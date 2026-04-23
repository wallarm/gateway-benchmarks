#!/usr/bin/env bash
# gateways/tyk/p09-resp-headers/setup.sh

set -euo pipefail

DATA_URL="${DATA_URL:-http://localhost:9080}"
TYK_SECRET="${TYK_SECRET:-gateway-benchmarks}"

say()  { printf '%s %s\n' "$(date +'%H:%M:%S')" "$*" >&2; }
fail() { printf '\033[31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

say "tyk/p09-resp-headers: waiting for ${DATA_URL}/hello"
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
printf '%s' "${api_list}" \
    | jq -e 'any(.[]; .api_id == "bench" and (.version_data.versions.Default.extended_paths.transform_response_headers | length) == 1)' \
    >/dev/null 2>&1 \
    || fail "API definition 'bench' missing or transform_response_headers not declared"
say "  ✓ /tyk/apis registers api_id=bench with one transform_response_headers entry"

say "smoke: GET /get expects X-Bench-Out=1 and no Server header"
hdrs=$(curl -sS -D - -o /dev/null "${DATA_URL}/get" || true)
echo "${hdrs}" | grep -i '^X-Bench-Out:' >/dev/null \
    || fail "client did not see X-Bench-Out header"
echo "${hdrs}" | grep -i '^Server:' >/dev/null \
    && fail "client unexpectedly saw Server header (should be dropped)" || true
say "  ✓ X-Bench-Out present, Server absent"

say "tyk/p09-resp-headers ready"
