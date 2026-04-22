#!/usr/bin/env bash
# gateways/wallarm/p06-req-headers/setup.sh
#
# Bootstrap the p06-req-headers policy profile via the Wallarm Admin API.
#
# Canonical policy (docs/POLICIES.md § p06):
#   add:    X-Bench-In: 1
#   remove: X-Forwarded-For
#
# Wallarm 0.2.0 implementation:
#   - The public image does not ship a dedicated `header_transform`
#     policy; the built-in registry exposes `lua_runner` + `ratelimit`
#     only (see admin-api OpenAPI, `PolicyBinding.policy_id`). A
#     `lua_runner` policy is therefore the idiomatic vehicle on this
#     image — it is a single-line table write + delete, so no crypto
#     primitives are needed.
#
#   - Base-path strip: wallarm 0.2.0 strips `base_path` and prepends
#     `target.endpoint.url`, always leaving a trailing `/` between
#     the two halves (verified against p01: `GET /anything` → upstream
#     sees `/anything/`). go-httpbin 404s on `/headers/`, so we can't
#     point the service directly at `/headers`. Instead we route via
#     go-httpbin's `/anything/<slug>` catch-all — it echoes request
#     headers in the same `.headers` JSON shape (`"X-Foo": ["v"]`),
#     which is exactly what the fixture asserts on.
#
# NOTE: the headers are set in lower-case on the Lua side because the
# guide (policy-development-guide.md §3) flags `ctx.request.headers`
# as a case-insensitive table — lower-case writes are the canonical form.
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

# `/headers` on the client side → `/anything/headers` on the backend
# side (wallarm forwards `<target.url>/<stripped-suffix>/`, which
# becomes `/anything/headers/` — a 200-echo path on go-httpbin).
SERVICE_NAME="bench-p06-headers"
SERVICE_BASE_PATH="/headers"
SERVICE_TARGET_URL="${BACKEND_URL}/anything/headers"

say()  { printf '%s %s\n' "$(date +'%H:%M:%S')" "$*" >&2; }
fail() { printf '\033[31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

# -----------------------------------------------------------------------------
# 1. Wait for the Admin API
# -----------------------------------------------------------------------------
say "wallarm/p06-req-headers: bootstrap via ${ADMIN_URL}"
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

http_code=$(curl -sS -o /tmp/wallarm-p06.out -w '%{http_code}' \
    -X POST "${ADMIN_URL}/services" \
    -H "Content-Type: application/json" \
    -d "${service_body}" || true)

case "${http_code}" in
    200|201) say "  ✓ service ${SERVICE_NAME} (base_path=${SERVICE_BASE_PATH} → ${SERVICE_TARGET_URL})";;
    409)     say "  · service ${SERVICE_NAME} already exists";;
    *)       cat /tmp/wallarm-p06.out >&2
             fail "service create returned ${http_code}";;
esac

route_code=$(curl -sS -o /tmp/wallarm-p06.out -w '%{http_code}' \
    -X POST "${ADMIN_URL}/services/${SERVICE_NAME}/routes" \
    -H "Content-Type: application/json" \
    -d '{"id":"catchall","condition":{"path":["/**"]}}' || true)
case "${route_code}" in
    200|201|409) say "  ✓ route catchall";;
    *) cat /tmp/wallarm-p06.out >&2
       fail "route create returned ${route_code}";;
esac

# -----------------------------------------------------------------------------
# 3. Bind the request-header-rewrite policy on the service's request_flow
# -----------------------------------------------------------------------------
read -r -d '' LUA_CODE <<'LUA' || true
function execute(ctx)
  ctx.request.headers["x-bench-in"] = "1"
  ctx.request.headers["x-forwarded-for"] = nil
  return { action = "continue" }
end
LUA

flow_body=$(jq -cn \
    --arg code "${LUA_CODE}" \
    '{
        request_flow: [{
            policy_id:   "lua_runner",
            policy_name: "bench-p06-req-headers",
            config:      { code: $code }
        }]
    }')

flow_code=$(curl -sS -o /tmp/wallarm-p06.out -w '%{http_code}' \
    -X POST "${ADMIN_URL}/services/${SERVICE_NAME}/flow" \
    -H "Content-Type: application/json" \
    -d "${flow_body}" || true)
case "${flow_code}" in
    200|201) say "  ✓ lua_runner bound on request_flow (+X-Bench-In, -X-Forwarded-For)";;
    *) cat /tmp/wallarm-p06.out >&2
       fail "flow bind returned ${flow_code}";;
esac

# -----------------------------------------------------------------------------
# 4. Smoke — confirm the policy actually took effect
# -----------------------------------------------------------------------------
say "smoke: GET ${DATA_URL}/headers  (with X-Forwarded-For: 1.2.3.4)"
smoke=$(curl -sS -H 'X-Forwarded-For: 1.2.3.4' "${DATA_URL}/headers")
jq -c '{smoke:"ok", bench_in:.headers."X-Bench-In", xff:.headers."X-Forwarded-For"}' <<< "${smoke}" >&2 || {
    printf '%s\n' "${smoke}" >&2
    fail "smoke: echo did not parse as JSON"
}

# Fail loudly if the policy did not apply — catches e.g. lua syntax errors
# or a silent bind mismatch before we hand off to parity-attestation.sh.
saw_bench_in=$(jq -r '.headers."X-Bench-In" // [] | .[]? // ""' <<< "${smoke}")
saw_xff=$(jq -r '.headers."X-Forwarded-For" // [] | .[]? // ""' <<< "${smoke}")
[[ "${saw_bench_in}" == "1" ]] || fail "smoke: backend did not see X-Bench-In: 1"
[[ -z "${saw_xff}" ]]          || fail "smoke: backend still sees X-Forwarded-For: ${saw_xff}"

say "wallarm/p06-req-headers ready"
