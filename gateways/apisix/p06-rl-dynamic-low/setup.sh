#!/usr/bin/env bash
# gateways/apisix/p06-rl-dynamic-low/setup.sh
set -euo pipefail

DATA_URL="${DATA_URL:-http://localhost:9080}"

say()  { printf '%s %s\n' "$(date +'%H:%M:%S')" "$*" >&2; }
fail() { printf '\033[31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

say "apisix/p06-rl-dynamic-low: waiting for ${DATA_URL}"
for _ in $(seq 1 30); do
    if curl -sS -o /dev/null --max-time 2 "${DATA_URL}/anything" 2>/dev/null; then
        say "data plane ready"
        break
    fi
    sleep 1
done

say "smoke: GET /anything with a fresh X-Real-IP below 10 rps -> 200"
code=$(curl --max-time 5 -sS -o /dev/null -w '%{http_code}' \
    -H 'X-Real-IP: 10.0.0.254' \
    "${DATA_URL}/anything" || true)
[[ "${code}" == "200" ]] || fail "single per-IP below-limit request: expected 200, got ${code}"

say "apisix/p06-rl-dynamic-low ready"
