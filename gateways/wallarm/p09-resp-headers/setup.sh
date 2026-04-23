#!/usr/bin/env bash
# gateways/wallarm/p09-resp-headers/setup.sh
#
# Bootstrap the p09-resp-headers policy profile via the Wallarm Admin API.
#
# Canonical policy (docs/POLICIES.md § p08):
#   add:    X-Bench-Out: 1        (to the response)
#   remove: Server                (from the response)
#
# Wallarm API Gateway implementation:
#   - `lua_runner` on `response_flow` at the service level; same
#     idiom as p07 (see that profile's NOTES.md for the why).
#   - Two services (`bench-p09-rh` and `bench-p09-get`) because the
#     fixture covers two client-facing paths (`/response-headers`
#     and `/get`). Both route through go-httpbin's `/anything/<slug>`
#     catch-all to sidestep the trailing-slash strip (see NOTES.md).
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

say()  { printf '%s %s\n' "$(date +'%H:%M:%S')" "$*" >&2; }
fail() { printf '\033[31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

# -----------------------------------------------------------------------------
# 1. Wait for the Admin API
# -----------------------------------------------------------------------------
say "wallarm/p09-resp-headers: bootstrap via ${ADMIN_URL}"
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
# 2. Lua body (shared by both services)
# -----------------------------------------------------------------------------
read -r -d '' LUA_CODE <<'LUA' || true
function execute(ctx)
  ctx.response.headers["x-bench-out"] = "1"
  ctx.response.headers["server"] = nil
  return { action = "continue" }
end
LUA

# -----------------------------------------------------------------------------
# 3. Helper: create service + catchall route + bind lua on response_flow
# -----------------------------------------------------------------------------
create_service_with_lua_resp() {
    local name="$1" base_path="$2" target_url="$3"

    local svc_body
    svc_body=$(jq -cn \
        --arg name    "${name}" \
        --arg bp      "${base_path}" \
        --arg backend "${target_url}" \
        '{name:$name, base_path:$bp, target:{endpoint:{url:$backend}}}')

    local svc_code
    svc_code=$(curl -sS -o /tmp/wallarm-p08.out -w '%{http_code}' \
        -X POST "${ADMIN_URL}/services" \
        -H "Content-Type: application/json" \
        -d "${svc_body}" || true)
    case "${svc_code}" in
        200|201) say "  ✓ service ${name} (base_path=${base_path} → ${target_url})";;
        409)     say "  · service ${name} already exists";;
        *)       cat /tmp/wallarm-p08.out >&2
                 fail "service ${name} create returned ${svc_code}";;
    esac

    local route_code
    route_code=$(curl -sS -o /tmp/wallarm-p08.out -w '%{http_code}' \
        -X POST "${ADMIN_URL}/services/${name}/routes" \
        -H "Content-Type: application/json" \
        -d '{"id":"catchall","condition":{"path":["/**"]}}' || true)
    case "${route_code}" in
        200|201|409) ;;
        *) cat /tmp/wallarm-p08.out >&2
           fail "service ${name} route create returned ${route_code}";;
    esac

    local flow_body
    flow_body=$(jq -cn \
        --arg code "${LUA_CODE}" \
        --arg pname "${name}-resp-headers" \
        '{
            response_flow: [{
                policy_id:   "lua_runner",
                policy_name: $pname,
                config:      { code: $code }
            }]
        }')

    local flow_code
    flow_code=$(curl -sS -o /tmp/wallarm-p08.out -w '%{http_code}' \
        -X POST "${ADMIN_URL}/services/${name}/flow" \
        -H "Content-Type: application/json" \
        -d "${flow_body}" || true)
    case "${flow_code}" in
        200|201) say "    ✓ lua_runner bound on response_flow (+X-Bench-Out, -Server)";;
        *) cat /tmp/wallarm-p08.out >&2
           fail "flow bind returned ${flow_code}";;
    esac
}

# -----------------------------------------------------------------------------
# 4. Register both services
#
# Client path        → backend-side target                         (via /anything
#                                                                    catch-all to
#                                                                    dodge the
#                                                                    trailing-slash
#                                                                    strip; see
#                                                                    NOTES.md)
# /response-headers  → http://backend:8080/anything/response-headers
# /get               → http://backend:8080/anything/get
# -----------------------------------------------------------------------------
create_service_with_lua_resp \
    "bench-p09-rh"  "/response-headers" "${BACKEND_URL}/anything/response-headers"
create_service_with_lua_resp \
    "bench-p09-get" "/get"              "${BACKEND_URL}/anything/get"

# -----------------------------------------------------------------------------
# 5. Smoke — confirm the response-flow policy fired on both paths
# -----------------------------------------------------------------------------
say "smoke: GET ${DATA_URL}/get"
hdr=$(curl -sS -o /dev/null -D - "${DATA_URL}/get" | tr -d '\r')
grep -qi '^x-bench-out: 1' <<< "${hdr}" \
    || { printf '%s\n' "${hdr}" >&2; fail "smoke: X-Bench-Out not found on /get"; }

say "smoke: GET ${DATA_URL}/response-headers?Server=dropme"
hdr=$(curl -sS -o /dev/null -D - "${DATA_URL}/response-headers?Server=dropme" | tr -d '\r')
grep -qi '^x-bench-out: 1' <<< "${hdr}" \
    || { printf '%s\n' "${hdr}" >&2; fail "smoke: X-Bench-Out not found on /response-headers"; }
grep -qi '^server:'        <<< "${hdr}" \
    && { printf '%s\n' "${hdr}" >&2; fail "smoke: Server header still present"; }

say "wallarm/p09-resp-headers ready"
