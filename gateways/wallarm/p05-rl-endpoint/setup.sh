#!/usr/bin/env bash
# gateways/wallarm/p05-rl-endpoint/setup.sh
#
# Bootstrap the p05-rl-endpoint policy profile via the Wallarm Admin API.
#
# Canonical policy (docs/POLICIES.md § p04):
#   - 100 req/s, rolling 1-second window
#   - scope: ONE client-visible endpoint (`/anything/limited`)
#   - `/anything/free` must stay unrestricted
#   - 429 + Retry-After: 1 above the limit
#
# Wallarm API Gateway implementation — canonical route-level policy attach:
#
#   One service `bench-p05` at base_path=/anything, with TWO routes:
#
#       ┌─────────────────────────────────────────────────────────┐
#       │ route "limited" — condition path=[/limited, /limited/**]│
#       │   └─ POST /services/bench-p05/routes/limited/flow      │
#       │        policy_id=ratelimit, rate=100/1s, sliding        │
#       ├─────────────────────────────────────────────────────────┤
#       │ route "free" — condition path=[/free, /free/**]         │
#       │   └─ no flow binding → unrestricted                     │
#       └─────────────────────────────────────────────────────────┘
#
# The route-level `POST /services/<svc>/routes/<rt>/flow` endpoint is the
# wallarm idiom for "policy attached to one route only" — same mechanism
# envoy expresses via `typed_per_filter_config` on a route and nginx
# expresses via `limit_req` inside a `location` block. See wallarm
# admin API docs; the endpoint shape was confirmed during p02-jwt
# exploratory work (p02-jwt/NOTES.md § "Route-level flow is supported").
#
# Route ordering: `limited` is registered BEFORE `free` to hedge against
# a hypothetical "first defined wins" route-matching implementation in
# the Wallarm gateway. The conditions themselves are mutually exclusive
# (`/limited/**` vs `/free/**`) so ordering should not matter, but
# defining the rate-limited route first keeps the bucket on the path
# the fixture exercises.
#
# Path patterns: wallarm glob patterns are based on ant-style globs
# where `**` matches zero-or-more segments. We include BOTH `/limited`
# (exact) and `/limited/**` (with-suffix) in the condition list to be
# unambiguous across glob-engine variants. The fixture only exercises
# the exact form.
#
# Rate-limit key / scope: same idiom as p03 — `scope: "service"` with
# a constant `ratelimit_key` string collapses every request that
# REACHES this policy into a single bucket. Since the flow is bound
# only to the `limited` route, only `/limited` requests decrement the
# bucket — `/free` requests bypass it entirely.
#
# Rate/window: 100 rps, window=1s, `window_type: sliding` (same
# deviation as p03 — `window_type: fixed` with `window=1` is a no-op
# on the Wallarm gateway; see gateways/wallarm/p04-rl-static/NOTES.md § Deviation).
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

SERVICE_NAME="bench-p05"
SERVICE_PATH="/anything"
RL_RATE="${RL_RATE:-100}"
RL_WINDOW="${RL_WINDOW:-1}"
RL_WINDOW_TYPE="${RL_WINDOW_TYPE:-sliding}"
RL_KEY="${RL_KEY:-bench-p05-limited}"

say()  { printf '%s %s\n' "$(date +'%H:%M:%S')" "$*" >&2; }
fail() { printf '\033[31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

# -----------------------------------------------------------------------------
# 1. Wait for the Admin API
# -----------------------------------------------------------------------------
say "wallarm/p05-rl-endpoint: bootstrap via ${ADMIN_URL}"
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
# 2. Register the service at /anything (same INVALID_BASE_PATH workaround
#    as p01 — single service, two routes that split /anything by suffix).
# -----------------------------------------------------------------------------
body=$(jq -cn \
    --arg name    "${SERVICE_NAME}" \
    --arg bp      "${SERVICE_PATH}" \
    --arg backend "${BACKEND_URL}${SERVICE_PATH}" \
    '{name:$name, base_path:$bp, target:{endpoint:{url:$backend}}}')

http_code=$(curl -sS -o /tmp/wallarm-p04.out -w '%{http_code}' \
    -X POST "${ADMIN_URL}/services" \
    -H "Content-Type: application/json" \
    -d "${body}" || true)

case "${http_code}" in
    200|201) say "  ✓ service ${SERVICE_NAME} (base_path=${SERVICE_PATH})";;
    409)     say "  · service ${SERVICE_NAME} already exists";;
    *)       cat /tmp/wallarm-p04.out >&2
             fail "service create returned ${http_code}";;
esac

# -----------------------------------------------------------------------------
# 3. Register TWO routes: `limited` (rate-limited) and `free` (unrestricted).
#
# Ordering: `limited` first — see file header.
# Patterns: both exact + glob-suffix form for wallarm glob compatibility.
# -----------------------------------------------------------------------------
route_code=$(curl -sS -o /tmp/wallarm-p04.out -w '%{http_code}' \
    -X POST "${ADMIN_URL}/services/${SERVICE_NAME}/routes" \
    -H "Content-Type: application/json" \
    -d '{"id":"limited","condition":{"path":["/limited","/limited/**"]}}' || true)
case "${route_code}" in
    200|201|409) say "  ✓ route limited (path=/limited, /limited/**)";;
    *) cat /tmp/wallarm-p04.out >&2
       fail "route limited create returned ${route_code}";;
esac

route_code=$(curl -sS -o /tmp/wallarm-p04.out -w '%{http_code}' \
    -X POST "${ADMIN_URL}/services/${SERVICE_NAME}/routes" \
    -H "Content-Type: application/json" \
    -d '{"id":"free","condition":{"path":["/free","/free/**"]}}' || true)
case "${route_code}" in
    200|201|409) say "  ✓ route free (path=/free, /free/**)";;
    *) cat /tmp/wallarm-p04.out >&2
       fail "route free create returned ${route_code}";;
esac

# -----------------------------------------------------------------------------
# 4. Bind the rate-limit policy on the `limited` route ONLY.
#
# Using the *route* flow (not the service flow) ensures only requests
# that match this specific route participate in the bucket — which
# matches the "per-endpoint static rate limit" semantics of p04.
#
# Same rate shape as p03 but at 100 rps / 1 s (not 1000 rps / 1 s),
# and same `window_type: sliding` deviation (see p03 NOTES.md).
# -----------------------------------------------------------------------------
rl_config=$(jq -cn \
    --arg  key "${RL_KEY}" \
    --arg  win_type "${RL_WINDOW_TYPE}" \
    --argjson rate "${RL_RATE}" \
    --argjson win  "${RL_WINDOW}" \
    '{
        request_flow: [{
            policy_id:   "ratelimit",
            policy_name: "bench-p05-rl-endpoint",
            config: {
                ratelimit_key: $key,
                rate:          $rate,
                window:        $win,
                window_type:   $win_type,
                scope:         "service"
            }
        }]
    }')

flow_code=$(curl -sS -o /tmp/wallarm-p04.out -w '%{http_code}' \
    -X POST "${ADMIN_URL}/services/${SERVICE_NAME}/routes/limited/flow" \
    -H "Content-Type: application/json" \
    -d "${rl_config}" || true)
case "${flow_code}" in
    200|201) say "  ✓ rate-limit policy bound on route 'limited' (rate=${RL_RATE}/${RL_WINDOW}s, ${RL_WINDOW_TYPE})";;
    *) cat /tmp/wallarm-p04.out >&2
       fail "route-level flow bind returned ${flow_code}";;
esac

# -----------------------------------------------------------------------------
# 5. Smoke — both endpoints answer 200 on the very first request.
# -----------------------------------------------------------------------------
say "smoke: GET ${DATA_URL}/anything/limited (below 100 rps)"
smoke_code=$(curl -s -o /tmp/wallarm-p04.out -w '%{http_code}' "${DATA_URL}/anything/limited" || true)
if [[ "${smoke_code}" != "200" ]]; then
    cat /tmp/wallarm-p04.out >&2
    fail "smoke /anything/limited: expected 200, got ${smoke_code}"
fi

say "smoke: GET ${DATA_URL}/anything/free (unrestricted)"
smoke_code=$(curl -s -o /tmp/wallarm-p04.out -w '%{http_code}' "${DATA_URL}/anything/free" || true)
if [[ "${smoke_code}" != "200" ]]; then
    cat /tmp/wallarm-p04.out >&2
    fail "smoke /anything/free: expected 200, got ${smoke_code}"
fi

say "wallarm/p05-rl-endpoint ready"
