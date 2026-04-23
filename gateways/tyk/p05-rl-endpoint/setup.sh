#!/usr/bin/env bash
# gateways/tyk/p05-rl-endpoint/setup.sh

set -euo pipefail

DATA_URL="${DATA_URL:-http://localhost:9080}"
TYK_SECRET="${TYK_SECRET:-gateway-benchmarks}"

say()  { printf '%s %s\n' "$(date +'%H:%M:%S')" "$*" >&2; }
fail() { printf '\033[31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

say "tyk/p05-rl-endpoint: waiting for ${DATA_URL}/hello"
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
printf '%s' "${api_list}" | jq -e 'any(.[]; .api_id == "bench" and (.version_data.versions.Default.extended_paths.rate_limit | length) == 1)' >/dev/null 2>&1 \
    || fail "API definition 'bench' missing or extended_paths.rate_limit not declared"
say "  ✓ /tyk/apis reports api_id=bench with one extended_paths.rate_limit entry"

say "smoke: GET /anything/limited -> 200, /anything/free -> 200"
code1=$(curl -sS -o /dev/null -w '%{http_code}' "${DATA_URL}/anything/limited" || true)
code2=$(curl -sS -o /dev/null -w '%{http_code}' "${DATA_URL}/anything/free" || true)
[[ "${code1}" == "200" && "${code2}" == "200" ]] \
    || fail "expected 200/200 for limited/free, got ${code1}/${code2}"

say "tyk/p05-rl-endpoint ready"
