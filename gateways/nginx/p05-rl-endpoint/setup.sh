#!/usr/bin/env bash
# gateways/nginx/p05-rl-endpoint/setup.sh
#
# Post-up smoke for nginx/p05-rl-endpoint. nginx has no admin API —
# the rate-limit policy and its endpoint scoping are fully expressed
# in nginx.conf. This script only proves that:
#
#   1. the config parsed (container started, :9080 is accepting);
#   2. the limited endpoint is reachable on a below-limit request;
#   3. the free endpoint is reachable (the scoping check that the
#      fixture's `status_429_max: 0` burst will later exercise in
#      earnest).
#
# Environment:
#   DATA_URL      (default http://localhost:9080) - data plane (smoke)
set -euo pipefail

DATA_URL="${DATA_URL:-http://localhost:9080}"

say()  { printf '%s %s\n' "$(date +'%H:%M:%S')" "$*" >&2; }
fail() { printf '\033[31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

# -----------------------------------------------------------------------------
# 1. Wait for the data plane
# -----------------------------------------------------------------------------
say "nginx/p05-rl-endpoint: waiting for ${DATA_URL}"
for _ in $(seq 1 30); do
    if curl -sS -o /dev/null --max-time 2 "${DATA_URL}/anything/free" 2>/dev/null; then
        say "data plane ready"
        break
    fi
    sleep 1
done

# -----------------------------------------------------------------------------
# 2. Smoke: /anything/limited (below limit) and /anything/free
# -----------------------------------------------------------------------------
say "smoke: GET ${DATA_URL}/anything/limited (below 100 rps)"
body=$(curl -fsS "${DATA_URL}/anything/limited") \
    || fail "smoke /anything/limited: curl failed"
jq -e '.method == "GET"' <<<"${body}" >/dev/null \
    || { printf '%s\n' "${body}" >&2; fail "smoke /anything/limited: .method not GET"; }

say "smoke: GET ${DATA_URL}/anything/free (unrestricted)"
body=$(curl -fsS "${DATA_URL}/anything/free") \
    || fail "smoke /anything/free: curl failed"
jq -e '.method == "GET"' <<<"${body}" >/dev/null \
    || { printf '%s\n' "${body}" >&2; fail "smoke /anything/free: .method not GET"; }

say "nginx/p05-rl-endpoint ready"
