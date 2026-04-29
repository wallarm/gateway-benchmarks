#!/usr/bin/env bash
# gateways/kong/p12-full-pipeline/setup.sh
#
# Composite smoke for the kong p11 chain. We don't replay the full
# parity matrix here — that's parity-attestation's job — but we do
# the minimum sanity-check that proves every link in the chain is
# actually wired:
#
#   * No Authorization → 401            (jwt is in the path)
#   * Valid JWT + POST body →
#       - request body had .secret stripped + .bench.injected added
#       - X-Bench-In injected, X-Forwarded-For dropped
#       - response body had .origin stripped + .bench.injected added
#       - X-Bench-Out present, Server absent

set -euo pipefail

DATA_URL="${DATA_URL:-http://localhost:9080}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

say()  { printf '%s %s\n' "$(date +'%H:%M:%S')" "$*" >&2; }
fail() { printf '\033[31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

say "kong/p11: waiting for ${DATA_URL} (expect 401 without auth)"
for _ in $(seq 1 30); do
    code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 2 \
        "${DATA_URL}/anything" 2>/dev/null || echo 000)
    if [[ "${code}" == "401" ]]; then
        say "data plane ready (jwt rejecting unauthenticated)"
        break
    fi
    sleep 1
done

token=$("${REPO_ROOT}/scripts/gen-jwt.sh" valid)

say "smoke: full chain through /anything with valid JWT + POST body"
hdrs_file=$(mktemp)
body=$(curl --max-time 5 -sS -D "${hdrs_file}" -o - \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -H "X-Forwarded-For: 198.51.100.7" \
    -X POST -d '{"msg":"hi","secret":"please-drop","bench":{"from_client":true}}' \
    "${DATA_URL}/anything")

# Response headers
grep -qi '^X-Bench-Out:' "${hdrs_file}" || fail "missing X-Bench-Out: $(cat "${hdrs_file}")"
if grep -qi '^Server:' "${hdrs_file}"; then
    fail "Server header leaked: $(cat "${hdrs_file}")"
fi

# Response body
echo "${body}" | grep -qE '"bench":[[:space:]]*\{' \
    || fail "missing top-level .bench: ${body}"
echo "${body}" | grep -qE '"injected":[[:space:]]*true' \
    || fail "missing injected:true: ${body}"
if echo "${body}" | grep -q '"origin"'; then
    fail ".origin leaked from response: ${body}"
fi
if echo "${body}" | grep -q '"secret"'; then
    fail ".secret leaked from request: ${body}"
fi

# Backend echoes the headers it saw
echo "${body}" | grep -qi '"X-Bench-In"' \
    || fail "backend missed X-Bench-In: ${body}"
if echo "${body}" | grep -qi '"X-Forwarded-For"'; then
    fail "backend still saw X-Forwarded-For: ${body}"
fi

rm -f "${hdrs_file}"
say "kong/p12-full-pipeline ready"
