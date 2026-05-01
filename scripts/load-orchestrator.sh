#!/usr/bin/env bash
# shellcheck shell=bash
#
# Phase 4 — load matrix orchestrator. Sweeps one gateway through an
# arbitrary subset of the (policy × scenario × load) matrix by
# invoking scripts/load-gateway.sh once per cell and accumulating
# the per-cell outputs under a single reports/<RUN_ID>/ tree.
#
# This is the minimal Phase-4 bash orchestrator — it produced the
# first publishable load numbers on a developer machine. It is kept
# as a tiny, auditable reference; the production entrypoint is the
# Go binary under orchestrator/ (invoked via `make perf-local-run`
# / `bench run`) which subsumes it with proper parallelism, retry,
# and cross-gateway fan-out.
#
# Lifecycle (per cell):
#
#   1. Compute the cell triplet (policy, scenario, load).
#   2. Invoke scripts/load-gateway.sh with that triplet.
#   3. Record the cell's outcome into
#      reports/<RUN_ID>/matrix.tsv (append-only).
#   4. Continue to the next cell unless --stop-on-fail.
#
# After the sweep, emit a short summary with PASS / EXCLUDED / FAIL
# counts.
#
# Usage:
#
#   scripts/load-orchestrator.sh \
#     --gateway   <name>                         (required) e.g. nginx
#     [--policies  p01,p02,p03,p04-rl-static,…]  (default: all 12 canonical)
#     [--scenarios s01,s02,…]                    (default: auto-map from policies)
#     [--loads    p1-baseline,p2-sustained,…]    (default: p1-baseline)
#     [--run-id    <id>]                         (default: auto-timestamp)
#     [--stop-on-fail]                           (default: keep going)
#     [--seed     <int>]                         (default: 42)
#     [--stream]                                 (stream per-request JSON)
#     [--dry-run]                                (print plan and exit)
#
# Policy ↔ scenario mapping (when --scenarios is omitted):
#   p01-vanilla           → s01-vanilla-http
#   p02-jwt               → s02-jwt-http
#   p03-jwks-rs256-basic  → s03-jwks-rs256-basic-http
#   …
#   p12-full-pipeline     → s12-full-pipeline-http
#
# i.e. the policy slug with `p` swapped for `s` and `-http` appended.
#
# Exit codes:
#   0   every cell either PASSed or was cleanly EXCLUDED
#   1   at least one cell FAILed (or was interrupted) and
#       --stop-on-fail was not set (the matrix completed but not green)
#   2   argument error
#   >2  propagated from load-gateway.sh when --stop-on-fail is set

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

# -----------------------------------------------------------------------------
# Defaults
# -----------------------------------------------------------------------------
GATEWAY=""
POLICIES_CSV=""
SCENARIOS_CSV=""
LOADS_CSV="p1-baseline"
RUN_ID=""
STOP_ON_FAIL=0
STREAM=0
DRY_RUN=0
SEED="${BENCH_RUN_SEED:-42}"

CANONICAL_POLICIES=(
    p01-vanilla
    p02-jwt
    p03-jwks-rs256-basic
    p04-rl-static
    p05-rl-endpoint
    p06-rl-dynamic-low
    p07-rl-dynamic-high
    p08-req-headers
    p09-resp-headers
    p10-req-body
    p11-resp-body
    p12-full-pipeline
)

# -----------------------------------------------------------------------------
# Arg parsing
# -----------------------------------------------------------------------------
usage() { sed -n '2,50p' "${BASH_SOURCE[0]}" >&2; exit 2; }

while (( $# > 0 )); do
    case "$1" in
        --gateway)      GATEWAY="$2";       shift 2;;
        --policies)     POLICIES_CSV="$2";  shift 2;;
        --scenarios)    SCENARIOS_CSV="$2"; shift 2;;
        --loads)        LOADS_CSV="$2";     shift 2;;
        --run-id)       RUN_ID="$2";        shift 2;;
        --stop-on-fail) STOP_ON_FAIL=1;     shift;;
        --stream)       STREAM=1;           shift;;
        --dry-run)      DRY_RUN=1;          shift;;
        --seed)         SEED="$2";          shift 2;;
        -h|--help)      usage;;
        *) printf 'unknown arg: %s\n' "$1" >&2; usage;;
    esac
done

[[ -n "${GATEWAY}" ]] || { printf '%s\n' "--gateway is required" >&2; exit 2; }

# -----------------------------------------------------------------------------
# Resolve policies, scenarios, loads into bash arrays
# -----------------------------------------------------------------------------
# `mapfile -t` is bash 4+; macOS ships 3.2 — use a portable reader.
split_csv_into_array() {
    # $1 = name of array to populate, $2 = CSV string
    local __name="$1"
    local __csv="$2"
    local __tok
    eval "${__name}=()"
    local IFS=','
    for __tok in ${__csv}; do
        # trim surrounding whitespace
        __tok="${__tok#"${__tok%%[![:space:]]*}"}"
        __tok="${__tok%"${__tok##*[![:space:]]}"}"
        [[ -z "${__tok}" ]] && continue
        eval "${__name}+=(\"\${__tok}\")"
    done
}

if [[ -n "${POLICIES_CSV}" ]]; then
    split_csv_into_array POLICIES "${POLICIES_CSV}"
else
    POLICIES=("${CANONICAL_POLICIES[@]}")
fi

if [[ -n "${SCENARIOS_CSV}" ]]; then
    split_csv_into_array SCENARIOS "${SCENARIOS_CSV}"
    if (( ${#SCENARIOS[@]} != ${#POLICIES[@]} )); then
        printf 'scenario count (%d) != policy count (%d); scenarios must be one-per-policy in order\n' \
            "${#SCENARIOS[@]}" "${#POLICIES[@]}" >&2
        exit 2
    fi
else
    # Auto-map: p<NN>-<slug> → s<NN>-<slug>-http
    SCENARIOS=()
    for p in "${POLICIES[@]}"; do
        SCENARIOS+=("s${p#p}-http")
    done
fi

split_csv_into_array LOADS "${LOADS_CSV}"
# Accepted load profiles — both closed-loop (p1/p2/p3/p4-*) and
# their paced-arrivals twins (p1c/p2c/p3c/p4c-paced). The `-paced`
# suffix is the gate for the `constant-arrival-rate` executors; see
# docs/LOAD-PROFILES.md § Paced-arrivals variants. Any new profile
# MUST be added here AND in `k6/lib/options.js`'s profileMap.
for l in "${LOADS[@]}"; do
    case "${l}" in
        p1-baseline|p2-sustained|p3-ramp|p4-stress) ;;
        p1c-paced|p2c-paced|p3c-paced|p4c-paced) ;;
        *) printf 'unknown load profile: %s (valid: p1-baseline|p2-sustained|p3-ramp|p4-stress|p1c-paced|p2c-paced|p3c-paced|p4c-paced)\n' "${l}" >&2; exit 2;;
    esac
done

# -----------------------------------------------------------------------------
# Run ID & output layout
# -----------------------------------------------------------------------------
if [[ -z "${RUN_ID}" ]]; then
    RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
fi
export RUN_ID

MATRIX_TSV="reports/${RUN_ID}/matrix.tsv"
SWEEP_LOG="reports/${RUN_ID}/orchestrator.log"
mkdir -p "reports/${RUN_ID}"

# -----------------------------------------------------------------------------
# Colors
# -----------------------------------------------------------------------------
C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_C=$'\033[36m'; C_N=$'\033[0m'
say()  { printf '%s%s%s\n' "${C_C}" "$*" "${C_N}"; }
ok()   { printf '%s%s%s\n' "${C_G}" "$*" "${C_N}"; }
warn() { printf '%s%s%s\n' "${C_Y}" "$*" "${C_N}"; }
bad()  { printf '%s%s%s\n' "${C_R}" "$*" "${C_N}"; }

# -----------------------------------------------------------------------------
# Plan
# -----------------------------------------------------------------------------
total_cells=$(( ${#POLICIES[@]} * ${#LOADS[@]} ))

say "=== load-orchestrator sweep ==="
say "  gateway:    ${GATEWAY}"
say "  run_id:     ${RUN_ID}"
say "  policies:   ${#POLICIES[@]}"
say "  scenarios:  ${#SCENARIOS[@]}"
say "  loads:      ${#LOADS[@]}  (${LOADS_CSV})"
say "  total:      ${total_cells} cells"
say "  report:     reports/${RUN_ID}/"
say ""

if (( DRY_RUN == 1 )); then
    say "=== plan (dry-run) ==="
    cell_no=0
    for i in "${!POLICIES[@]}"; do
        for l in "${LOADS[@]}"; do
            cell_no=$(( cell_no + 1 ))
            printf '%3d. %s  %s  %s  %s\n' \
                "${cell_no}" \
                "${GATEWAY}" "${POLICIES[i]}" "${SCENARIOS[i]}" "${l}"
        done
    done
    exit 0
fi

# -----------------------------------------------------------------------------
# matrix.tsv header
# -----------------------------------------------------------------------------
printf 'cell\tgateway\tpolicy\tscenario\tload\tverdict\tduration_s\toutput_dir\n' > "${MATRIX_TSV}"

# -----------------------------------------------------------------------------
# Sweep
# -----------------------------------------------------------------------------
pass=0
excluded=0
failed=0
cell_no=0

for i in "${!POLICIES[@]}"; do
    policy="${POLICIES[i]}"
    scenario="${SCENARIOS[i]}"
    for load in "${LOADS[@]}"; do
        cell_no=$(( cell_no + 1 ))
        output_dir="reports/${RUN_ID}/raw/${GATEWAY}/${policy}__${load}__${scenario}"

        say ""
        say "=== cell ${cell_no}/${total_cells}: ${GATEWAY} / ${policy} / ${load} / ${scenario} ==="

        load_args=(
            --gateway  "${GATEWAY}"
            --policy   "${policy}"
            --scenario "${scenario}"
            --load     "${load}"
            --output   "${output_dir}"
            --seed     "${SEED}"
        )
        (( STREAM == 1 )) && load_args+=(--stream)

        t0="$(date +%s)"
        rc=0
        RUN_ID="${RUN_ID}" bash scripts/load-gateway.sh "${load_args[@]}" \
            2>&1 | tee -a "${SWEEP_LOG}" || rc="${PIPESTATUS[0]}"
        t1="$(date +%s)"
        dt=$(( t1 - t0 ))

        verdict=""
        if [[ -s "${output_dir}/k6-summary.json" ]]; then
            verdict="PASS"
            pass=$(( pass + 1 ))
            ok "  ${cell_no}/${total_cells} PASS (${dt}s)"
        elif [[ -s "${output_dir}/excluded.json" ]]; then
            verdict="EXCLUDED"
            excluded=$(( excluded + 1 ))
            warn "  ${cell_no}/${total_cells} EXCLUDED (${dt}s)"
        else
            verdict="FAIL"
            failed=$(( failed + 1 ))
            bad "  ${cell_no}/${total_cells} FAIL (${dt}s, rc=${rc})"
        fi

        printf '%d\t%s\t%s\t%s\t%s\t%s\t%d\t%s\n' \
            "${cell_no}" "${GATEWAY}" "${policy}" "${scenario}" "${load}" \
            "${verdict}" "${dt}" "${output_dir}" >> "${MATRIX_TSV}"

        if (( STOP_ON_FAIL == 1 )) && [[ "${verdict}" == "FAIL" ]]; then
            bad "stop-on-fail: halting sweep at cell ${cell_no}/${total_cells}"
            exit "${rc:-1}"
        fi
    done
done

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
say ""
say "=== sweep complete ==="
ok   "  PASS:     ${pass}/${total_cells}"
warn "  EXCLUDED: ${excluded}/${total_cells}"
bad  "  FAIL:     ${failed}/${total_cells}"
say "  matrix:   ${MATRIX_TSV}"
say "  log:      ${SWEEP_LOG}"
say "  reports:  reports/${RUN_ID}/"

# Aggregate + render the same Go-pipeline HTML the AWS sweep produces.
# Best-effort — failures here don't change the sweep's exit code,
# the raw artefacts are already on disk. Override with BENCH_LOCAL_REPORT=0.
if [[ "${BENCH_LOCAL_REPORT:-1}" == "1" ]]; then
    bench_bin="${REPO_ROOT}/orchestrator/bin/bench"
    if [[ ! -x "${bench_bin}" ]]; then
        warn "  (HTML report skipped: ${bench_bin} not built — \`cd orchestrator && go build -o bin/bench .\`)"
    elif "${bench_bin}" --repo-root "${REPO_ROOT}" aggregate --run-id "${RUN_ID}" -q >/dev/null 2>&1 \
        && "${bench_bin}" --repo-root "${REPO_ROOT}" report --run-id "${RUN_ID}" >/dev/null 2>&1; then
        ok "  report:   reports/${RUN_ID}/report.html"
    else
        warn "  (HTML report failed — re-run \`bench aggregate / report --run-id ${RUN_ID}\` to see the error)"
    fi
fi

if (( failed > 0 )); then
    exit 1
fi
exit 0
