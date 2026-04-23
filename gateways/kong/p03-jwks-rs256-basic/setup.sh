#!/usr/bin/env bash
# gateways/kong/p03-jwks-rs256-basic/setup.sh
#
# Post-up smoke + drift guard for kong/p03-jwks-rs256-basic.
#
# Kong loads the declarative config at container start (DB-less mode;
# see ../docker-compose.yaml), so there is no runtime bootstrap —
# the whole JWT/JWKS wiring lives in kong.yml's single-consumer
# `jwt_secrets` block plus the `jwt` plugin on the only service.
# This script only:
#
#   1. Waits for the data plane.
#   2. Drift guard: asserts the RSA public key embedded in kong.yml
#      still matches the canonical gateways/_reference/jwks-rs256/
#      public.pem. If the reference is ever rotated and someone
#      forgets to refresh kong.yml, this check fails loudly BEFORE a
#      single probe runs.
#   3. Smokes the three mini-probes that mirror the fixture so a
#      failure at boot surfaces before the parity runner even starts.
#
# Unlike gateways/wallarm/p03-jwks-rs256-basic/setup.sh there is no
# FEATURE-MISSING fallback path here: kong 3.x ships RS256 in the
# stock `jwt` plugin. If the plugin misbehaves this is a FAIL, not a
# FEATURE-MISSING.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

DATA_URL="${DATA_URL:-http://localhost:9080}"

REFERENCE_PEM="${REFERENCE_PEM:-${REPO_ROOT}/gateways/_reference/jwks-rs256/public.pem}"
REFERENCE_KID_FILE="${REFERENCE_KID_FILE:-${REPO_ROOT}/gateways/_reference/jwks-rs256/kid.txt}"
KONG_YML="${KONG_YML:-${SCRIPT_DIR}/kong.yml}"
RS256_GEN_SCRIPT="${RS256_GEN_SCRIPT:-${REPO_ROOT}/scripts/gen-jwt-rs256.sh}"

say()  { printf '%s %s\n' "$(date +'%H:%M:%S')" "$*" >&2; }
fail() { printf '\033[31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

[[ -f "${REFERENCE_PEM}"       ]] || fail "reference PEM not found: ${REFERENCE_PEM}"
[[ -f "${REFERENCE_KID_FILE}"  ]] || fail "reference kid file not found: ${REFERENCE_KID_FILE}"
[[ -f "${KONG_YML}"            ]] || fail "kong.yml not found: ${KONG_YML}"
[[ -x "${RS256_GEN_SCRIPT}"    ]] || fail "RS256 generator not executable: ${RS256_GEN_SCRIPT}"

# -----------------------------------------------------------------------------
# 1. Wait for the data plane.
#    With the `jwt` plugin on the only route, the proxy returns 401
#    as soon as kong finishes loading declarative config — that's the
#    readiness signal we want.
# -----------------------------------------------------------------------------
say "kong/p03-jwks-rs256-basic: waiting for ${DATA_URL}"
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
(( ready == 1 )) || fail "data plane never returned 401 on ${DATA_URL}/anything"

# -----------------------------------------------------------------------------
# 2. Drift guard — the `rsa_public_key` PEM baked into kong.yml MUST
#    be the byte-for-byte reference PEM, and the credential key MUST
#    be the canonical `kid`.
#
#    We use the same modulus-presence strategy as envoy's drift guard:
#    the reference RSA modulus is a uniquely-determined 342-char
#    base64url string (inside the PEM's base64 body after DER
#    unwrapping would split it into a modulus plus public exponent).
#    A literal-match of a 64-char interior PEM line against kong.yml
#    is strictly stronger than any structural check would give us in
#    this file — and it stays portable to bash + grep with no YAML
#    parser dependency.
#
#    We also pin the `kid` presence. This is the axis that turns
#    probe 3 (unknown-kid RS256) into a 401: if we do not stamp the
#    canonical kid into `consumers[].jwt_secrets[].key`, the unknown-
#    kid token would ALSO succeed because every token would map to
#    "no credential found" — which matches probe 3 by accident but
#    would silently break probe 2 (valid-kid RS256 → 200).
# -----------------------------------------------------------------------------
REFERENCE_KID=$(tr -d '\n' < "${REFERENCE_KID_FILE}")
[[ -n "${REFERENCE_KID}" ]] || fail "reference kid file is empty: ${REFERENCE_KID_FILE}"

# Pull out any second line of the reference PEM body — it is a
# canary interior line uniquely derived from the RSA private key.
# Bare `sed -n '2p'` on a PEM file always lands on a full 64-char
# base64 line (first line is `-----BEGIN ...-----`).
reference_pem_canary=$(sed -n '2p' "${REFERENCE_PEM}")
[[ -n "${reference_pem_canary}" ]] \
    || fail "failed to extract canary line from ${REFERENCE_PEM}"
[[ ${#reference_pem_canary} -ge 32 ]] \
    || fail "reference PEM canary too short (${#reference_pem_canary} chars); shape changed?"

if ! grep -qF "${reference_pem_canary}" "${KONG_YML}"; then
    fail "drift guard: ${KONG_YML} does not carry the reference PEM canary line (${reference_pem_canary:0:32}…). Regenerate the embedded RSA public key from ${REFERENCE_PEM} and paste the full PEM into kong.yml's rsa_public_key: | block."
fi
if ! grep -qF "key: ${REFERENCE_KID}" "${KONG_YML}"; then
    fail "drift guard: ${KONG_YML} does not carry the reference kid (${REFERENCE_KID}) as the consumer credential key. Check consumers[].jwt_secrets[].key."
fi
say "  ✓ drift guard: embedded RSA public key + kid still match ${REFERENCE_PEM##*/} (kid=${REFERENCE_KID})"

# -----------------------------------------------------------------------------
# 3. Smoke — three mini-probes that mirror the canonical fixture
#    (fixtures/p03-jwks-rs256-basic.jsonl). A boot-time failure here
#    surfaces the root cause long before the parity runner bundles
#    it into a FAIL verdict.
# -----------------------------------------------------------------------------
say "smoke: GET ${DATA_URL}/anything without Authorization -> expect 401"
missing_code=$(curl -s -o /tmp/kong-jwks.out -w '%{http_code}' \
    "${DATA_URL}/anything" || true)
[[ "${missing_code}" == "401" ]] \
    || { cat /tmp/kong-jwks.out >&2
         fail "smoke: expected 401 without token, got ${missing_code}"; }

valid_token="$("${RS256_GEN_SCRIPT}" valid)"
say "smoke: GET ${DATA_URL}/anything with valid RS256 token (kid=${REFERENCE_KID}) -> expect 200"
valid_code=$(curl -s -o /tmp/kong-jwks.out -w '%{http_code}' \
    -H "Authorization: Bearer ${valid_token}" \
    "${DATA_URL}/anything" || true)
[[ "${valid_code}" == "200" ]] \
    || { cat /tmp/kong-jwks.out >&2
         fail "smoke: expected 200 with valid RS256 token, got ${valid_code}"; }

unknown_token="$("${RS256_GEN_SCRIPT}" unknown-kid)"
say "smoke: GET ${DATA_URL}/anything with RS256 token carrying unknown kid -> expect 401"
unknown_code=$(curl -s -o /tmp/kong-jwks.out -w '%{http_code}' \
    -H "Authorization: Bearer ${unknown_token}" \
    "${DATA_URL}/anything" || true)
[[ "${unknown_code}" == "401" ]] \
    || { cat /tmp/kong-jwks.out >&2
         fail "smoke: expected 401 with unknown-kid RS256 token, got ${unknown_code}"; }

say "kong/p03-jwks-rs256-basic ready"
