#!/usr/bin/env bash
# gateways/wallarm/p11-resp-body/setup.sh
#
# Bootstrap the p11-resp-body policy profile via the Wallarm Admin API.
#
# Canonical policy (docs/POLICIES.md § p10):
#   add:    $.bench.injected = true
#   remove: $.origin
#
# Wallarm API Gateway implementation:
#   - `lua_runner` on `response_flow` at the service level; same
#     idiom as p09 but on the outbound path.
#   - `go-httpbin` always emits `$.origin` (client IP), so the drop
#     rule is always exercised — regardless of fixture shape.
#   - `Content-Length` is explicitly recomputed after the rewrite,
#     otherwise the gateway sends the new JSON body with the original
#     header value, which either truncates the payload or leaves
#     the client hanging on a keep-alive (see
#     `response_flow_gaps_test.sh` L378 for the canonical pattern).
#
# Environment:
#   ADMIN_URL     (default http://localhost:9081) - Admin API base
#   DATA_URL      (default http://localhost:9080) - data plane (smoke)
#   BACKEND_URL   (default http://backend:8080)  - upstream, resolved
#                                                  from inside the gateway
#                                                  container via docker DNS
set -euo pipefail

ADMIN_URL="${ADMIN_URL:-http://localhost:9081}"
DATA_URL="${DATA_URL:-http://localhost:9080}"
BACKEND_URL="${BACKEND_URL:-http://backend:8080}"

# Same single-service layout as p09: go-httpbin `/anything` handles
# GET/POST alike and the trailing-slash strip is harmless.
SERVICE_NAME="bench-p11-anything"
SERVICE_BASE_PATH="/anything"
SERVICE_TARGET_URL="${BACKEND_URL}/anything"

say()  { printf '%s %s\n' "$(date +'%H:%M:%S')" "$*" >&2; }
fail() { printf '\033[31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

# -----------------------------------------------------------------------------
# 1. Wait for the Admin API
# -----------------------------------------------------------------------------
say "wallarm/p11-resp-body: bootstrap via ${ADMIN_URL}"
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
# 2. Register the service + catch-all route
# -----------------------------------------------------------------------------
service_body=$(jq -cn \
    --arg name    "${SERVICE_NAME}" \
    --arg bp      "${SERVICE_BASE_PATH}" \
    --arg backend "${SERVICE_TARGET_URL}" \
    '{name:$name, base_path:$bp, target:{endpoint:{url:$backend}}}')

http_code=$(curl -sS -o /tmp/wallarm-p10.out -w '%{http_code}' \
    -X POST "${ADMIN_URL}/services" \
    -H "Content-Type: application/json" \
    -d "${service_body}" || true)

case "${http_code}" in
    200|201) say "  ✓ service ${SERVICE_NAME} (base_path=${SERVICE_BASE_PATH} → ${SERVICE_TARGET_URL})";;
    409)     say "  · service ${SERVICE_NAME} already exists";;
    *)       cat /tmp/wallarm-p10.out >&2
             fail "service create returned ${http_code}";;
esac

route_code=$(curl -sS -o /tmp/wallarm-p10.out -w '%{http_code}' \
    -X POST "${ADMIN_URL}/services/${SERVICE_NAME}/routes" \
    -H "Content-Type: application/json" \
    -d '{"id":"catchall","condition":{"path":["/**"]}}' || true)
case "${route_code}" in
    200|201|409) say "  ✓ route catchall";;
    *) cat /tmp/wallarm-p10.out >&2
       fail "route create returned ${route_code}";;
esac

# -----------------------------------------------------------------------------
# 3. Bind the body-rewrite policy on the service's response_flow
#
# Robustness notes:
#
#   - If the upstream body is not parseable as JSON (e.g. upstream
#     returned an error page or a non-JSON 5xx), we pass it through
#     untouched. The policy only mutates well-formed JSON responses.
#
#   - `data.bench` is coerced to a table so that a non-table incoming
#     value (e.g. `"bench": "hello"` from some other upstream) cannot
#     crash the policy.
# -----------------------------------------------------------------------------
read -r -d '' LUA_CODE <<'LUA' || true
function execute(ctx)
  local cjson = require("cjson.safe")
  local body = ctx.response.body or ""
  local data = cjson.decode(body)
  if type(data) ~= "table" then
    return { action = "continue" }
  end
  if type(data.bench) ~= "table" then
    data.bench = {}
  end
  data.bench.injected = true
  data.origin = nil
  local new_body = cjson.encode(data)
  ctx.response.body = new_body
  ctx.response.headers["content-length"] = tostring(#new_body)
  return { action = "continue" }
end
LUA

flow_body=$(jq -cn \
    --arg code "${LUA_CODE}" \
    '{
        response_flow: [{
            policy_id:   "lua_runner",
            policy_name: "bench-p11-resp-body",
            config:      { code: $code }
        }]
    }')

flow_code=$(curl -sS -o /tmp/wallarm-p10.out -w '%{http_code}' \
    -X POST "${ADMIN_URL}/services/${SERVICE_NAME}/flow" \
    -H "Content-Type: application/json" \
    -d "${flow_body}" || true)
case "${flow_code}" in
    200|201) say "  ✓ lua_runner bound on response_flow (+\$.bench.injected, -\$.origin)";;
    *) cat /tmp/wallarm-p10.out >&2
       fail "flow bind returned ${flow_code}";;
esac

# -----------------------------------------------------------------------------
# 4. Smoke — confirm the response rewrite reaches the client
# -----------------------------------------------------------------------------
say "smoke: GET ${DATA_URL}/anything"
smoke=$(curl -sS "${DATA_URL}/anything")

injected=$(jq -r '.bench.injected // empty' <<< "${smoke}")
origin=$(jq -r   '.origin         // empty' <<< "${smoke}")

[[ "${injected}" == "true" ]] \
    || { printf '%s\n' "${smoke}" >&2
         fail "smoke: client did not see \$.bench.injected == true"; }
[[ -z "${origin}" ]] \
    || { printf '%s\n' "${smoke}" >&2
         fail "smoke: client still sees \$.origin (was '${origin}')"; }

say "wallarm/p11-resp-body ready"
