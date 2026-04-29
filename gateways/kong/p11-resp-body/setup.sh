#!/usr/bin/env bash
# gateways/kong/p11-resp-body/setup.sh
set -euo pipefail
DATA_URL="${DATA_URL:-http://localhost:9080}"

say()  { printf '%s %s\n' "$(date +'%H:%M:%S')" "$*" >&2; }
fail() { printf '\033[31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

say "kong/p11-resp-body: waiting for ${DATA_URL}"
for _ in $(seq 1 30); do
    body=$(curl -sS --max-time 2 "${DATA_URL}/anything" 2>/dev/null || true)
    if echo "${body}" | grep -qE '"injected":[[:space:]]*true'; then
        say "data plane ready"; break
    fi
    sleep 1
done

say "smoke: client sees injected JSON, $.origin stripped"
body=$(curl --max-time 5 -sS "${DATA_URL}/anything")
echo "${body}" | grep -qE '"injected":[[:space:]]*true' \
    || fail "missing injected:true: ${body}"
if echo "${body}" | grep -q '"origin"'; then
    fail "origin leaked: ${body}"
fi

say "kong/p11-resp-body ready"
