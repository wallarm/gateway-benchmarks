#!/usr/bin/env bash
# gateways/envoy/p05-rl-endpoint/setup.sh
#
# Post-up smoke for envoy/p05-rl-endpoint. Envoy is a pure static-
# bootstrap gateway in this bench — the whole profile is expressed in
# envoy.yaml (HCM filter globally disabled + route-level override on
# `/anything/limited`). This script only proves:
#
#   1. the static bootstrap parsed (container started, :9080 answers);
#   2. the limited endpoint is reachable on a below-limit request;
#   3. the free endpoint is reachable and distinct from the limited
#      path (so the scoping invariant can later be exercised).
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
say "envoy/p05-rl-endpoint: waiting for ${DATA_URL}"
for _ in $(seq 1 30); do
    if curl -sS -o /dev/null --max-time 2 "${DATA_URL}/anything/free" 2>/dev/null; then
        say "data plane ready"
        break
    fi
    sleep 1
done

# -----------------------------------------------------------------------------
# 2. Smoke: /anything/limited (below limit) and /anything/free (unrestricted)
# -----------------------------------------------------------------------------
say "smoke: GET ${DATA_URL}/anything/limited (below 100 rps)"
body=$(curl --max-time 5 -fsS "${DATA_URL}/anything/limited") \
    || fail "smoke /anything/limited: curl --max-time 5 failed"
jq -e '.method == "GET"' <<<"${body}" >/dev/null \
    || { printf '%s\n' "${body}" >&2; fail "smoke /anything/limited: .method not GET"; }

say "smoke: GET ${DATA_URL}/anything/free (unrestricted)"
body=$(curl --max-time 5 -fsS "${DATA_URL}/anything/free") \
    || fail "smoke /anything/free: curl --max-time 5 failed"
jq -e '.method == "GET"' <<<"${body}" >/dev/null \
    || { printf '%s\n' "${body}" >&2; fail "smoke /anything/free: .method not GET"; }

say "envoy/p05-rl-endpoint ready"
