#!/usr/bin/env bash
# gateways/tyk/p01-vanilla/setup.sh
#
# Post-up readiness + minimal smoke for tyk/p01-vanilla.
#
# Tyk Classic loads its API definitions from /opt/tyk-gateway/apps at
# boot. There is nothing to POST — we just wait until /hello reports
# Redis healthy and confirm the API definition is registered.

set -euo pipefail

DATA_URL="${DATA_URL:-http://localhost:9080}"
TYK_SECRET="${TYK_SECRET:-gateway-benchmarks}"

say()  { printf '%s %s\n' "$(date +'%H:%M:%S')" "$*" >&2; }
fail() { printf '\033[31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

say "tyk/p01-vanilla: waiting for ${DATA_URL}/hello"
hello_ok=0
for _ in $(seq 1 60); do
    hello=$(curl -sS --max-time 2 "${DATA_URL}/hello" 2>/dev/null || true)
    if [[ -n "${hello}" ]] \
       && printf '%s' "${hello}" | jq -e '.status == "pass"' >/dev/null 2>&1; then
        hello_ok=1
        break
    fi
    sleep 1
done
(( hello_ok == 1 )) || fail "tyk /hello never returned status=pass"
say "  ✓ /hello reports status=pass"

api_list=$(curl -sS -H "X-Tyk-Authorization: ${TYK_SECRET}" \
               "${DATA_URL}/tyk/apis" 2>/dev/null || true)
printf '%s' "${api_list}" | jq -e 'any(.[]; .api_id == "bench")' >/dev/null 2>&1 \
    || fail "API definition 'bench' not registered — check docker logs gwb-tyk for JSON parse errors"
say "  ✓ /tyk/apis knows api_id=bench"

say "smoke: GET /anything -> 200"
code=$(curl -sS -o /dev/null -w '%{http_code}' "${DATA_URL}/anything" || true)
[[ "${code}" == "200" ]] || fail "expected 200 on /anything, got ${code}"

say "tyk/p01-vanilla ready"
