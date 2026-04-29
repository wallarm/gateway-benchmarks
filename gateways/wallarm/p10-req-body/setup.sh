#!/usr/bin/env bash
# gateways/wallarm/p10-req-body/setup.sh
#
# Bootstrap the p10-req-body policy profile via the Wallarm Admin API.
#
# Canonical policy (docs/POLICIES.md § p09):
#   add:    $.bench.injected = true
#   remove: $.secret
#
# Wallarm API Gateway implementation:
#   - The gateway does not yet ship a dedicated `body_transform`
#     policy; the built-in registry is `lua_runner` + `ratelimit`
#     only (see admin-api OpenAPI, `PolicyBinding.policy_id`). The
#     Lua sandbox exposes `cjson.safe` and read/write `ctx.request.body`,
#     which is exactly the primitive body-rewrite needs.
#
#   - Buffering: service `streaming_mode` defaults to `buffered`
#     (admin-api-openapi.yaml), so the full request body is in
#     `ctx.request.body` before the policy fires.
#
#   - `Content-Length` is recomputed explicitly by the policy because
#     `ctx.request.body =` does not automatically update the header
#     (the wallarm router passes the payload through to upstream as-is).
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

# Client `/anything` → backend `/anything` (go-httpbin `/anything` is
# a catch-all that echoes method / headers / body / json, so the
# trailing-slash strip from wallarm is harmless here — unlike p07/p08
# where strict `/headers`/`/response-headers` 404 on trailing slash).
SERVICE_NAME="bench-p10-anything"
SERVICE_BASE_PATH="/anything"
SERVICE_TARGET_URL="${BACKEND_URL}/anything"

say()  { printf '%s %s\n' "$(date +'%H:%M:%S')" "$*" >&2; }
fail() { printf '\033[31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

# -----------------------------------------------------------------------------
# 1. Wait for the Admin API
# -----------------------------------------------------------------------------
say "wallarm/p10-req-body: bootstrap via ${ADMIN_URL}"
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
# 2. Register the service + catch-all route
# -----------------------------------------------------------------------------
service_body=$(jq -cn \
    --arg name    "${SERVICE_NAME}" \
    --arg bp      "${SERVICE_BASE_PATH}" \
    --arg backend "${SERVICE_TARGET_URL}" \
    '{name:$name, base_path:$bp, target:{endpoint:{url:$backend}}}')

http_code=$(curl --max-time 5 -sS -o /tmp/wallarm-p09.out -w '%{http_code}' \
    -X POST "${ADMIN_URL}/services" \
    -H "Content-Type: application/json" \
    -d "${service_body}" || true)

case "${http_code}" in
    200|201) say "  ✓ service ${SERVICE_NAME} (base_path=${SERVICE_BASE_PATH} → ${SERVICE_TARGET_URL})";;
    409)     say "  · service ${SERVICE_NAME} already exists";;
    *)       cat /tmp/wallarm-p09.out >&2
             fail "service create returned ${http_code}";;
esac

route_code=$(curl --max-time 5 -sS -o /tmp/wallarm-p09.out -w '%{http_code}' \
    -X POST "${ADMIN_URL}/services/${SERVICE_NAME}/routes" \
    -H "Content-Type: application/json" \
    -d '{"id":"catchall","condition":{"path":["/**"]}}' || true)
case "${route_code}" in
    200|201|409) say "  ✓ route catchall";;
    *) cat /tmp/wallarm-p09.out >&2
       fail "route create returned ${route_code}";;
esac

# -----------------------------------------------------------------------------
# 3. Bind the body-rewrite policy on the service's request_flow
#
# Robustness notes:
#
#   - If the incoming body is absent or not parseable as JSON, the
#     policy still injects `$.bench.injected = true` on an empty object
#     — matches the fixture's "rewrite works with empty body object"
#     probe, and keeps the invariant `$.bench.injected == true` on
#     every proxied request.
#
#   - `data.bench` is coerced to a table so that a non-table incoming
#     value (e.g. `"bench": "hello"`) cannot crash the policy.
#
#   - Content-Length is explicitly rewritten; Transfer-Encoding is not
#     touched because wallarm does not expose chunked framing to Lua —
#     when it ran, buffered mode already produced a fully-materialised
#     body with a known length.
# -----------------------------------------------------------------------------
read -r -d '' LUA_CODE <<'LUA' || true
function execute(ctx)
  local cjson = require("cjson.safe")
  local body = ctx.request.body or ""
  local data = cjson.decode(body)
  if type(data) ~= "table" then
    data = {}
  end
  if type(data.bench) ~= "table" then
    data.bench = {}
  end
  data.bench.injected = true
  data.secret = nil
  local new_body = cjson.encode(data)
  ctx.request.body = new_body
  ctx.request.headers["content-length"] = tostring(#new_body)
  return { action = "continue" }
end
LUA

flow_body=$(jq -cn \
    --arg code "${LUA_CODE}" \
    '{
        request_flow: [{
            policy_id:   "lua_runner",
            policy_name: "bench-p10-req-body",
            config:      { code: $code }
        }]
    }')

flow_code=$(curl --max-time 5 -sS -o /tmp/wallarm-p09.out -w '%{http_code}' \
    -X POST "${ADMIN_URL}/services/${SERVICE_NAME}/flow" \
    -H "Content-Type: application/json" \
    -d "${flow_body}" || true)
case "${flow_code}" in
    200|201) say "  ✓ lua_runner bound on request_flow (+\$.bench.injected, -\$.secret)";;
    *) cat /tmp/wallarm-p09.out >&2
       fail "flow bind returned ${flow_code}";;
esac

# -----------------------------------------------------------------------------
# 4. Smoke — confirm the body rewrite actually applied upstream
# -----------------------------------------------------------------------------
say "smoke: POST ${DATA_URL}/anything  body={msg:hi, secret:x}"
smoke=$(curl --max-time 5 -sS -X POST \
    -H 'Content-Type: application/json' \
    --data-binary '{"msg":"hi","secret":"drop-me"}' \
    "${DATA_URL}/anything")

# go-httpbin echoes the received (and thus rewritten) JSON into `.json`.
injected=$(jq -r '.json.bench.injected // empty' <<< "${smoke}")
leaked=$(jq -r   '.json.secret        // empty'  <<< "${smoke}")

[[ "${injected}" == "true" ]] \
    || { printf '%s\n' "${smoke}" >&2
         fail "smoke: backend did not see \$.bench.injected == true"; }
[[ -z "${leaked}" ]] \
    || { printf '%s\n' "${smoke}" >&2
         fail "smoke: backend still sees \$.secret (was '${leaked}')"; }

say "wallarm/p10-req-body ready"
