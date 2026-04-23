#!/usr/bin/env bash
# gateways/wallarm/p04-rl-static/setup.sh
#
# Bootstrap the p04-rl-static policy profile via the Wallarm Admin API.
#
# Canonical policy (docs/POLICIES.md § p03):
#   - 1000 req/s per service, rolling 1-second window
#   - single bucket (all requests share one key)
#   - 429 above the limit
#
# Wallarm API Gateway implementation:
#   - policy_id:   "ratelimit"   (built-in; see /policies)
#   - scope:       "service"     (all routes of this service → one bucket)
#   - window_type: "sliding"     (see NOTES.md — fixed/window=1 is a no-op
#                                 in the pinned build; sliding with
#                                 window=1 produces the expected 429s.)
#   - rate:        1000
#   - window:      1
#   - ratelimit_key: static "bench-p04"
#       (the policy accepts a plain string as a constant key; every
#        request collapses into one bucket, which is the "static
#        service-wide" semantics of docs/POLICIES.md § p03.)
#
# NOTE: same INVALID_BASE_PATH workaround as p01 — register one service
# per path prefix used by the fixture (just /anything for p03).
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

SERVICE_NAME="bench-anything"
SERVICE_PATH="/anything"
RL_RATE="${RL_RATE:-1000}"
RL_WINDOW="${RL_WINDOW:-1}"
RL_WINDOW_TYPE="${RL_WINDOW_TYPE:-sliding}"
RL_KEY="${RL_KEY:-bench-p04}"

say()  { printf '%s %s\n' "$(date +'%H:%M:%S')" "$*" >&2; }
fail() { printf '\033[31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

# -----------------------------------------------------------------------------
# 1. Wait for the Admin API
# -----------------------------------------------------------------------------
say "wallarm/p04-rl-static: bootstrap via ${ADMIN_URL}"
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
# 2. Register the service + route (same INVALID_BASE_PATH workaround as p01)
# -----------------------------------------------------------------------------
body=$(jq -cn \
    --arg name    "${SERVICE_NAME}" \
    --arg bp      "${SERVICE_PATH}" \
    --arg backend "${BACKEND_URL}${SERVICE_PATH}" \
    '{name:$name, base_path:$bp, target:{endpoint:{url:$backend}}}')

http_code=$(curl -sS -o /tmp/wallarm-p03.out -w '%{http_code}' \
    -X POST "${ADMIN_URL}/services" \
    -H "Content-Type: application/json" \
    -d "${body}" || true)

case "${http_code}" in
    200|201) say "  ✓ service ${SERVICE_NAME} (base_path=${SERVICE_PATH})";;
    409)     say "  · service ${SERVICE_NAME} already exists";;
    *)       cat /tmp/wallarm-p03.out >&2
             fail "service create returned ${http_code}";;
esac

route_code=$(curl -sS -o /tmp/wallarm-p03.out -w '%{http_code}' \
    -X POST "${ADMIN_URL}/services/${SERVICE_NAME}/routes" \
    -H "Content-Type: application/json" \
    -d '{"id":"catchall","condition":{"path":["/**"]}}' || true)
case "${route_code}" in
    200|201|409) say "  ✓ route catchall";;
    *) cat /tmp/wallarm-p03.out >&2
       fail "route create returned ${route_code}";;
esac

# -----------------------------------------------------------------------------
# 3. Bind the rate-limit policy at the service flow level
#
# Using the *service* flow (not the route flow) ensures every route of
# the service shares one bucket — which matches the "static service-wide"
# semantics of profile p03.
# -----------------------------------------------------------------------------
rl_config=$(jq -cn \
    --arg  key "${RL_KEY}" \
    --arg  win_type "${RL_WINDOW_TYPE}" \
    --argjson rate "${RL_RATE}" \
    --argjson win  "${RL_WINDOW}" \
    '{
        request_flow: [{
            policy_id:   "ratelimit",
            policy_name: "bench-p04-rl-static",
            config: {
                ratelimit_key: $key,
                rate:          $rate,
                window:        $win,
                window_type:   $win_type,
                scope:         "service"
            }
        }]
    }')

flow_code=$(curl -sS -o /tmp/wallarm-p03.out -w '%{http_code}' \
    -X POST "${ADMIN_URL}/services/${SERVICE_NAME}/flow" \
    -H "Content-Type: application/json" \
    -d "${rl_config}" || true)
case "${flow_code}" in
    200|201) say "  ✓ rate-limit policy bound (rate=${RL_RATE}/${RL_WINDOW}s, ${RL_WINDOW_TYPE})";;
    *) cat /tmp/wallarm-p03.out >&2
       fail "flow bind returned ${flow_code}";;
esac

# -----------------------------------------------------------------------------
# 4. Smoke — confirm the data plane proxies and returns a 200 on
#    the very first request (below the 1000 rps limit).
# -----------------------------------------------------------------------------
say "smoke: GET ${DATA_URL}/anything"
smoke_code=$(curl -s -o /tmp/wallarm-p03.out -w '%{http_code}' "${DATA_URL}/anything" || true)
if [[ "${smoke_code}" != "200" ]]; then
    cat /tmp/wallarm-p03.out >&2
    fail "smoke: expected 200, got ${smoke_code}"
fi
jq -c '{smoke:"ok", method:.method, url:.url}' /tmp/wallarm-p03.out >&2 || true

say "wallarm/p04-rl-static ready"
