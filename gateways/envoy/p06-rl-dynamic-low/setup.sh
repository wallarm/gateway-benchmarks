#!/usr/bin/env bash
# gateways/envoy/p06-rl-dynamic-low/setup.sh
#
# Envoy reads the static bootstrap at container start; there is
# nothing to bootstrap at runtime. This script only proves that a
# single request carrying a fixture-listed X-Real-IP goes through the
# per-IP descriptor path cleanly before the burst probe hammers the
# buckets.
#
# Environment:
#   DATA_URL      (default http://localhost:9080) - data plane (smoke)
set -euo pipefail

DATA_URL="${DATA_URL:-http://localhost:9080}"

say()  { printf '%s %s\n' "$(date +'%H:%M:%S')" "$*" >&2; }
fail() { printf '\033[31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

# -----------------------------------------------------------------------------
# 1. Wait for the data plane. We carry X-Real-IP on the health-check so
#    we also smoke-test the descriptor path (not just the default bucket).
# -----------------------------------------------------------------------------
say "envoy/p06-rl-dynamic-low: waiting for ${DATA_URL}"
for _ in $(seq 1 30); do
    if curl -sS -o /dev/null --max-time 2 \
            -H 'X-Real-IP: 10.0.0.1' "${DATA_URL}/status/200" \
         2>/dev/null; then
        say "data plane ready"
        break
    fi
    sleep 1
done

# -----------------------------------------------------------------------------
# 2. Smoke — one below-limit GET with a fixture IP must succeed.
# -----------------------------------------------------------------------------
say "smoke: GET ${DATA_URL}/anything (X-Real-IP: 10.0.0.1, below limit)"
body=$(curl --max-time 5 -fsS -H 'X-Real-IP: 10.0.0.1' "${DATA_URL}/anything") \
    || fail "smoke /anything: curl --max-time 5 failed"
jq -e '.method == "GET"' <<<"${body}" >/dev/null \
    || { printf '%s\n' "${body}" >&2; fail "smoke /anything: .method not GET"; }

say "envoy/p06-rl-dynamic-low ready"
