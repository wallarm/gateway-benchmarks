#!/usr/bin/env bash
# gateways/traefik/p03-jwks-rs256-basic/setup.sh
#
# Post-up smoke + drift guard for traefik/p03-jwks-rs256-basic.
#
# This profile wires traefik's `forwardAuth` middleware at an
# OpenResty sidecar (service `jwks-auth` on bench-net, see
# ../docker-compose.yaml gated by `profiles: [p03-jwks-rs256-basic]`).
# The sidecar reuses the nginx column's Lua modules —
# `jwt_rs256_verify.lua` and `jwt_rs256_jwks.lua` — via column-local
# copies under `./jwks-auth/lualib/`. This script verifies:
#
#   1. The data plane (traefik :9080) is up AND the sidecar
#      (`jwks-auth:9091`) is reachable on bench-net.
#   2. The column-local Lua copies under ./jwks-auth/lualib/ are
#      byte-for-byte identical to the canonical nginx originals
#      under ../../nginx/_shared/lualib/. Apisix uses the same
#      ports-not-forks pattern for its lualib (see
#      gateways/apisix/_shared/lualib/); keeping the drift guard
#      at setup time means a lualib bugfix on the nginx column
#      does not silently drift the traefik sidecar.
#   3. The reference JWKS / PEM / kid bundle under
#      gateways/_reference/jwks-rs256/ is internally consistent
#      (same shape as the nginx column's drift guard).
#   4. Three mini-probes mirror the fixture so a failure at boot
#      surfaces before the parity runner starts.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

DATA_URL="${DATA_URL:-http://localhost:9080}"

REFERENCE_DIR="${REFERENCE_DIR:-${REPO_ROOT}/gateways/_reference/jwks-rs256}"
JWKS_FILE="${JWKS_FILE:-${REFERENCE_DIR}/jwks.json}"
PEM_FILE="${PEM_FILE:-${REFERENCE_DIR}/public.pem}"
KID_FILE="${KID_FILE:-${REFERENCE_DIR}/kid.txt}"
RS256_GEN_SCRIPT="${RS256_GEN_SCRIPT:-${REPO_ROOT}/scripts/gen-jwt-rs256.sh}"

NGINX_LUALIB_SRC="${NGINX_LUALIB_SRC:-${REPO_ROOT}/gateways/nginx/_shared/lualib}"
TRAEFIK_LUALIB_DST="${TRAEFIK_LUALIB_DST:-${SCRIPT_DIR}/jwks-auth/lualib}"

say()  { printf '%s %s\n' "$(date +'%H:%M:%S')" "$*" >&2; }
fail() { printf '\033[31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

[[ -f "${JWKS_FILE}"        ]] || fail "reference JWKS not found: ${JWKS_FILE}"
[[ -f "${PEM_FILE}"         ]] || fail "reference PEM not found:  ${PEM_FILE}"
[[ -f "${KID_FILE}"         ]] || fail "reference kid file not found: ${KID_FILE}"
[[ -x "${RS256_GEN_SCRIPT}" ]] || fail "RS256 generator not executable: ${RS256_GEN_SCRIPT}"
[[ -d "${NGINX_LUALIB_SRC}" ]] || fail "nginx canonical lualib not found: ${NGINX_LUALIB_SRC}"
[[ -d "${TRAEFIK_LUALIB_DST}" ]] || fail "traefik sidecar lualib not found: ${TRAEFIK_LUALIB_DST}"

# -----------------------------------------------------------------------------
# 1. Drift guard A: column-local Lua copies must equal the canonical
#    nginx-column sources byte-for-byte. This is the apisix pattern
#    applied to a new column — keeps the JWT/JWKS primitive living
#    in exactly one source location while allowing each column to
#    bind-mount its own copy (no cross-column compose references).
# -----------------------------------------------------------------------------
for mod in jwt_rs256_verify.lua jwt_rs256_jwks.lua; do
    src="${NGINX_LUALIB_SRC}/${mod}"
    dst="${TRAEFIK_LUALIB_DST}/${mod}"
    [[ -f "${src}" ]] || fail "canonical ${mod} missing at ${src}"
    [[ -f "${dst}" ]] || fail "column-local ${mod} missing at ${dst}"
    if ! cmp -s "${src}" "${dst}"; then
        fail "drift guard: ${dst} differs from canonical ${src}. Re-run: cp ${src} ${dst}"
    fi
done
say "  ✓ drift guard: column-local lualib (jwt_rs256_verify + jwt_rs256_jwks) matches nginx canonical"

# -----------------------------------------------------------------------------
# 2. Drift guard B: reference JWKS / PEM / kid bundle internally
#    consistent. Same check as the nginx column.
# -----------------------------------------------------------------------------
REFERENCE_KID=$(tr -d '\r\n' < "${KID_FILE}")
JWKS_KID=$(jq -r '.keys[0].kid' "${JWKS_FILE}")

[[ -n "${REFERENCE_KID}" && "${REFERENCE_KID}" != "null" ]] \
    || fail "drift guard: ${KID_FILE} is empty"
[[ -n "${JWKS_KID}"      && "${JWKS_KID}"      != "null" ]] \
    || fail "drift guard: ${JWKS_FILE} has no .keys[0].kid"
[[ "${REFERENCE_KID}" == "${JWKS_KID}" ]] \
    || fail "drift guard: kid mismatch between ${KID_FILE} ('${REFERENCE_KID}') and ${JWKS_FILE} ('${JWKS_KID}')"

grep -qF 'BEGIN PUBLIC KEY' "${PEM_FILE}" \
    || fail "drift guard: ${PEM_FILE} is not a SubjectPublicKeyInfo PEM (no 'BEGIN PUBLIC KEY' marker)"

say "  ✓ drift guard: reference JWKS + PEM + kid mutually consistent (kid=${REFERENCE_KID})"

# -----------------------------------------------------------------------------
# 3. Wait for the data plane.
#    Traefik answers /status/200 via PathPrefix(`/`) but the
#    forwardAuth middleware fires first. With no Authorization
#    header, the sidecar returns 401 and traefik terminates 401 —
#    that's our readiness signal. It proves BOTH the traefik router
#    AND the sidecar are up and wired.
# -----------------------------------------------------------------------------
say "traefik/p03-jwks-rs256-basic: waiting for ${DATA_URL}"
ready=0
for _ in $(seq 1 90); do
    code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 2 \
        "${DATA_URL}/anything" 2>/dev/null || echo 000)
    if [[ "${code}" == "401" ]]; then
        say "data plane + jwks-auth sidecar ready (got 401 without auth)"
        ready=1
        break
    fi
    sleep 1
done
(( ready == 1 )) || fail "traefik never returned 401 on ${DATA_URL}/anything (check jwks-auth sidecar — see compose logs for both services)"

# -----------------------------------------------------------------------------
# 4. Smoke — three mini-probes that mirror the canonical fixture
#    (fixtures/p03-jwks-rs256-basic.jsonl).
# -----------------------------------------------------------------------------
say "smoke: GET ${DATA_URL}/anything without Authorization -> expect 401"
missing_code=$(curl --max-time 5 -s -o /tmp/traefik-jwks.out -w '%{http_code}' \
    "${DATA_URL}/anything" || true)
[[ "${missing_code}" == "401" ]] \
    || { cat /tmp/traefik-jwks.out >&2
         fail "smoke: expected 401 without token, got ${missing_code}"; }

valid_token="$("${RS256_GEN_SCRIPT}" valid)"
say "smoke: GET ${DATA_URL}/anything with valid RS256 token (kid=${REFERENCE_KID}) -> expect 200"
valid_code=$(curl --max-time 5 -s -o /tmp/traefik-jwks.out -w '%{http_code}' \
    -H "Authorization: Bearer ${valid_token}" \
    "${DATA_URL}/anything" || true)
[[ "${valid_code}" == "200" ]] \
    || { cat /tmp/traefik-jwks.out >&2
         fail "smoke: expected 200 with valid RS256 token, got ${valid_code}"; }

unknown_token="$("${RS256_GEN_SCRIPT}" unknown-kid)"
say "smoke: GET ${DATA_URL}/anything with RS256 token carrying unknown kid -> expect 401"
unknown_code=$(curl --max-time 5 -s -o /tmp/traefik-jwks.out -w '%{http_code}' \
    -H "Authorization: Bearer ${unknown_token}" \
    "${DATA_URL}/anything" || true)
[[ "${unknown_code}" == "401" ]] \
    || { cat /tmp/traefik-jwks.out >&2
         fail "smoke: expected 401 with unknown-kid RS256 token, got ${unknown_code}"; }

say "traefik/p03-jwks-rs256-basic ready"
