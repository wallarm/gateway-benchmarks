#!/usr/bin/env bash
# gateways/traefik/p02-jwt/setup.sh
#
# Post-up readiness + smoke for traefik/p02-jwt.
#
# Verifies the Yaegi `jwt_hs256` plugin is wired correctly: a request
# without Authorization is rejected 401, a request with a freshly
# minted valid token is allowed through to the backend.
#
# Two notes specific to traefik:
#
#   * Cold start is noticeably slower than the other p02 columns
#     because Yaegi has to compile the plugin source (jwt_hs256.go +
#     body_rewrite.go are both loaded even though p02 only references
#     jwt_hs256). Expect ~3-5 s before the first 401 lands.
#
#   * The full truth-table (missing/garbage/scheme/expired/wrong-secret
#     all -> 401; valid -> 200) is exercised by
#     scripts/parity-attestation.sh against fixtures/p02-jwt.jsonl —
#     this script only exercises the two endpoints (missing -> 401,
#     valid -> 200) so we catch config drift before the attestation
#     run.
set -euo pipefail

DATA_URL="${DATA_URL:-http://localhost:9080}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

say()  { printf '%s %s\n' "$(date +'%H:%M:%S')" "$*" >&2; }
fail() { printf '\033[31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

# -----------------------------------------------------------------------------
# 1. Wait for the data plane. parity-gateway.sh already polls /status/200
#    which is unauthenticated; here we re-poll /anything WITH a missing
#    Authorization, expecting 401 — the signal that the JWT middleware
#    is wired and live (a 200 here would mean the route bypasses the
#    middleware entirely, i.e. config drift).
# -----------------------------------------------------------------------------
say "traefik/p02-jwt: waiting for jwt_hs256 plugin to come up at ${DATA_URL}"
for _ in $(seq 1 60); do
    code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 2 \
        "${DATA_URL}/anything" 2>/dev/null || true)
    if [[ "${code}" == "401" ]]; then
        say "data plane + jwt_hs256 plugin ready"
        break
    fi
    sleep 1
done

# -----------------------------------------------------------------------------
# 2. Smoke A — no Authorization header should be rejected 401.
# -----------------------------------------------------------------------------
say "smoke A: GET /anything without Authorization -> expect 401"
code=$(curl --max-time 5 -sS -o /dev/null -w '%{http_code}' "${DATA_URL}/anything")
[[ "${code}" == "401" ]] || fail "expected 401 with no Authorization, got ${code}"

# -----------------------------------------------------------------------------
# 3. Smoke B — a freshly minted valid HS256 token should reach the
#    backend (200). gen-jwt.sh signs with the canonical secret from
#    gateways/_reference/jwt/secret.txt, which we inline verbatim
#    in dynamic.yaml's jwt_hs256.secret field.
# -----------------------------------------------------------------------------
say "smoke B: GET /anything with a fresh valid token -> expect 200"
token=$("${REPO_ROOT}/scripts/gen-jwt.sh" valid)
code=$(curl --max-time 5 -sS -o /dev/null -w '%{http_code}' \
    -H "Authorization: Bearer ${token}" \
    "${DATA_URL}/anything")
[[ "${code}" == "200" ]] || fail "expected 200 with valid token, got ${code}"

say "traefik/p02-jwt ready"
