#!/usr/bin/env bash
# gateways/nginx/p05-rl-dynamic-high/setup.sh
#
# Post-up smoke for nginx/p05-rl-dynamic-high. nginx has no admin
# API — the rate-limit policy is fully expressed in nginx.conf. This
# script only proves the config parsed cleanly and the per-IP bucket
# path is reachable before the parity burst probe runs.
#
# The real per-IP RL attestation is delivered by
# scripts/parity-attestation.sh::run_burst_probe.
#
# Environment:
#   DATA_URL      (default http://localhost:9080) - data plane (smoke)
set -euo pipefail

DATA_URL="${DATA_URL:-http://localhost:9080}"

say()  { printf '%s %s\n' "$(date +'%H:%M:%S')" "$*" >&2; }
fail() { printf '\033[31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

say "nginx/p05-rl-dynamic-high: waiting for ${DATA_URL}"
for _ in $(seq 1 30); do
    if curl -sS -o /dev/null --max-time 2 \
            -H 'X-Real-IP: 10.5.0.1' "${DATA_URL}/anything" 2>/dev/null; then
        say "data plane ready"
        break
    fi
    sleep 1
done

say "smoke: GET ${DATA_URL}/anything (X-Real-IP: 10.5.0.1, below limit)"
body=$(curl -fsS -H 'X-Real-IP: 10.5.0.1' "${DATA_URL}/anything") \
    || fail "smoke /anything: curl failed"
jq -e '.method == "GET"' <<<"${body}" >/dev/null \
    || { printf '%s\n' "${body}" >&2; fail "smoke /anything: .method not GET"; }

say "nginx/p05-rl-dynamic-high ready"
