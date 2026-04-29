#!/usr/bin/env bash
# gateways/kong/p08-req-headers/setup.sh
set -euo pipefail
DATA_URL="${DATA_URL:-http://localhost:9080}"

say()  { printf '%s %s\n' "$(date +'%H:%M:%S')" "$*" >&2; }
fail() { printf '\033[31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

say "kong/p08-req-headers: waiting for ${DATA_URL}"
for _ in $(seq 1 30); do
    if curl -sS -o /dev/null --max-time 2 "${DATA_URL}/headers" 2>/dev/null; then
        say "data plane ready"; break
    fi
    sleep 1
done

say "smoke: backend sees X-Bench-In=1, does NOT see X-Forwarded-For"
body=$(curl --max-time 5 -sS "${DATA_URL}/headers" -H "X-Forwarded-For: 198.51.100.7")
echo "${body}" | grep -qi '"X-Bench-In"' || fail "backend missing X-Bench-In: ${body}"
if echo "${body}" | grep -qi '"X-Forwarded-For"'; then
    fail "backend still sees X-Forwarded-For: ${body}"
fi

say "kong/p08-req-headers ready"
