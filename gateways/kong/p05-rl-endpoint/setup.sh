#!/usr/bin/env bash
# gateways/kong/p05-rl-endpoint/setup.sh
set -euo pipefail
DATA_URL="${DATA_URL:-http://localhost:9080}"

say()  { printf '%s %s\n' "$(date +'%H:%M:%S')" "$*" >&2; }
fail() { printf '\033[31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

say "kong/p05-rl-endpoint: waiting for ${DATA_URL}"
for _ in $(seq 1 30); do
    if curl -sS -o /dev/null --max-time 2 "${DATA_URL}/anything/free" 2>/dev/null; then
        say "data plane ready"; break
    fi
    sleep 1
done

for p in /anything/free /anything/limited; do
    code=$(curl --max-time 5 -sS -o /dev/null -w '%{http_code}' "${DATA_URL}${p}")
    [[ "${code}" == "200" ]] || fail "expected 200 on ${p}, got ${code}"
done

say "kong/p05-rl-endpoint ready"
