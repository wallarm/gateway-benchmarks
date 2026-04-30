#!/usr/bin/env bash
# shellcheck shell=bash
#
# Phase 4 — thin wrapper over scripts/load-orchestrator.sh that sweeps
# multiple gateways back-to-back in a single background-friendly
# invocation. Each gateway still runs strictly serial under the hood
# (the docker-compose stacks bind the same host port 9080 and each
# gateway needs the full machine's CPU/RSS budget for fair numbers),
# so this script is literally a loop with per-gateway run-ids and a
# combined exit summary.
#
# Why a wrapper instead of teaching load-orchestrator.sh to take
# `--gateways a,b,c`: the per-gateway runs deliberately produce
# *independent* reports/<run-id>/ trees — that's the reproducibility
# contract (each sweep is re-runnable on its own SHA, seeds, infra).
# A single-sweep-across-gateways semantic would blur that line.
#
# Usage:
#   scripts/load-sweep-many.sh \
#     --gateways nginx,envoy,wallarm,traefik,kong,apisix,tyk \
#     [--loads    p1-baseline]                  default: p1-baseline
#     [--policies p01-vanilla,p02-jwt,…]         default: all 12 canonical
#     [--run-id-prefix <str>]                   default: auto-timestamp
#     [--seed     42]
#     [--stop-on-fail]                          abort on first non-PASS cell
#
# Outputs:
#   reports/<prefix>-<gateway>-<ts>/               one tree per gateway
#   reports/<prefix>-many-<ts>.stdout.log          tailable combined log
#
# The script writes a path list of all per-gateway run-ids to
#   /tmp/load-sweep-many.last-runs
# which `bench compare-runs` / `bench report --combined` consume via
# `--run-ids "$(cat /tmp/load-sweep-many.last-runs | paste -sd, -)"`.
#
# Exit codes:
#   0    every sweep either all-PASS or all-EXCLUDED
#   1    at least one sweep had a FAIL (captured but kept going)
#   2    argument error
#   >2   propagated from load-orchestrator.sh when --stop-on-fail is set

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

GATEWAYS_CSV=""
LOADS_CSV="p1-baseline"
POLICIES_CSV=""
SEED="${BENCH_RUN_SEED:-42}"
STOP_ON_FAIL=0
RUN_ID_PREFIX=""

while (( $# > 0 )); do
    case "$1" in
        --gateways)       GATEWAYS_CSV="$2"; shift 2;;
        --loads)          LOADS_CSV="$2"; shift 2;;
        --policies)       POLICIES_CSV="$2"; shift 2;;
        --run-id-prefix)  RUN_ID_PREFIX="$2"; shift 2;;
        --seed)           SEED="$2"; shift 2;;
        --stop-on-fail)   STOP_ON_FAIL=1; shift;;
        -h|--help)        sed -n '2,40p' "${BASH_SOURCE[0]}"; exit 0;;
        *)                printf 'unknown arg: %s\n' "$1" >&2; exit 2;;
    esac
done

[[ -n "${GATEWAYS_CSV}" ]] || {
    printf '%s\n' "--gateways is required (comma-separated list)" >&2
    exit 2
}

# Portable CSV split — `for tok in ${csv}` with IFS=',' is the macOS
# bash-3.2-friendly idiom (mapfile / `read -ra` is bash-4+). Mirrors
# the helper in `scripts/load-orchestrator.sh`.
split_csv_into_array() {
    # $1 = name of array to populate, $2 = CSV string
    local __name="$1"
    local __csv="$2"
    local __tok
    eval "${__name}=()"
    local IFS=','
    for __tok in ${__csv}; do
        __tok="${__tok#"${__tok%%[![:space:]]*}"}"
        __tok="${__tok%"${__tok##*[![:space:]]}"}"
        eval "${__name}+=(\"\${__tok}\")"
    done
}
split_csv_into_array GATEWAYS "${GATEWAYS_CSV}"

ts="$(date -u +%Y%m%dT%H%M%SZ)"
[[ -n "${RUN_ID_PREFIX}" ]] || RUN_ID_PREFIX="pathA"

master_log="reports/${RUN_ID_PREFIX}-many-${ts}.stdout.log"
mkdir -p "reports"
: > "${master_log}"
: > /tmp/load-sweep-many.last-runs

total=${#GATEWAYS[@]}
pass_sweeps=0
fail_sweeps=0
idx=0

# ANSI colors — mirror the orchestrator so the combined log reads
# like one continuous sweep.
CY=$'\033[36m'; GR=$'\033[32m'; YL=$'\033[33m'; RD=$'\033[31m'; NC=$'\033[0m'

{
    printf '%s=== sweep-many: %d gateways × loads=%s ===%s\n' \
        "${CY}" "${total}" "${LOADS_CSV}" "${NC}"
    printf '%sgateways: %s%s\n' "${CY}" "${GATEWAYS_CSV}" "${NC}"
    [[ -n "${POLICIES_CSV}" ]] && printf '%spolicies: %s%s\n' "${CY}" "${POLICIES_CSV}" "${NC}"
    printf '%sseed:     %s%s\n\n' "${CY}" "${SEED}" "${NC}"
} | tee -a "${master_log}"

for gw in "${GATEWAYS[@]}"; do
    idx=$(( idx + 1 ))
    run_id="${RUN_ID_PREFIX}-${gw}-${ts}"
    # Stamp the sub-run's log with a banner referring back to the
    # combined log, so an operator tailing reports/<run_id>.stdout.log
    # sees the wider context.
    {
        printf '\n%s=== sweep-many [%d/%d]: %s (run_id=%s) ===%s\n' \
            "${CY}" "${idx}" "${total}" "${gw}" "${run_id}" "${NC}"
    } | tee -a "${master_log}"

    orch_args=(
        --gateway "${gw}"
        --loads   "${LOADS_CSV}"
        --seed    "${SEED}"
        --run-id  "${run_id}"
    )
    [[ -n "${POLICIES_CSV}" ]] && orch_args+=( --policies "${POLICIES_CSV}" )
    [[ "${STOP_ON_FAIL}" -eq 1 ]] && orch_args+=( --stop-on-fail )

    # Record the run-id for the aggregator tooling BEFORE we start, so
    # a crash mid-sweep still leaves a traceable list of RUN_IDs.
    printf '%s\n' "${run_id}" >> /tmp/load-sweep-many.last-runs

    # Run the orchestrator; its own stdout is both written to its own
    # reports/<run_id>.stdout.log and streamed into the master log.
    rc=0
    bash scripts/load-orchestrator.sh "${orch_args[@]}" \
        > "reports/${run_id}.stdout.log" 2>&1 || rc=$?

    # Even when the orchestrator exits non-zero, we tee its tail into
    # the master log so the final summary is in one place.
    tail -n 10 "reports/${run_id}.stdout.log" | tee -a "${master_log}" >/dev/null

    if [[ "${rc}" -eq 0 ]]; then
        pass_sweeps=$(( pass_sweeps + 1 ))
        printf '%ssweep-many [%d/%d] %s: PASS%s\n' \
            "${GR}" "${idx}" "${total}" "${gw}" "${NC}" | tee -a "${master_log}"
    else
        fail_sweeps=$(( fail_sweeps + 1 ))
        printf '%ssweep-many [%d/%d] %s: FAIL (rc=%d)%s\n' \
            "${RD}" "${idx}" "${total}" "${gw}" "${rc}" "${NC}" | tee -a "${master_log}"
        if [[ "${STOP_ON_FAIL}" -eq 1 ]]; then
            printf '%sstop-on-fail set — aborting after %s%s\n' \
                "${YL}" "${gw}" "${NC}" | tee -a "${master_log}"
            break
        fi
    fi
done

{
    printf '\n%s=== sweep-many complete ===%s\n' "${CY}" "${NC}"
    printf '%sPASS sweeps:  %d/%d%s\n' "${GR}" "${pass_sweeps}" "${total}" "${NC}"
    printf '%sFAIL sweeps:  %d/%d%s\n' "${RD}" "${fail_sweeps}" "${total}" "${NC}"
    printf '%srun-ids written to /tmp/load-sweep-many.last-runs%s\n' "${CY}" "${NC}"
    printf '%scombined log: %s%s\n' "${CY}" "${master_log}" "${NC}"
} | tee -a "${master_log}"

if [[ "${fail_sweeps}" -gt 0 ]]; then
    exit 1
fi
exit 0
