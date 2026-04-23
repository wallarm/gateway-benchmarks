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

# -----------------------------------------------------------------------------
# Per-profile opt-in compose services
#
# `COMPOSE_PROFILES` is read by `docker compose` to gate services that
# carry a matching `profiles: [<name>]` directive. Unprofiled services
# always start. Profiled services only start when their profile name
# appears in COMPOSE_PROFILES.
#
# We export the current parity PROFILE (e.g. `p03-jwks-rs256-basic`) so
# that any gateway column can opt-in per-profile sidecars WITHOUT
# branching logic in this script. Example: the traefik column
# declares a `jwks-auth` OpenResty sidecar under
# `profiles: [p03-jwks-rs256-basic]`; it only boots when PARITY_PROFILE
# is `p03-jwks-rs256-basic`, not during the 12 profile runs.
#
# Existing columns that don't use compose profiles are unaffected —
# setting COMPOSE_PROFILES has no effect on services without a
# matching `profiles:` directive.
# -----------------------------------------------------------------------------
export COMPOSE_PROFILES="${PROFILE}"

RUN_ID="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
if [[ -z "${OUTPUT}" ]]; then
    OUTPUT="reports/${RUN_ID}/parity/${GATEWAY}-${PROFILE}.json"
fi
LOGS_DIR="$(dirname "${OUTPUT}")/logs/${GATEWAY}-${PROFILE}"
mkdir -p "$(dirname "${OUTPUT}")" "${LOGS_DIR}"
RUNTIME_FEATURE_MISSING_REASON_FILE="${LOGS_DIR}/feature-missing.txt"
SETUP_FEATURE_MISSING_RC=42

GATEWAY_TARGET="${GATEWAY_TARGET:-http://localhost:9080}"

# The burst runner defaults to 32 concurrent workers, which is fine
# against a bare backend but leaves slack on a cold gateway under
# x86/arm emulation. Push it to 128 so the 1200-req/s parity probe
# actually fits inside its 1-second window.
#
# Per-gateway override: if `gateways/<gw>/parity.env` exists, source
# it here so a column can tune its harness posture without touching
# the default. The file is a plain bash snippet — only simple
# `KEY=value` lines intended. No column ships one today: an earlier
# iteration added `gateways/envoy/parity.env` with
# `BURST_PARALLELISM=32` after misdiagnosing a connection-churn
# symptom on Docker Desktop as "accept-queue saturation"; the real
# root cause was `max_connection_duration: 0s` in envoy's HCM
# `common_http_protocol_options` (closes every connection at t=0,
# not "no maximum"). Unsetting that field across every envoy
# profile eliminated the churn and the override was dropped. The
# mechanism stays here for future columns whose harness posture
# legitimately differs.
gateway_parity_env="gateways/${GATEWAY}/parity.env"
if [[ -f "${gateway_parity_env}" ]]; then
    # shellcheck disable=SC1090
    source "${gateway_parity_env}"
fi
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
# Per-profile overrides (e.g. GATEWAY_IMAGE to swap in openresty for
# profiles that need extra modules). The .env file is optional; most
# profiles rely on the default values baked into docker-compose.yaml.
# We pass it via `docker compose --env-file` (not `source` into the
# current shell) so the override is scoped strictly to this invocation
# of compose — no risk of GATEWAY_IMAGE leaking into sibling profiles
# inside a `make parity-gateway-all` sweep.
profile_env="gateways/${GATEWAY}/${PROFILE}/.env"
compose_cmd=(docker compose)
if [[ -f "${profile_env}" ]]; then
    compose_cmd+=(--env-file "${profile_env}")
fi
compose_cmd+=(-f "${compose_file}")

teardown() {
    local rc=$?
    set +e
    if (( KEEP_UP == 1 )); then
        warn "keep-up requested — stack left running (tear down with: ${compose_cmd[*]} down -v)"
    else
        say "=> capturing logs & stopping stack"
        "${compose_cmd[@]}" logs --no-color > "${LOGS_DIR}/compose.log" 2>&1 || true
        "${compose_cmd[@]}" down --remove-orphans -v >/dev/null 2>&1 || true
    fi
    return "${rc}"
}
trap teardown EXIT

# -----------------------------------------------------------------------------
# 1. Bring up the stack
# -----------------------------------------------------------------------------
say "=> bringing up stack (${GATEWAY} / ${PROFILE})"
"${compose_cmd[@]}" down --remove-orphans -v >/dev/null 2>&1 || true

if [[ -f "${profile_env}" ]]; then
    say "=> per-profile env: ${profile_env}"
fi

GATEWAY_PROFILE="${PROFILE}" "${compose_cmd[@]}" up -d

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
rm -f "${RUNTIME_FEATURE_MISSING_REASON_FILE}"
setup_rc=0
FEATURE_MISSING_REASON_FILE="${RUNTIME_FEATURE_MISSING_REASON_FILE}" \
    bash "${setup_script}" || setup_rc=$?

case "${setup_rc}" in
    0) ;;
    "${SETUP_FEATURE_MISSING_RC}")
        reason="$(sed -n '1p' "${RUNTIME_FEATURE_MISSING_REASON_FILE}" 2>/dev/null || true)"
        say "=> ${GATEWAY} / ${PROFILE}: setup reported FEATURE-MISSING"
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
        ;;
    *)
        exit "${setup_rc}"
        ;;
esac

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
