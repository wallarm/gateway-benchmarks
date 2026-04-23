#!/usr/bin/env bash
# gateways/kong/p02-jwt/setup.sh
#
# Post-up smoke for kong/p02-jwt. Verifies the native `jwt` plugin
# is wired: no Authorization → 401, valid token → 200.
# Full truth-table is exercised by scripts/parity-attestation.sh
# against fixtures/p02-jwt.jsonl.

set -euo pipefail

DATA_URL="${DATA_URL:-http://localhost:9080}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

say()  { printf '%s %s\n' "$(date +'%H:%M:%S')" "$*" >&2; }
fail() { printf '\033[31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

say "kong/p02-jwt: waiting for ${DATA_URL}"
for _ in $(seq 1 30); do
    code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 2 \
        "${DATA_URL}/anything" 2>/dev/null || echo 000)
    if [[ "${code}" == "401" ]]; then
        say "data plane ready (got 401 without auth)"
        break
    fi
    sleep 1
done

say "smoke A: no Authorization -> expect 401"
code=$(curl -sS -o /dev/null -w '%{http_code}' "${DATA_URL}/anything")
[[ "${code}" == "401" ]] || fail "expected 401 with no Authorization, got ${code}"

say "smoke B: valid HS256 token -> expect 200"
token=$("${REPO_ROOT}/scripts/gen-jwt.sh" valid)
code=$(curl -sS -o /dev/null -w '%{http_code}' \
    -H "Authorization: Bearer ${token}" \
    "${DATA_URL}/anything")
[[ "${code}" == "200" ]] || fail "expected 200 with valid token, got ${code}"

say "kong/p02-jwt ready"
