#!/usr/bin/env bash
# gateways/nginx/p03-jwks-rs256-basic/setup.sh
#
# Post-up smoke + drift guard for nginx/p03-jwks-rs256-basic.
#
# OpenResty loads nginx.conf at container start; init_by_lua_block
# runs once per worker and slurps the JWKS + PEM + kid from the
# reference mount (see ../docker-compose.yaml and the `init_by_lua_block`
# in nginx.conf). There is no Admin API and no runtime bootstrap —
# the whole JWKS wiring lives in static config + static bind-mount.
# This script only:
#
#   1. Waits for the data plane.
#   2. Drift guard: asserts the reference files under
#      gateways/_reference/jwks-rs256/ still describe the same key
#      pair (the `kid` in `jwks.json` matches `kid.txt`, and
#      `public.pem` is non-empty with a `BEGIN PUBLIC KEY` marker).
#   3. Smokes the three mini-probes that mirror the fixture so a
#      failure at boot surfaces before the parity runner starts.
#
# There is no FEATURE-MISSING fallback: the FFI-to-libcrypto path
# works on every pinned `openresty/openresty:1.27.1.2-alpine` build
# (libcrypto.so is shipped in the image itself; OpenSSL 3.5.5 at
# the time of this iteration). If it breaks this is a FAIL, not a
# FEATURE-MISSING.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

DATA_URL="${DATA_URL:-http://localhost:9080}"

REFERENCE_DIR="${REFERENCE_DIR:-${REPO_ROOT}/gateways/_reference/jwks-rs256}"
JWKS_FILE="${JWKS_FILE:-${REFERENCE_DIR}/jwks.json}"
PEM_FILE="${PEM_FILE:-${REFERENCE_DIR}/public.pem}"
KID_FILE="${KID_FILE:-${REFERENCE_DIR}/kid.txt}"
RS256_GEN_SCRIPT="${RS256_GEN_SCRIPT:-${REPO_ROOT}/scripts/gen-jwt-rs256.sh}"

say()  { printf '%s %s\n' "$(date +'%H:%M:%S')" "$*" >&2; }
fail() { printf '\033[31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

[[ -f "${JWKS_FILE}"         ]] || fail "reference JWKS not found: ${JWKS_FILE}"
[[ -f "${PEM_FILE}"          ]] || fail "reference PEM not found:  ${PEM_FILE}"
[[ -f "${KID_FILE}"          ]] || fail "reference kid file not found: ${KID_FILE}"
[[ -x "${RS256_GEN_SCRIPT}"  ]] || fail "RS256 generator not executable: ${RS256_GEN_SCRIPT}"

# -----------------------------------------------------------------------------
# 1. Wait for the data plane.
#    The server block has `access_by_lua_block` on `/`, so every
#    request without an Authorization header returns 401 as soon as
#    nginx finishes loading nginx.conf — that's the readiness
#    signal. init_by_lua_block's PEM parse either works or crashes
#    the worker, so if the proxy answers 401 at all, libcrypto +
#    JWKS + PEM are all wired.
# -----------------------------------------------------------------------------
say "nginx/p03-jwks-rs256-basic: waiting for ${DATA_URL}"
ready=0
for _ in $(seq 1 60); do
    code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 2 \
        "${DATA_URL}/anything" 2>/dev/null || echo 000)
    if [[ "${code}" == "401" ]]; then
        say "data plane ready (got 401 without auth)"
        ready=1
        break
    fi
    sleep 1
done
(( ready == 1 )) || fail "data plane never returned 401 on ${DATA_URL}/anything (check init_by_lua_block didn't crash the worker — see compose logs)"

# -----------------------------------------------------------------------------
# 2. Drift guard — the reference files under gateways/_reference/jwks-rs256/
#    MUST describe the same key pair. Unlike envoy/apisix/kong where
#    the embedded JWKS or PEM lives inside the profile config, this
#    nginx profile reads the reference files directly via a bind-
#    mount (see ../docker-compose.yaml). That removes a whole class
#    of drift (forgotten paste-refresh after a rotation) by
#    construction — but we still sanity-check the reference itself.
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
# 3. Smoke — three mini-probes that mirror the canonical fixture
#    (fixtures/p03-jwks-rs256-basic.jsonl). A boot-time failure here
#    surfaces the root cause long before the parity runner bundles
#    it into a FAIL verdict.
# -----------------------------------------------------------------------------
say "smoke: GET ${DATA_URL}/anything without Authorization -> expect 401"
missing_code=$(curl -s -o /tmp/nginx-jwks.out -w '%{http_code}' \
    "${DATA_URL}/anything" || true)
[[ "${missing_code}" == "401" ]] \
    || { cat /tmp/nginx-jwks.out >&2
         fail "smoke: expected 401 without token, got ${missing_code}"; }

valid_token="$("${RS256_GEN_SCRIPT}" valid)"
say "smoke: GET ${DATA_URL}/anything with valid RS256 token (kid=${REFERENCE_KID}) -> expect 200"
valid_code=$(curl -s -o /tmp/nginx-jwks.out -w '%{http_code}' \
    -H "Authorization: Bearer ${valid_token}" \
    "${DATA_URL}/anything" || true)
[[ "${valid_code}" == "200" ]] \
    || { cat /tmp/nginx-jwks.out >&2
         fail "smoke: expected 200 with valid RS256 token, got ${valid_code}"; }

unknown_token="$("${RS256_GEN_SCRIPT}" unknown-kid)"
say "smoke: GET ${DATA_URL}/anything with RS256 token carrying unknown kid -> expect 401"
unknown_code=$(curl -s -o /tmp/nginx-jwks.out -w '%{http_code}' \
    -H "Authorization: Bearer ${unknown_token}" \
    "${DATA_URL}/anything" || true)
[[ "${unknown_code}" == "401" ]] \
    || { cat /tmp/nginx-jwks.out >&2
         fail "smoke: expected 401 with unknown-kid RS256 token, got ${unknown_code}"; }

say "nginx/p03-jwks-rs256-basic ready"
