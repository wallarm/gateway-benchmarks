#!/usr/bin/env bash
# gateways/kong/p10-req-body/setup.sh
set -euo pipefail
DATA_URL="${DATA_URL:-http://localhost:9080}"

say()  { printf '%s %s\n' "$(date +'%H:%M:%S')" "$*" >&2; }
fail() { printf '\033[31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

say "kong/p10-req-body: waiting for ${DATA_URL}"
for _ in $(seq 1 30); do
    body=$(curl -sS --max-time 2 -X POST "${DATA_URL}/anything" \
        -H "Content-Type: application/json" \
        -d '{"hello":"x"}' 2>/dev/null || true)
    if echo "${body}" | grep -qE '"injected":[[:space:]]*true'; then
        say "data plane ready"; break
    fi
    sleep 1
done

say "smoke: backend echoes injected JSON, $.secret stripped"
body=$(curl -sS -X POST "${DATA_URL}/anything" \
    -H "Content-Type: application/json" \
    -d '{"msg":"hello","secret":"please-drop","bench":{"from_client":true}}')
echo "${body}" | grep -qE '"injected":[[:space:]]*true' \
    || fail "missing injected:true: ${body}"
if echo "${body}" | grep -q '"secret"'; then
    fail "secret leaked: ${body}"
fi

say "kong/p10-req-body ready"
