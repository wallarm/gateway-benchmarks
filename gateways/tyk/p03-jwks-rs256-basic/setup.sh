#!/usr/bin/env bash
# gateways/tyk/p03-jwks-rs256-basic/setup.sh
#
# Post-up readiness check + 3-probe smoke for the p03
# `p03-jwks-rs256-basic` scenario on tyk.
#
# Unlike wallarm (which bootstraps via Admin API) this profile is a
# file-config profile: the API definition and the permissive default
# policy are mounted at container start. There is nothing to POST.
# All the script has to prove is that:
#
#   1. Tyk booted and Redis is healthy (`/hello`).
#   2. Tyk loaded the API definition from /opt/tyk-gateway/apps
#      (`/tyk/apis` reports our api_id).
#   3. The canonical JWKS file behind the private `jwks-server` has
#      not drifted from `gateways/_reference/jwks-rs256/jwks.json`.
#   4. Three mini-probes — identical in shape to the fixture — return
#      the expected status codes before the parity runner fires a
#      single real probe:
#        - no Authorization header        → 401
#        - valid RS256 token, valid kid   → 200
#        - valid RS256 signature, wrong kid → 401
#
# Non-zero exit codes:
#   1  — generic FAIL (configuration error, container misbehaving)
#   42 — FEATURE-MISSING (reserved; currently not reachable here
#                         because Tyk ships RS256+JWKS natively)
#
# Why no dual-mode path? Tyk's `jwt_signing_method: rsa` +
# URL-based `jwt_source` has been stable since 3.x (see upstream
# release notes). The capability pass verified nothing changed in
# 5.11.1. If a future Tyk drops the URL path, *then* we add a
# FEATURE-MISSING branch here; for now a failure is a real failure.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

DATA_URL="${DATA_URL:-http://localhost:9080}"
TYK_SECRET="${TYK_SECRET:-gateway-benchmarks}"

JWKS_FILE="${JWKS_FILE:-${REPO_ROOT}/gateways/_reference/jwks-rs256/jwks.json}"
API_DEF_FILE="${API_DEF_FILE:-${SCRIPT_DIR}/apis/p03-jwks-rs256-basic.json}"
POLICIES_FILE="${POLICIES_FILE:-${REPO_ROOT}/gateways/tyk/_policies/policies.json}"
RS256_GEN_SCRIPT="${RS256_GEN_SCRIPT:-${REPO_ROOT}/scripts/gen-jwt-rs256.sh}"

SMOKE_OUT="/tmp/tyk-p03-jwks-rs256-basic.out"

say()  { printf '%s %s\n' "$(date +'%H:%M:%S')" "$*" >&2; }
fail() { printf '\033[31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

[[ -f "${JWKS_FILE}"       ]] || fail "reference JWKS not found: ${JWKS_FILE}"
[[ -f "${API_DEF_FILE}"    ]] || fail "API definition not found: ${API_DEF_FILE}"
[[ -f "${POLICIES_FILE}"   ]] || fail "policies file not found: ${POLICIES_FILE}"
[[ -x "${RS256_GEN_SCRIPT}" ]] || fail "RS256 generator not executable: ${RS256_GEN_SCRIPT}"

# -----------------------------------------------------------------------------
# 1. Wait for the gateway. `/hello` is Tyk's liveness endpoint — it
#    also reports Redis status, which is the dependency most likely
#    to delay boot on a cold machine.
# -----------------------------------------------------------------------------
say "tyk/p03-jwks-rs256-basic: waiting for ${DATA_URL}/hello"
hello_ok=0
for _ in $(seq 1 60); do
    hello=$(curl -sS --max-time 2 "${DATA_URL}/hello" 2>/dev/null || true)
    if [[ -n "${hello}" ]] \
       && printf '%s' "${hello}" | jq -e '.status == "pass"' >/dev/null 2>&1; then
        hello_ok=1
        break
    fi
    sleep 1
done
(( hello_ok == 1 )) || {
    printf '%s\n' "${hello:-<no body>}" >&2
    fail "tyk /hello never returned status=pass — is tyk-redis healthy?"
}
say "  ✓ /hello reports status=pass"

# -----------------------------------------------------------------------------
# 2. Confirm the API definition loaded. Tyk hot-loads JSON files
#    from /opt/tyk-gateway/apps at boot; if the JSON is malformed
#    it is silently skipped (error only in stderr). The admin API
#    is the authoritative way to confirm the definition made it in.
# -----------------------------------------------------------------------------
api_list=$(curl --max-time 5 -sS -H "X-Tyk-Authorization: ${TYK_SECRET}" \
               "${DATA_URL}/tyk/apis" 2>/dev/null || true)

if ! printf '%s' "${api_list}" \
        | jq -e 'any(.[]; .api_id == "p03-jwks-rs256-basic")' >/dev/null 2>&1; then
    printf 'admin /tyk/apis payload: %s\n' "${api_list:-<empty>}" >&2
    fail "API definition 'p03-jwks-rs256-basic' not registered — check docker logs gwb-tyk for JSON parse errors"
fi
say "  ✓ /tyk/apis knows api_id=p03-jwks-rs256-basic"

# -----------------------------------------------------------------------------
# 3. Drift guard — the JWKS the jwks-server is mounting MUST be the
#    same document as `gateways/_reference/jwks-rs256/jwks.json`.
#
#    Because docker-compose mounts the reference file as a read-only
#    bind mount, they *should* always be byte-identical. We still
#    diff here because a future iteration might decide to template
#    the JWKS into a committed artifact under the tyk tree, and this
#    check will catch any drift before the parity runner starts.
#
#    The comparison is done inside `jwks-server` so we capture what
#    Tyk actually sees over the network — not whatever happens to be
#    in the loadgen-side filesystem.
# -----------------------------------------------------------------------------
served_jwks=$(docker exec "${BENCH_CONTAINER_PREFIX:-gwb-tyk}-jwks-server" sh -c \
    'wget -qO- http://127.0.0.1/.well-known/jwks.json' 2>/dev/null || true)
[[ -n "${served_jwks}" ]] || fail "jwks-server returned empty body for /.well-known/jwks.json"

reference_n=$(jq -r '.keys[0].n'   "${JWKS_FILE}")
reference_kid=$(jq -r '.keys[0].kid' "${JWKS_FILE}")
[[ -n "${reference_n}"   && "${reference_n}"   != "null" ]] \
    || fail "reference JWKS has no .keys[0].n"
[[ -n "${reference_kid}" && "${reference_kid}" != "null" ]] \
    || fail "reference JWKS has no .keys[0].kid"

served_n=$(  printf '%s' "${served_jwks}" | jq -r '.keys[0].n')
served_kid=$(printf '%s' "${served_jwks}" | jq -r '.keys[0].kid')

[[ "${served_n}"   == "${reference_n}"   ]] \
    || fail "drift guard: jwks-server served modulus differs from ${JWKS_FILE##*/} (got ${served_n:0:24}…, expected ${reference_n:0:24}…)"
[[ "${served_kid}" == "${reference_kid}" ]] \
    || fail "drift guard: jwks-server served kid '${served_kid}' != reference kid '${reference_kid}'"
say "  ✓ drift guard: jwks-server is in sync with ${JWKS_FILE##*/} (kid=${reference_kid})"

# -----------------------------------------------------------------------------
# 4. Three mini-probes that mirror the fixture. `setup.sh` here is
#    DELIBERATELY LENIENT on the rejection status — Tyk 5.x's JWT
#    middleware uses non-standard HTTP codes for the two rejection
#    paths (`400 Authorization field missing` and `403 Key not
#    authorized`) rather than the 401 every other gateway returns.
#    The codes are hard-coded in tyk/gateway/mw_jwt.go and are not
#    configurable in Tyk Classic OSS.
#
#    The axis we measure — "JWT signature verified + JWKS kid lookup
#    is native" — is fully observable from the *shape* of the three
#    probe outcomes (4xx, 2xx, 4xx in the fixture's exact order),
#    which is what this smoke asserts. The exact-status divergence
#    (401 vs 400 / 403) is captured by the canonical parity runner
#    `scripts/parity-attestation.sh` as a documented deviation in
#    the resulting JSONL report (Tyk reports 1/3 PASS — probe 2
#    passes cleanly, probes 1 and 3 disagree on status code but
#    correctly reject).
#
#    We do NOT emit FEATURE-MISSING (exit 42) here because the
#    capability is present — it is just packaged behind a non-
#    canonical status-code convention. FEATURE-MISSING is reserved
#    for cases where the gateway cannot reject the request at all.
# -----------------------------------------------------------------------------
assert_4xx() {
    local code="$1" label="$2"
    [[ "${code}" =~ ^4[0-9]{2}$ ]] \
        || { cat "${SMOKE_OUT}" >&2
             fail "smoke (${label}): expected a 4xx rejection, got ${code}"; }
    if [[ "${code}" != "401" ]]; then
        say "  ⚠ ${label}: Tyk returned ${code} (non-standard; canonical fixture expects 401 — see NOTES.md)"
    fi
}

say "smoke: GET ${DATA_URL}/anything without Authorization"
missing_code=$(curl --max-time 5 -s -o "${SMOKE_OUT}" -w '%{http_code}' \
    "${DATA_URL}/anything" || true)
assert_4xx "${missing_code}" "no-auth"

valid_token="$("${RS256_GEN_SCRIPT}" valid)"
say "smoke: GET ${DATA_URL}/anything with valid RS256 token (kid=${reference_kid})"
valid_code=$(curl --max-time 5 -s -o "${SMOKE_OUT}" -w '%{http_code}' \
    -H "Authorization: Bearer ${valid_token}" \
    "${DATA_URL}/anything" || true)
[[ "${valid_code}" == "200" ]] \
    || { cat "${SMOKE_OUT}" >&2
         fail "smoke (valid-token): expected 200, got ${valid_code} — signature/kid lookup broken"; }

unknown_token="$("${RS256_GEN_SCRIPT}" unknown-kid)"
say "smoke: GET ${DATA_URL}/anything with RS256 token carrying unknown kid"
unknown_code=$(curl --max-time 5 -s -o "${SMOKE_OUT}" -w '%{http_code}' \
    -H "Authorization: Bearer ${unknown_token}" \
    "${DATA_URL}/anything" || true)
assert_4xx "${unknown_code}" "unknown-kid"

say "tyk/p03-jwks-rs256-basic ready (capability verified; status-code deviation logged above)"
