#!/usr/bin/env bash
# gateways/wallarm/p03-jwks-rs256-basic/setup.sh
#
# Bootstrap the `p03-jwks-rs256-basic` scenario via the
# Wallarm Admin API. This scenario is NOT part of the 12-profile core
# matrix; it lives alongside the parity framework and is invoked
# explicitly, for example:
#
#   make parity-gateway \
#       PARITY_GATEWAY=wallarm \
#       PARITY_PROFILE=p03-jwks-rs256-basic
#
# Canonical policy:
#   - Algorithm: RS256 (asymmetric, PKCS#1 v1.5 over SHA-256)
#   - Key material: static inline JWKS from
#     gateways/_reference/jwks-rs256/jwks.json (the first iteration
#     deliberately avoids `jwks_uri` so there's no moving network
#     component to debug).
#   - Token source: Authorization: Bearer <jwt>
#
# Sanity-check path mirroring p02-jwt: the script inspects
# `GET /policies` for `jwt_validation` at startup and exits
# FEATURE-MISSING (code 42) if the primitive is absent, which signals
# that `WALLARM_IMAGE` points at a build too old to exercise this
# p03 axis.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

ADMIN_URL="${ADMIN_URL:-http://localhost:9081}"
DATA_URL="${DATA_URL:-http://localhost:9080}"
BACKEND_URL="${BACKEND_URL:-http://backend:8080}"

JWKS_FILE="${JWKS_FILE:-${REPO_ROOT}/gateways/_reference/jwks-rs256/jwks.json}"
RS256_GEN_SCRIPT="${RS256_GEN_SCRIPT:-${REPO_ROOT}/scripts/gen-jwt-rs256.sh}"

SERVICE_NAME="bench-p03-jwks-rs256-basic"
SERVICE_BASE_PATH="/anything"
SERVICE_TARGET_URL="${BACKEND_URL}/anything"
FEATURE_MISSING_EXIT_CODE=42

say()  { printf '%s %s\n' "$(date +'%H:%M:%S')" "$*" >&2; }
fail() { printf '\033[31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }
feature_missing() {
    local reason="$1"
    printf '%s\n' "${reason}" >&2
    if [[ -n "${FEATURE_MISSING_REASON_FILE:-}" ]]; then
        printf '%s\n' "${reason}" > "${FEATURE_MISSING_REASON_FILE}"
    fi
    exit "${FEATURE_MISSING_EXIT_CODE}"
}

[[ -f "${JWKS_FILE}"       ]] || fail "JWKS not found: ${JWKS_FILE}"
[[ -x "${RS256_GEN_SCRIPT}" ]] || fail "RS256 generator not executable: ${RS256_GEN_SCRIPT}"

# The JWKS file ships as a JWKS document `{"keys": [...]}`. The
# jwt_validation policy expects the same shape (see
# wallarm-api-gateway/tests/integration/jwt_validation_test.sh test_07).
# Validate the JSON upfront so a subtle `n`/`e` typo surfaces here
# rather than as a cryptic 401 later.
jq -e '.keys | length > 0 and all(type=="object" and has("kid") and has("kty") and .kty=="RSA")' \
    "${JWKS_FILE}" >/dev/null \
    || fail "JWKS does not look like a JWKS document: ${JWKS_FILE}"

# -----------------------------------------------------------------------------
# 1. Wait for the Admin API
# -----------------------------------------------------------------------------
say "wallarm/p03-jwks-rs256-basic: bootstrap via ${ADMIN_URL}"
for _ in $(seq 1 60); do
    if curl --max-time 5 -fsS "${ADMIN_URL}/health" >/dev/null 2>&1; then
        say "admin API ready"
        break
    fi
    sleep 1
done
curl --max-time 5 -fsS "${ADMIN_URL}/health" >/dev/null 2>&1 \
    || fail "admin API did not come up at ${ADMIN_URL}"

# -----------------------------------------------------------------------------
# 2. Check whether the running image actually exposes jwt_validation
# -----------------------------------------------------------------------------
if ! curl --max-time 5 -fsS "${ADMIN_URL}/policies" \
        | jq -e '.policies[]? | select(.policy_id == "jwt_validation")' >/dev/null; then
    feature_missing "jwt_validation is not exposed by ${ADMIN_URL}/policies on this image"
fi
say "  ✓ jwt_validation present in registry"

# -----------------------------------------------------------------------------
# 3. Register the service + catch-all route
# -----------------------------------------------------------------------------
service_body=$(jq -cn \
    --arg name    "${SERVICE_NAME}" \
    --arg bp      "${SERVICE_BASE_PATH}" \
    --arg backend "${SERVICE_TARGET_URL}" \
    '{name:$name, base_path:$bp, target:{endpoint:{url:$backend}}}')

http_code=$(curl --max-time 5 -sS -o /tmp/wallarm-jwks.out -w '%{http_code}' \
    -X POST "${ADMIN_URL}/services" \
    -H "Content-Type: application/json" \
    -d "${service_body}" || true)

case "${http_code}" in
    200|201) say "  ✓ service ${SERVICE_NAME} (base_path=${SERVICE_BASE_PATH} → ${SERVICE_TARGET_URL})";;
    409)     say "  · service ${SERVICE_NAME} already exists";;
    *)       cat /tmp/wallarm-jwks.out >&2
             fail "service create returned ${http_code}";;
esac

route_code=$(curl --max-time 5 -sS -o /tmp/wallarm-jwks.out -w '%{http_code}' \
    -X POST "${ADMIN_URL}/services/${SERVICE_NAME}/routes" \
    -H "Content-Type: application/json" \
    -d '{"id":"catchall","condition":{"path":["/**"]}}' || true)
case "${route_code}" in
    200|201|409) say "  ✓ route catchall";;
    *) cat /tmp/wallarm-jwks.out >&2
       fail "route create returned ${route_code}";;
esac

# -----------------------------------------------------------------------------
# 4. Bind native jwt_validation with RS256 + inline JWKS
#
# The shape below matches
# wallarm-api-gateway/tests/integration/jwt_validation_test.sh §test_07:
#
#     set_jwt_flow "{
#         \"algorithm\": \"RS256\",
#         \"jwks\": {\"keys\": ${jwks_keys}}
#     }"
#
# The p03-jwks-rs256-basic scenario deliberately omits `issuer` / `audience` to
# keep the first iteration minimal — we only measure the JWKS-lookup
# path (kid → JWK → RS256 signature verify). Richer claim checks are
# intentionally deferred.
# -----------------------------------------------------------------------------
jwks_keys=$(jq -c '.keys' "${JWKS_FILE}")

flow_body=$(jq -cn \
    --argjson jwks_keys "${jwks_keys}" \
    '{
        request_flow: [{
            policy_id:   "jwt_validation",
            policy_name: "bench-p03-jwks-rs256-basic",
            config: {
                algorithm: "RS256",
                jwks: { keys: $jwks_keys }
            }
        }]
    }')

flow_code=$(curl --max-time 5 -sS -o /tmp/wallarm-jwks.out -w '%{http_code}' \
    -X POST "${ADMIN_URL}/services/${SERVICE_NAME}/flow" \
    -H "Content-Type: application/json" \
    -d "${flow_body}" || true)
case "${flow_code}" in
    200|201) say "  ✓ jwt_validation(RS256+JWKS) bound on request_flow";;
    400)
        # If the image ships jwt_validation but an older shape that
        # doesn't accept `jwks` / `RS256`, surface FEATURE-MISSING with
        # a crisp reason rather than a generic 400. This keeps the
        # p03-jwks-rs256-basic scenario well-behaved on any future intermediate
        # build where HS256 works but JWKS doesn't.
        body="$(cat /tmp/wallarm-jwks.out)"
        say "flow bind returned 400: ${body}"
        feature_missing "jwt_validation policy does not accept RS256+JWKS on this image"
        ;;
    *) cat /tmp/wallarm-jwks.out >&2
       fail "flow bind returned ${flow_code}";;
esac

# -----------------------------------------------------------------------------
# 5. Smoke — three mini-probes that mirror the fixture so a failure at
#    boot surfaces before the parity runner even starts.
# -----------------------------------------------------------------------------
say "smoke: GET ${DATA_URL}/anything without Authorization"
missing_code=$(curl --max-time 5 -s -o /tmp/wallarm-jwks.out -w '%{http_code}' "${DATA_URL}/anything" || true)
[[ "${missing_code}" == "401" ]] \
    || { cat /tmp/wallarm-jwks.out >&2
         fail "smoke: expected 401 without token, got ${missing_code}"; }

valid_token="$("${RS256_GEN_SCRIPT}" valid)"
say "smoke: GET ${DATA_URL}/anything with valid RS256 token (kid=bench-rs256-2026)"
valid_code=$(curl --max-time 5 -s -o /tmp/wallarm-jwks.out -w '%{http_code}' \
    -H "Authorization: Bearer ${valid_token}" \
    "${DATA_URL}/anything" || true)
[[ "${valid_code}" == "200" ]] \
    || { cat /tmp/wallarm-jwks.out >&2
         fail "smoke: expected 200 with valid RS256 token, got ${valid_code}"; }

unknown_token="$("${RS256_GEN_SCRIPT}" unknown-kid)"
say "smoke: GET ${DATA_URL}/anything with RS256 token carrying unknown kid"
unknown_code=$(curl --max-time 5 -s -o /tmp/wallarm-jwks.out -w '%{http_code}' \
    -H "Authorization: Bearer ${unknown_token}" \
    "${DATA_URL}/anything" || true)
[[ "${unknown_code}" == "401" ]] \
    || { cat /tmp/wallarm-jwks.out >&2
         fail "smoke: expected 401 with unknown-kid RS256 token, got ${unknown_code}"; }

jq -c '{smoke:"ok", method:.method, url:.url}' /tmp/wallarm-jwks.out >&2 || true

say "wallarm/p03-jwks-rs256-basic ready"
