#!/usr/bin/env bash
# gateways/wallarm/p02-jwt/setup.sh
#
# Bootstrap the p02-jwt policy profile via the Wallarm Admin API.
#
# Canonical policy (docs/POLICIES.md § p02):
#   - HS256 validation against the shared benchmark secret
#   - token source: Authorization: Bearer <jwt>
#
# The image must expose `jwt_validation` in its policy registry —
# the script sanity-checks this against GET /policies at startup and
# exits FEATURE-MISSING (code 42) if the primitive is absent, which
# usually means the `WALLARM_IMAGE` override points at an old build.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

ADMIN_URL="${ADMIN_URL:-http://localhost:9081}"
DATA_URL="${DATA_URL:-http://localhost:9080}"
BACKEND_URL="${BACKEND_URL:-http://backend:8080}"
JWT_SECRET_FILE="${JWT_SECRET_FILE:-${REPO_ROOT}/gateways/_reference/jwt/secret.txt}"
JWT_GEN_SCRIPT="${JWT_GEN_SCRIPT:-${REPO_ROOT}/scripts/gen-jwt.sh}"

SERVICE_NAME="bench-p02-jwt"
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

[[ -f "${JWT_SECRET_FILE}" ]] || fail "JWT secret file not found: ${JWT_SECRET_FILE}"
[[ -x "${JWT_GEN_SCRIPT}" ]] || fail "JWT generator not executable: ${JWT_GEN_SCRIPT}"
JWT_SECRET="$(tr -d '\n' < "${JWT_SECRET_FILE}")"

# -----------------------------------------------------------------------------
# 1. Wait for the Admin API
# -----------------------------------------------------------------------------
say "wallarm/p02-jwt: bootstrap via ${ADMIN_URL}"
for _ in $(seq 1 60); do
    if curl -fsS "${ADMIN_URL}/health" >/dev/null 2>&1; then
        say "admin API ready"
        break
    fi
    sleep 1
done
curl -fsS "${ADMIN_URL}/health" >/dev/null 2>&1 \
    || fail "admin API did not come up at ${ADMIN_URL}"

# -----------------------------------------------------------------------------
# 2. Check whether the running image actually exposes jwt_validation
# -----------------------------------------------------------------------------
if ! curl -fsS "${ADMIN_URL}/policies" \
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

http_code=$(curl -sS -o /tmp/wallarm-p02.out -w '%{http_code}' \
    -X POST "${ADMIN_URL}/services" \
    -H "Content-Type: application/json" \
    -d "${service_body}" || true)

case "${http_code}" in
    200|201) say "  ✓ service ${SERVICE_NAME} (base_path=${SERVICE_BASE_PATH} → ${SERVICE_TARGET_URL})";;
    409)     say "  · service ${SERVICE_NAME} already exists";;
    *)       cat /tmp/wallarm-p02.out >&2
             fail "service create returned ${http_code}";;
esac

route_code=$(curl -sS -o /tmp/wallarm-p02.out -w '%{http_code}' \
    -X POST "${ADMIN_URL}/services/${SERVICE_NAME}/routes" \
    -H "Content-Type: application/json" \
    -d '{"id":"catchall","condition":{"path":["/**"]}}' || true)
case "${route_code}" in
    200|201|409) say "  ✓ route catchall";;
    *) cat /tmp/wallarm-p02.out >&2
       fail "route create returned ${route_code}";;
esac

# -----------------------------------------------------------------------------
# 4. Bind native jwt_validation on the service request_flow
# -----------------------------------------------------------------------------
flow_body=$(jq -cn \
    --arg secret "${JWT_SECRET}" \
    '{
        request_flow: [{
            policy_id:   "jwt_validation",
            policy_name: "bench-p02-jwt",
            config: {
                algorithm:  "HS256",
                secret_key: $secret
            }
        }]
    }')

flow_code=$(curl -sS -o /tmp/wallarm-p02.out -w '%{http_code}' \
    -X POST "${ADMIN_URL}/services/${SERVICE_NAME}/flow" \
    -H "Content-Type: application/json" \
    -d "${flow_body}" || true)
case "${flow_code}" in
    200|201) say "  ✓ jwt_validation bound on request_flow";;
    *) cat /tmp/wallarm-p02.out >&2
       fail "flow bind returned ${flow_code}";;
esac

# -----------------------------------------------------------------------------
# 5. Smoke — missing token must fail, valid token must pass
# -----------------------------------------------------------------------------
say "smoke: GET ${DATA_URL}/anything without Authorization"
missing_code=$(curl -s -o /tmp/wallarm-p02.out -w '%{http_code}' "${DATA_URL}/anything" || true)
[[ "${missing_code}" == "401" ]] \
    || { cat /tmp/wallarm-p02.out >&2
         fail "smoke: expected 401 without token, got ${missing_code}"; }

valid_token="$("${JWT_GEN_SCRIPT}" valid)"
say "smoke: GET ${DATA_URL}/anything with valid HS256 token"
valid_code=$(curl -s -o /tmp/wallarm-p02.out -w '%{http_code}' \
    -H "Authorization: Bearer ${valid_token}" \
    "${DATA_URL}/anything" || true)
[[ "${valid_code}" == "200" ]] \
    || { cat /tmp/wallarm-p02.out >&2
         fail "smoke: expected 200 with valid token, got ${valid_code}"; }

jq -c '{smoke:"ok", method:.method, url:.url}' /tmp/wallarm-p02.out >&2 || true

say "wallarm/p02-jwt ready"
