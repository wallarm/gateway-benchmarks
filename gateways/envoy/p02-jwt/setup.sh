#!/usr/bin/env bash
# gateways/envoy/p02-jwt/setup.sh
#
# Post-up smoke for envoy/p02-jwt. Verifies the Lua filter's HS256
# verifier is wired correctly:
#   * no Authorization -> 401 (and envelope is our crafted JSON body)
#   * fresh valid token -> 200 (request reaches backend)
#
# The full truth-table (missing / garbage / wrong scheme / expired
# / wrong-secret / valid) is exercised by
# scripts/parity-attestation.sh against fixtures/p02-jwt.jsonl.
set -euo pipefail

DATA_URL="${DATA_URL:-http://localhost:9080}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

say()  { printf '%s %s\n' "$(date +'%H:%M:%S')" "$*" >&2; }
fail() { printf '\033[31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

say "envoy/p02-jwt: waiting for ${DATA_URL}"
for _ in $(seq 1 30); do
    # Probe with no Authorization (expected 401). The exit code from
    # curl --max-time 5 is still 0 for a 401 response (it succeeded talking to the
    # gateway), so we just check that SOMETHING answers.
    if curl -sS -o /dev/null --max-time 2 "${DATA_URL}/anything" \
         2>/dev/null; then
        say "data plane ready"
        break
    fi
    sleep 1
done

# -----------------------------------------------------------------------------
# Smoke A: no Authorization header must produce 401 + our crafted body.
# -----------------------------------------------------------------------------
say "smoke A: GET /anything without Authorization -> expect 401"
code=$(curl --max-time 5 -sS -o /dev/null -w '%{http_code}' "${DATA_URL}/anything")
[[ "${code}" == "401" ]] \
    || fail "expected 401 with no Authorization, got ${code}"

body=$(curl --max-time 5 -sS "${DATA_URL}/anything")
# The Lua filter responds with a JSON envelope; if we see "unauthorized"
# in the body, the custom respond() path fired (not a stray envoy 404
# or router misconfig producing a generic 401).
grep -q 'unauthorized' <<<"${body}" \
    || { printf '%s\n' "${body}" >&2; fail "401 body missing 'unauthorized' — custom respond() did not fire"; }

# -----------------------------------------------------------------------------
# Smoke B: fresh valid token must reach the backend and return 200.
# We mint it with the repo-canonical generator so every column shares
# the same secret / alg / claim shape.
# -----------------------------------------------------------------------------
say "smoke B: GET /anything with a fresh valid HS256 token -> expect 200"
token=$("${REPO_ROOT}/scripts/gen-jwt.sh" valid)
code=$(curl --max-time 5 -sS -o /dev/null -w '%{http_code}' \
    -H "Authorization: Bearer ${token}" \
    "${DATA_URL}/anything")
[[ "${code}" == "200" ]] \
    || fail "expected 200 with valid token, got ${code}"

say "envoy/p02-jwt ready"
