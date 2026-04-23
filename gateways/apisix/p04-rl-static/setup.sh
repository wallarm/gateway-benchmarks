#!/usr/bin/env bash
# gateways/apisix/p04-rl-static/setup.sh
#
# Post-up smoke for apisix/p04-rl-static. Single-request smoke to
# confirm the rate-limit bucket is attached correctly and that below-
# limit traffic is served normally. The 1200-rps burst probe that
# actually engages the rate limit is handled by parity-attestation.
set -euo pipefail

DATA_URL="${DATA_URL:-http://localhost:9080}"

say()  { printf '%s %s\n' "$(date +'%H:%M:%S')" "$*" >&2; }
fail() { printf '\033[31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

say "apisix/p04-rl-static: waiting for ${DATA_URL}"
for _ in $(seq 1 30); do
    if curl -sS -o /dev/null --max-time 2 "${DATA_URL}/anything" 2>/dev/null; then
        say "data plane ready"
        break
    fi
    sleep 1
done

say "smoke: GET /anything below 1000 rps -> 200"
code=$(curl -sS -o /dev/null -w '%{http_code}' "${DATA_URL}/anything" || true)
[[ "${code}" == "200" ]] || fail "single below-limit request: expected 200, got ${code}"

say "apisix/p04-rl-static ready"
