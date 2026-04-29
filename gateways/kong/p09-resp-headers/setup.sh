#!/usr/bin/env bash
# gateways/kong/p09-resp-headers/setup.sh
set -euo pipefail
DATA_URL="${DATA_URL:-http://localhost:9080}"

say()  { printf '%s %s\n' "$(date +'%H:%M:%S')" "$*" >&2; }
fail() { printf '\033[31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

say "kong/p09-resp-headers: waiting for ${DATA_URL}"
for _ in $(seq 1 30); do
    if curl -sS -o /dev/null --max-time 2 "${DATA_URL}/get" 2>/dev/null; then
        say "data plane ready"; break
    fi
    sleep 1
done

say "smoke: client sees X-Bench-Out and not Server"
hdrs=$(curl --max-time 5 -sS -D - -o /dev/null "${DATA_URL}/get")
echo "${hdrs}" | grep -qi '^X-Bench-Out:' || fail "missing X-Bench-Out: ${hdrs}"
if echo "${hdrs}" | grep -qi '^Server:'; then
    fail "unexpected Server header: ${hdrs}"
fi

say "kong/p09-resp-headers ready"
