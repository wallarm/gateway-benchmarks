#!/usr/bin/env bash
# gateways/wallarm/p05-rl-dynamic-high/setup.sh
#
# Bootstrap the p05-rl-dynamic-high policy profile via the Wallarm Admin API.
#
# Canonical policy (docs/POLICIES.md § p05):
#   - 100 req/s per client IP, rolling 1-second window
#   - key = X-Real-IP header (one bucket per distinct header value)
#   - 429 above the limit; 2xx below
#   - IP pool size (at the load side): 50 000
#
# Wallarm 0.2.0 implementation: same `ratelimit` + context-expression
# idiom as p04, only the `rate` parameter changes (10 → 100). See
# p04-rl-dynamic-low/NOTES.md for the rationale behind `scope: service`
# / `window_type: sliding`.
#
# Environment:
#   ADMIN_URL     (default http://localhost:9081) - Admin API base
#   DATA_URL      (default http://localhost:9080) - data plane (smoke)
#   BACKEND_URL   (default http://backend:8080)  - upstream, resolved
#                                                  from inside the gateway
#                                                  container via docker DNS
#   RL_RATE       (default 100)                  - rate per IP per window
#   RL_WINDOW     (default 1)                    - window length in seconds
#   RL_WINDOW_TYPE (default sliding)             - sliding|fixed
set -euo pipefail

ADMIN_URL="${ADMIN_URL:-http://localhost:9081}"
DATA_URL="${DATA_URL:-http://localhost:9080}"
BACKEND_URL="${BACKEND_URL:-http://backend:8080}"

SERVICE_NAME="bench-p05-anything"
SERVICE_PATH="/anything"
RL_RATE="${RL_RATE:-100}"
RL_WINDOW="${RL_WINDOW:-1}"
RL_WINDOW_TYPE="${RL_WINDOW_TYPE:-sliding}"
# shellcheck disable=SC2016  # we want the literal '${…}' context expression
RL_KEY='${request.headers.x-real-ip}'

say()  { printf '%s %s\n' "$(date +'%H:%M:%S')" "$*" >&2; }
fail() { printf '\033[31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

# -----------------------------------------------------------------------------
# 1. Wait for the Admin API
# -----------------------------------------------------------------------------
say "wallarm/p05-rl-dynamic-high: bootstrap via ${ADMIN_URL}"
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
body=$(jq -cn \
    --arg name    "${SERVICE_NAME}" \
    --arg bp      "${SERVICE_PATH}" \
    --arg backend "${BACKEND_URL}${SERVICE_PATH}" \
    '{name:$name, base_path:$bp, target:{endpoint:{url:$backend}}}')

http_code=$(curl -sS -o /tmp/wallarm-p05.out -w '%{http_code}' \
    -X POST "${ADMIN_URL}/services" \
    -H "Content-Type: application/json" \
    -d "${body}" || true)

case "${http_code}" in
    200|201) say "  ✓ service ${SERVICE_NAME} (base_path=${SERVICE_PATH})";;
    409)     say "  · service ${SERVICE_NAME} already exists";;
    *)       cat /tmp/wallarm-p05.out >&2
             fail "service create returned ${http_code}";;
esac

route_code=$(curl -sS -o /tmp/wallarm-p05.out -w '%{http_code}' \
    -X POST "${ADMIN_URL}/services/${SERVICE_NAME}/routes" \
    -H "Content-Type: application/json" \
    -d '{"id":"catchall","condition":{"path":["/**"]}}' || true)
case "${route_code}" in
    200|201|409) say "  ✓ route catchall";;
    *) cat /tmp/wallarm-p05.out >&2
       fail "route create returned ${route_code}";;
esac

# -----------------------------------------------------------------------------
# 3. Bind the ratelimit policy on the service's request_flow
# -----------------------------------------------------------------------------
rl_config=$(jq -cn \
    --arg  key "${RL_KEY}" \
    --arg  win_type "${RL_WINDOW_TYPE}" \
    --argjson rate "${RL_RATE}" \
    --argjson win  "${RL_WINDOW}" \
    '{
        request_flow: [{
            policy_id:   "ratelimit",
            policy_name: "bench-p05-rl-dynamic-high",
            config: {
                ratelimit_key: $key,
                rate:          $rate,
                window:        $win,
                window_type:   $win_type,
                scope:         "service"
            }
        }]
    }')

flow_code=$(curl -sS -o /tmp/wallarm-p05.out -w '%{http_code}' \
    -X POST "${ADMIN_URL}/services/${SERVICE_NAME}/flow" \
    -H "Content-Type: application/json" \
    -d "${rl_config}" || true)
case "${flow_code}" in
    200|201) say "  ✓ ratelimit bound (rate=${RL_RATE}/${RL_WINDOW}s per X-Real-IP, ${RL_WINDOW_TYPE})";;
    *) cat /tmp/wallarm-p05.out >&2
       fail "flow bind returned ${flow_code}";;
esac

# -----------------------------------------------------------------------------
# 4. Smoke — a single request with a unique IP should pass (200).
# -----------------------------------------------------------------------------
say "smoke: GET ${DATA_URL}/anything  (X-Real-IP: 10.5.99.99)"
smoke_code=$(curl -s -o /tmp/wallarm-p05.out -w '%{http_code}' \
    -H 'X-Real-IP: 10.5.99.99' \
    "${DATA_URL}/anything" || true)
if [[ "${smoke_code}" != "200" ]]; then
    cat /tmp/wallarm-p05.out >&2
    fail "smoke: expected 200, got ${smoke_code}"
fi
jq -c '{smoke:"ok", method:.method, url:.url}' /tmp/wallarm-p05.out >&2 || true

say "wallarm/p05-rl-dynamic-high ready"
