#!/usr/bin/env bash
# gateways/tyk/p02-jwt/setup.sh
#
# Post-up readiness for tyk/p02-jwt.
#
# Tyk Classic loads its API definitions and policies from disk at boot
# — we just verify Redis is healthy and the JWT-bearing API definition
# is registered. We do NOT smoke a probe here because the canonical
# parity-attestation runner already does, and Tyk's hard-coded 400/403
# rejection codes (vs the canonical 401) are a cell-level deviation we
# want the runner to capture as FAIL, not paper over here.

set -euo pipefail

DATA_URL="${DATA_URL:-http://localhost:9080}"
TYK_SECRET="${TYK_SECRET:-gateway-benchmarks}"

say()  { printf '%s %s\n' "$(date +'%H:%M:%S')" "$*" >&2; }
fail() { printf '\033[31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

say "tyk/p02-jwt: waiting for ${DATA_URL}/hello"
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
printf '%s' "${api_list}" | jq -e 'any(.[]; .api_id == "bench" and .enable_jwt == true)' >/dev/null 2>&1 \
    || fail "API definition 'bench' missing or JWT not enabled — check docker logs gwb-tyk for JSON parse errors"
say "  ✓ /tyk/apis registers api_id=bench with enable_jwt=true"

policy_list=$(curl --max-time 5 -sS -H "X-Tyk-Authorization: ${TYK_SECRET}" \
                  "${DATA_URL}/tyk/policies" 2>/dev/null || true)
printf '%s' "${policy_list}" | jq -e '.[] | select(.id == "bench-default-policy") | .access_rights.bench != null' >/dev/null 2>&1 \
    || fail "bench-default-policy is missing 'bench' in access_rights — check _policies/policies.json"
say "  ✓ bench-default-policy grants access to api_id=bench"

say "tyk/p02-jwt ready (rejection-status divergence captured by parity probes)"
