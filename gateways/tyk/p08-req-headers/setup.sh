#!/usr/bin/env bash
# gateways/tyk/p08-req-headers/setup.sh

set -euo pipefail

DATA_URL="${DATA_URL:-http://localhost:9080}"
TYK_SECRET="${TYK_SECRET:-gateway-benchmarks}"

say()  { printf '%s %s\n' "$(date +'%H:%M:%S')" "$*" >&2; }
fail() { printf '\033[31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

say "tyk/p08-req-headers: waiting for ${DATA_URL}/hello"
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

api_list=$(curl --max-time 5 -sS -H "X-Tyk-Authorization: ${TYK_SECRET}" \
               "${DATA_URL}/tyk/apis" 2>/dev/null || true)
printf '%s' "${api_list}" \
    | jq -e 'any(.[]; .api_id == "bench" and (.version_data.versions.Default.extended_paths.transform_headers | length) == 1)' \
    >/dev/null 2>&1 \
    || fail "API definition 'bench' missing or transform_headers not declared"
say "  ✓ /tyk/apis registers api_id=bench with one transform_headers entry"

say "smoke: GET /headers, expect upstream to see X-Bench-In=1"
saw=$(curl --max-time 5 -sS "${DATA_URL}/headers" | jq -r '.headers["X-Bench-In"][0] // empty' || true)
[[ "${saw}" == "1" ]] || fail "upstream did not see X-Bench-In=1 (saw: '${saw}')"
say "  ✓ upstream sees X-Bench-In=1"

say "smoke: check X-Forwarded-For handling (Tyk's reverse proxy unconditionally re-stamps it)"
xff=$(curl --max-time 5 -sS -H 'X-Forwarded-For: 198.51.100.7' "${DATA_URL}/headers" \
        | jq -r '.headers["X-Forwarded-For"] // empty' || true)
say "  observed XFF on backend: ${xff}"

say "tyk/p08-req-headers ready (X-Forwarded-For drop divergence captured by parity probes)"
