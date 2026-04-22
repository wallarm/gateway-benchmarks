#!/usr/bin/env bash
# shellcheck shell=bash
#
# End-to-end parity for a single (gateway, profile) pair:
#
#   1. docker compose up the gateway stack (gateway + backend)
#   2. wait for the data plane to answer HTTP
#   3. run gateways/<gw>/<profile>/setup.sh to configure policies
#   4. run scripts/parity-attestation.sh against the data port
#   5. (optional) dump gateway / backend logs into the output directory
#   6. docker compose down regardless of outcome (trap-based cleanup)
#
# Contract on port layout: every `gateways/<gw>/docker-compose.yaml`
# publishes the data plane on host :9080 and, when applicable, the
# admin API on host :9081. That lets this script stay gateway-agnostic.
#
# Usage:
#   scripts/parity-gateway.sh \
#     --gateway <name> \
#     --profile <pXX-slug> \
#     [--output  <path>]          JSON result (default: reports/<RUN_ID>/parity/<gw>-<profile>.json)
#     [--keep-up]                 skip the final `docker compose down`
#     [--verbose]                 verbose parity output
#
# Dependencies: bash, docker, docker compose, curl, jq.

set -euo pipefail
shopt -s nullglob

# -----------------------------------------------------------------------------
# Paths
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

# -----------------------------------------------------------------------------
# Arg parsing
# -----------------------------------------------------------------------------
GATEWAY=""
PROFILE=""
OUTPUT=""
KEEP_UP=0
VERBOSE=0

usage() {
    sed -n '2,26p' "${BASH_SOURCE[0]}" >&2
    exit 2
}

while (( $# > 0 )); do
    case "$1" in
        --gateway) GATEWAY="$2"; shift 2;;
        --profile) PROFILE="$2"; shift 2;;
        --output)  OUTPUT="$2";  shift 2;;
        --keep-up) KEEP_UP=1;    shift;;
        --verbose|-v) VERBOSE=1; shift;;
        -h|--help) usage;;
        *) printf 'unknown arg: %s\n' "$1" >&2; usage;;
    esac
done

[[ -n "${GATEWAY}" ]] || { printf '%s\n' "--gateway is required" >&2; exit 2; }
[[ -n "${PROFILE}" ]] || { printf '%s\n' "--profile is required" >&2; exit 2; }

compose_file="gateways/${GATEWAY}/docker-compose.yaml"
profile_dir="gateways/${GATEWAY}/${PROFILE}"
setup_script="${profile_dir}/setup.sh"
feature_missing="${profile_dir}/FEATURE-MISSING"

[[ -d "${profile_dir}" ]] || { printf 'profile directory not found: %s\n' "${profile_dir}" >&2; exit 2; }

RUN_ID="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
if [[ -z "${OUTPUT}" ]]; then
    OUTPUT="reports/${RUN_ID}/parity/${GATEWAY}-${PROFILE}.json"
fi
LOGS_DIR="$(dirname "${OUTPUT}")/logs/${GATEWAY}-${PROFILE}"
mkdir -p "$(dirname "${OUTPUT}")" "${LOGS_DIR}"

GATEWAY_TARGET="${GATEWAY_TARGET:-http://localhost:9080}"

# The burst runner defaults to 32 concurrent workers, which is fine
# against a bare backend but leaves slack on a cold gateway under
# x86/arm emulation. Push it to 128 so the 1200-req/s parity probe
# actually fits inside its 1-second window.
export BURST_PARALLELISM="${BURST_PARALLELISM:-128}"

# -----------------------------------------------------------------------------
# Colors
# -----------------------------------------------------------------------------
C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_C=$'\033[36m'; C_N=$'\033[0m'
say()  { printf '%s%s%s\n' "${C_C}" "$*" "${C_N}" >&2; }
warn() { printf '%s%s%s\n' "${C_Y}" "$*" "${C_N}" >&2; }
ok()   { printf '%s%s%s\n' "${C_G}" "$*" "${C_N}" >&2; }
bad()  { printf '%s%s%s\n' "${C_R}" "$*" "${C_N}" >&2; }

# -----------------------------------------------------------------------------
# FEATURE-MISSING short-circuit.
#
# A profile directory is allowed to contain a single file named
# `FEATURE-MISSING` whose body explains *why* the profile is not
# implementable on this gateway/version. We then:
#
#   - do not bring up a stack,
#   - do not run a setup script,
#   - produce a valid parity JSON with status=FEATURE-MISSING,
#
# which keeps `parity-gateway-all` counting columns correctly.
# -----------------------------------------------------------------------------
if [[ -f "${feature_missing}" ]]; then
    reason="$(head -n 1 "${feature_missing}" 2>/dev/null || true)"
    say "=> ${GATEWAY} / ${PROFILE}: FEATURE-MISSING marker found"
    [[ -n "${reason}" ]] && warn "   reason: ${reason}"
    parity_args=(
        --gateway "${GATEWAY}"
        --profile "${PROFILE}"
        --target  "${GATEWAY_TARGET}"
        --output  "${OUTPUT}"
        --feature-missing
    )
    (( VERBOSE == 1 )) && parity_args+=(--verbose)
    bash scripts/parity-attestation.sh "${parity_args[@]}" >/dev/null
    warn "verdict: FEATURE-MISSING  ${OUTPUT}"
    exit 0
fi

# A real run needs both the compose file and a setup script.
[[ -f "${compose_file}" ]] || { printf 'compose file not found: %s\n' "${compose_file}" >&2; exit 2; }
[[ -f "${setup_script}" ]] || { printf 'setup script not found: %s\n' "${setup_script}" >&2; exit 2; }

# -----------------------------------------------------------------------------
# Teardown — always runs, even on Ctrl-C / failure
# -----------------------------------------------------------------------------
teardown() {
    local rc=$?
    set +e
    if (( KEEP_UP == 1 )); then
        warn "keep-up requested — stack left running (tear down with: docker compose -f ${compose_file} down -v)"
    else
        say "=> capturing logs & stopping stack"
        docker compose -f "${compose_file}" logs --no-color > "${LOGS_DIR}/compose.log" 2>&1 || true
        docker compose -f "${compose_file}" down --remove-orphans -v >/dev/null 2>&1 || true
    fi
    return "${rc}"
}
trap teardown EXIT

# -----------------------------------------------------------------------------
# 1. Bring up the stack
# -----------------------------------------------------------------------------
say "=> bringing up stack (${GATEWAY} / ${PROFILE})"
docker compose -f "${compose_file}" down --remove-orphans -v >/dev/null 2>&1 || true
GATEWAY_PROFILE="${PROFILE}" docker compose -f "${compose_file}" up -d

# -----------------------------------------------------------------------------
# 2. Wait for the data plane
# -----------------------------------------------------------------------------
say "=> waiting for ${GATEWAY_TARGET}"
for _ in $(seq 1 60); do
    # During a vanilla boot the gateway will return 404 because no
    # route is registered yet. We just want to know *something* answers.
    if curl -sS -o /dev/null -w '%{http_code}\n' --max-time 2 "${GATEWAY_TARGET}/" \
           2>/dev/null | grep -qE '^[0-9]{3}$'; then
        ok "gateway data plane answering"
        break
    fi
    sleep 1
done

# -----------------------------------------------------------------------------
# 3. Run the profile-specific setup
# -----------------------------------------------------------------------------
say "=> running setup ${setup_script}"
bash "${setup_script}"

# -----------------------------------------------------------------------------
# 4. Run parity attestation
# -----------------------------------------------------------------------------
say "=> running parity-attestation"
parity_args=(
    --gateway "${GATEWAY}"
    --profile "${PROFILE}"
    --target  "${GATEWAY_TARGET}"
    --output  "${OUTPUT}"
)
(( VERBOSE == 1 )) && parity_args+=(--verbose)

parity_rc=0
bash scripts/parity-attestation.sh "${parity_args[@]}" || parity_rc=$?

# -----------------------------------------------------------------------------
# 5. Report
# -----------------------------------------------------------------------------
status="$(jq -r '.status' "${OUTPUT}" 2>/dev/null || echo UNKNOWN)"
case "${status}" in
    PASS)             ok   "verdict: PASS    ${OUTPUT}";;
    FAIL)             bad  "verdict: FAIL    ${OUTPUT}";;
    FEATURE-MISSING)  warn "verdict: FEATURE-MISSING  ${OUTPUT}";;
    *)                warn "verdict: ${status}  ${OUTPUT}";;
esac

exit "${parity_rc}"
