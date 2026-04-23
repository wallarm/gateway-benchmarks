#!/usr/bin/env bash
# gateways/tyk/p04-rl-static/setup.sh
#
# Post-up readiness for tyk/p04-rl-static.

set -euo pipefail

DATA_URL="${DATA_URL:-http://localhost:9080}"
TYK_SECRET="${TYK_SECRET:-gateway-benchmarks}"

say()  { printf '%s %s\n' "$(date +'%H:%M:%S')" "$*" >&2; }
fail() { printf '\033[31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

say "tyk/p04-rl-static: waiting for ${DATA_URL}/hello"
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
printf '%s' "${api_list}" | jq -e 'any(.[]; .api_id == "bench" and .global_rate_limit.rate == 1000 and .global_rate_limit.per == 1)' >/dev/null 2>&1 \
    || fail "API definition 'bench' missing or global_rate_limit not 1000/1"
say "  ✓ /tyk/apis registers api_id=bench with global_rate_limit=1000/1s"

say "smoke: GET /anything -> 200"
code=$(curl -sS -o /dev/null -w '%{http_code}' "${DATA_URL}/anything" || true)
[[ "${code}" == "200" ]] || fail "expected 200 on /anything, got ${code}"

say "tyk/p04-rl-static ready"
