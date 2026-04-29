#!/usr/bin/env bash
# gateways/nginx/p02-jwt/setup.sh
#
# Post-up smoke for nginx/p02-jwt. Verifies the JWT access_by_lua
# path is wired correctly: a request without Authorization is
# rejected 401, a request with a freshly minted valid token is
# allowed through to the backend.
#
# The full truth-table (missing/garbage/scheme/expired/wrong-secret
# all → 401; valid → 200) is exercised by
# scripts/parity-attestation.sh against fixtures/p02-jwt.jsonl.
set -euo pipefail

DATA_URL="${DATA_URL:-http://localhost:9080}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

say()  { printf '%s %s\n' "$(date +'%H:%M:%S')" "$*" >&2; }
fail() { printf '\033[31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

say "nginx/p02-jwt: waiting for ${DATA_URL}"
for _ in $(seq 1 30); do
    if curl -sS -o /dev/null --max-time 2 "${DATA_URL}/anything" 2>/dev/null; then
        say "data plane ready"
        break
    fi
    sleep 1
done

say "smoke A: GET /anything without Authorization -> expect 401"
code=$(curl --max-time 5 -sS -o /dev/null -w '%{http_code}' "${DATA_URL}/anything")
[[ "${code}" == "401" ]] || fail "expected 401 with no Authorization, got ${code}"

say "smoke B: GET /anything with a fresh valid token -> expect 200"
token=$("${REPO_ROOT}/scripts/gen-jwt.sh" valid)
code=$(curl --max-time 5 -sS -o /dev/null -w '%{http_code}' \
    -H "Authorization: Bearer ${token}" \
    "${DATA_URL}/anything")
[[ "${code}" == "200" ]] || fail "expected 200 with valid token, got ${code}"

say "nginx/p02-jwt ready"
