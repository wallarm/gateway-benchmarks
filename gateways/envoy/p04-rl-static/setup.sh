#!/usr/bin/env bash
# gateways/envoy/p04-rl-static/setup.sh
#
# Envoy reads the static bootstrap at container start; there is
# nothing to bootstrap at runtime. This script only proves that a
# single request below the 1000 rps limit still goes through 200
# cleanly before the burst probe hammers the bucket.
#
# Environment:
#   DATA_URL      (default http://localhost:9080) - data plane (smoke)
set -euo pipefail

DATA_URL="${DATA_URL:-http://localhost:9080}"

say()  { printf '%s %s\n' "$(date +'%H:%M:%S')" "$*" >&2; }
fail() { printf '\033[31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

# -----------------------------------------------------------------------------
# 1. Wait for the data plane.
# -----------------------------------------------------------------------------
say "envoy/p04-rl-static: waiting for ${DATA_URL}"
for _ in $(seq 1 30); do
    if curl -sS -o /dev/null --max-time 2 "${DATA_URL}/status/200" \
         2>/dev/null; then
        say "data plane ready"
        break
    fi
    sleep 1
done

# -----------------------------------------------------------------------------
# 2. Smoke — one below-limit GET must succeed.
# -----------------------------------------------------------------------------
say "smoke: GET ${DATA_URL}/anything (below 1000 rps limit)"
code=$(curl -sS -o /dev/null -w '%{http_code}' "${DATA_URL}/anything" || true)
[[ "${code}" == "200" ]] \
    || fail "smoke /anything: expected 200, got ${code}"

say "envoy/p04-rl-static ready"
