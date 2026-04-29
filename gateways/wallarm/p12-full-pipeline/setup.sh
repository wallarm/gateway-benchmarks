#!/usr/bin/env bash
# gateways/wallarm/p12-full-pipeline/setup.sh
#
# Bootstrap the p12-full-pipeline policy profile via the Wallarm Admin API.
#
# Canonical order (docs/POLICIES.md § p11):
#   request:  jwt_validation -> ratelimit -> req-headers -> req-body
#   response: resp-body -> resp-headers
#
# Like p02-jwt, this script sanity-checks `jwt_validation` in the
# running image's policy registry at startup and exits FEATURE-MISSING
# (code 42) if the primitive is absent — that means the
# `WALLARM_IMAGE` override points at an older build that doesn't ship
# the policies the benchmark exercises.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

ADMIN_URL="${ADMIN_URL:-http://localhost:9081}"
DATA_URL="${DATA_URL:-http://localhost:9080}"
BACKEND_URL="${BACKEND_URL:-http://backend:8080}"
JWT_SECRET_FILE="${JWT_SECRET_FILE:-${REPO_ROOT}/gateways/_reference/jwt/secret.txt}"
JWT_GEN_SCRIPT="${JWT_GEN_SCRIPT:-${REPO_ROOT}/scripts/gen-jwt.sh}"

SERVICE_NAME="bench-p12"
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
JWT_SECRET="$(tr -d '\r\n' < "${JWT_SECRET_FILE}")"

# -----------------------------------------------------------------------------
# 1. Wait for the Admin API
# -----------------------------------------------------------------------------
say "wallarm/p12-full-pipeline: bootstrap via ${ADMIN_URL}"
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

http_code=$(curl -sS -o /tmp/wallarm-p11.out -w '%{http_code}' \
    -X POST "${ADMIN_URL}/services" \
    -H "Content-Type: application/json" \
    -d "${service_body}" || true)

case "${http_code}" in
    200|201) say "  ✓ service ${SERVICE_NAME} (base_path=${SERVICE_BASE_PATH} → ${SERVICE_TARGET_URL})";;
    409)     say "  · service ${SERVICE_NAME} already exists";;
    *)       cat /tmp/wallarm-p11.out >&2
             fail "service create returned ${http_code}";;
esac

route_code=$(curl -sS -o /tmp/wallarm-p11.out -w '%{http_code}' \
    -X POST "${ADMIN_URL}/services/${SERVICE_NAME}/routes" \
    -H "Content-Type: application/json" \
    -d '{"id":"catchall","condition":{"path":["/**"]}}' || true)
case "${route_code}" in
    200|201|409) say "  ✓ route catchall";;
    *) cat /tmp/wallarm-p11.out >&2
       fail "route create returned ${route_code}";;
esac

# -----------------------------------------------------------------------------
# 4. Compose the full policy chain
# -----------------------------------------------------------------------------
read -r -d '' LUA_REQ_HEADERS <<'LUA' || true
function execute(ctx)
  ctx.request.headers["x-bench-in"] = "1"
  ctx.request.headers["x-forwarded-for"] = nil
  return { action = "continue" }
end
LUA

read -r -d '' LUA_REQ_BODY <<'LUA' || true
function execute(ctx)
  local cjson = require("cjson.safe")
  local raw_body = ctx.request.body or ""
  if raw_body == "" then
    ctx.request.headers["x-forwarded-for"] = nil
    return { action = "continue" }
  end
  local data = cjson.decode(raw_body) or {}
  if type(data) ~= "table" then data = {} end
  if type(data.bench) ~= "table" then data.bench = {} end
  data.bench.injected = true
  data.secret = nil
  local new_body = cjson.encode(data)
  ctx.request.body = new_body
  ctx.request.headers["x-forwarded-for"] = nil
  ctx.request.headers["content-length"] = tostring(#new_body)
  return { action = "continue" }
end
LUA

read -r -d '' LUA_RESP_BODY <<'LUA' || true
function execute(ctx)
  local cjson = require("cjson.safe")
  local data = cjson.decode(ctx.response.body or "")
  if type(data) ~= "table" then return { action = "continue" } end
  if type(data.bench) ~= "table" then data.bench = {} end
  data.bench.injected = true
  data.origin = nil
  local new_body = cjson.encode(data)
  ctx.response.body = new_body
  ctx.response.headers["content-length"] = tostring(#new_body)
  return { action = "continue" }
end
LUA

read -r -d '' LUA_RESP_HEADERS <<'LUA' || true
function execute(ctx)
  ctx.response.headers["x-bench-out"] = "1"
  ctx.response.headers["server"] = nil
  return { action = "continue" }
end
LUA

flow_body=$(jq -cn \
    --arg secret    "${JWT_SECRET}" \
    --arg lua_req_h "${LUA_REQ_HEADERS}" \
    --arg lua_req_b "${LUA_REQ_BODY}" \
    --arg lua_res_b "${LUA_RESP_BODY}" \
    --arg lua_res_h "${LUA_RESP_HEADERS}" \
    '{
        request_flow: [
            {
                policy_id:   "jwt_validation",
                policy_name: "bench-p12-jwt",
                config: {
                    algorithm:  "HS256",
                    secret_key: $secret
                }
            },
            {
                policy_id:   "ratelimit",
                policy_name: "bench-p12-rl",
                config: {
                    ratelimit_key: "bench-p12",
                    rate:          1000,
                    window:        1,
                    window_type:   "sliding",
                    scope:         "service"
                }
            },
            {
                policy_id:   "lua_runner",
                policy_name: "bench-p12-req-headers",
                config:      { code: $lua_req_h }
            },
            {
                policy_id:   "lua_runner",
                policy_name: "bench-p12-req-body",
                config:      { code: $lua_req_b }
            }
        ],
        response_flow: [
            {
                policy_id:   "lua_runner",
                policy_name: "bench-p12-resp-body",
                config:      { code: $lua_res_b }
            },
            {
                policy_id:   "lua_runner",
                policy_name: "bench-p12-resp-headers",
                config:      { code: $lua_res_h }
            }
        ]
    }')

flow_code=$(curl -sS -o /tmp/wallarm-p11.out -w '%{http_code}' \
    -X POST "${ADMIN_URL}/services/${SERVICE_NAME}/flow" \
    -H "Content-Type: application/json" \
    -d "${flow_body}" || true)
case "${flow_code}" in
    200|201) say "  ✓ full request/response flow bound";;
    *) cat /tmp/wallarm-p11.out >&2
       fail "flow bind returned ${flow_code}";;
esac

# -----------------------------------------------------------------------------
# 5. Smoke — one missing-token 401 and one happy-path transformed 200
# -----------------------------------------------------------------------------
say "smoke: POST ${DATA_URL}/anything without Authorization"
missing_code=$(curl -s -o /tmp/wallarm-p11.out -w '%{http_code}' \
    -X POST \
    -H 'Content-Type: application/json' \
    --data-binary '{"msg":"x"}' \
    "${DATA_URL}/anything" || true)
[[ "${missing_code}" == "401" ]] \
    || { cat /tmp/wallarm-p11.out >&2
         fail "smoke: expected 401 without token, got ${missing_code}"; }

valid_token="$("${JWT_GEN_SCRIPT}" valid)"
say "smoke: POST ${DATA_URL}/anything with valid token and JSON body"
happy_code=$(curl -sS \
    -D /tmp/wallarm-p11.headers \
    -o /tmp/wallarm-p11.body \
    -w '%{http_code}' \
    -X POST \
    -H "Authorization: Bearer ${valid_token}" \
    -H 'Content-Type: application/json' \
    -H 'X-Forwarded-For: 198.51.100.7' \
    --data-binary '{"msg":"hello","secret":"please-drop-me","bench":{"from_client":true}}' \
    "${DATA_URL}/anything" || true)
[[ "${happy_code}" == "200" ]] \
    || { cat /tmp/wallarm-p11.body >&2
         fail "smoke: expected 200 with valid token, got ${happy_code}"; }

body=/tmp/wallarm-p11.body
x_bench_out="$(
    awk 'tolower($1) == "x-bench-out:" {gsub(/\r/, "", $2); print $2}' /tmp/wallarm-p11.headers \
    | sed -n '$p'
)"
backend_bench_in="$(jq -r '.headers."X-Bench-In" // [] | .[]? // empty' "${body}")"
backend_xff="$(jq -r '.headers."X-Forwarded-For" // [] | .[]? // empty' "${body}")"
top_bench="$(jq -r '.bench.injected // empty' "${body}")"
req_bench="$(jq -r '.json.bench.injected // empty' "${body}")"
req_secret="$(jq -r '.json.secret // empty' "${body}")"
resp_origin="$(jq -r '.origin // empty' "${body}")"

[[ "${x_bench_out}" == "1" ]] || fail "smoke: client did not see X-Bench-Out: 1"
[[ "${backend_bench_in}" == "1" ]] || fail "smoke: backend did not see X-Bench-In: 1"
[[ -z "${backend_xff}" ]] || fail "smoke: backend still sees X-Forwarded-For: ${backend_xff}"
[[ "${top_bench}" == "true" ]] || fail "smoke: response body missing \$.bench.injected == true"
[[ "${req_bench}" == "true" ]] || fail "smoke: backend echo missing \$.json.bench.injected == true"
[[ -z "${req_secret}" ]] || fail "smoke: backend echo still contains \$.json.secret"
[[ -z "${resp_origin}" ]] || fail "smoke: response body still contains \$.origin"

jq -c '{smoke:"ok", top_bench:.bench.injected, req_bench:.json.bench.injected, backend_bench_in:.headers."X-Bench-In"}' "${body}" >&2 || true

say "wallarm/p12-full-pipeline ready"
