#!/usr/bin/env bash
# gateways/traefik/p12-full-pipeline/setup.sh
#
# Post-up readiness + smoke for traefik/p12-full-pipeline.
#
# Verifies the composed JWT + RL + headers + body chain is wired
# correctly:
#
#   - missing JWT  -> 401 (bench-p02 short-circuits the chain)
#   - valid JWT    -> 200 with all six transforms applied
#
# The full truth-table (missing/expired JWT -> 401, valid JWT +
# transforms applied, 1200-req burst -> ~150 × 429) is exercised by
# scripts/parity-attestation.sh against fixtures/p12-full-pipeline.jsonl.
#
# Cold-start note: traefik has to compile BOTH Yaegi plugins
# (jwt_hs256.go + body_rewrite.go) before the chain serves traffic.
# Expect ~3-5 s before the first 401 lands. The wait loop below
# polls /anything WITHOUT Authorization, expecting 401 — the signal
# that the JWT middleware is the first link in the chain.
set -euo pipefail

DATA_URL="${DATA_URL:-http://localhost:9080}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

say()  { printf '%s %s\n' "$(date +'%H:%M:%S')" "$*" >&2; }
fail() { printf '\033[31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

# -----------------------------------------------------------------------------
# 1. Wait for the chain to come up: a missing-Authorization GET must
#    return 401 (signal that bench-p02 is at the head of the chain).
# -----------------------------------------------------------------------------
say "traefik/p12-full-pipeline: waiting for plugin chain at ${DATA_URL}"
for _ in $(seq 1 60); do
    code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 2 \
        "${DATA_URL}/anything" 2>/dev/null || true)
    if [[ "${code}" == "401" ]]; then
        say "data plane + plugin chain ready"
        break
    fi
    sleep 1
done

# -----------------------------------------------------------------------------
# 2. Smoke A — no Authorization header should be rejected 401, and
#    the 401 response body must NOT carry the bench transforms (the
#    chain short-circuits, the body rewrite never runs).
# -----------------------------------------------------------------------------
say "smoke A: GET /anything without Authorization -> expect 401"
code=$(curl -sS -o /dev/null -w '%{http_code}' "${DATA_URL}/anything")
[[ "${code}" == "401" ]] || fail "expected 401 with no Authorization, got ${code}"

# -----------------------------------------------------------------------------
# 3. Smoke B — a valid JWT should reach the backend, transforms
#    applied: backend received X-Bench-In=1, did NOT see X-Forwarded-For,
#    response carries X-Bench-Out=1, response body carries the
#    bench.injected inject and lost the secret/origin drops.
# -----------------------------------------------------------------------------
say "smoke B: POST /anything with valid JWT + secret body -> expect 200 + transforms"
token=$("${REPO_ROOT}/scripts/gen-jwt.sh" valid)
out=$(curl -isS -X POST \
    -H "Authorization: Bearer ${token}" \
    -H 'Content-Type: application/json' \
    -H 'X-Forwarded-For: 198.51.100.7' \
    -d '{"msg":"hello","secret":"please-drop-me","bench":{"from_client":true}}' \
    "${DATA_URL}/anything")

# Assert response status line: 200.
echo "${out}" | head -1 | grep -q '200' \
    || { printf '%s\n' "${out}" >&2; fail "smoke B: expected 200 in status line"; }

# Assert response carries X-Bench-Out (case-insensitive).
echo "${out}" | grep -qiE '^x-bench-out:[[:space:]]*1' \
    || { printf '%s\n' "${out}" >&2; fail "smoke B: missing X-Bench-Out: 1 response header"; }

# Assert response body has the bench inject and dropped origin/secret.
body=$(echo "${out}" | awk 'BEGIN{b=0} /^\r?$/{b=1; next} b{print}')
jq -e '.bench.injected == true' <<<"${body}" >/dev/null \
    || { printf '%s\n' "${body}" >&2; fail "smoke B: $.bench.injected missing in response body"; }
jq -e '.origin // empty' <<<"${body}" >/dev/null \
    && { printf '%s\n' "${body}" >&2; fail "smoke B: $.origin was NOT dropped"; }
jq -e '.json.bench.injected == true' <<<"${body}" >/dev/null \
    || { printf '%s\n' "${body}" >&2; fail "smoke B: backend did not receive $.bench.injected (req-body rewrite missed)"; }
jq -e '.json.secret // empty' <<<"${body}" >/dev/null \
    && { printf '%s\n' "${body}" >&2; fail "smoke B: $.secret was NOT dropped from request body"; }
jq -e '.headers["X-Bench-In"] == ["1"]' <<<"${body}" >/dev/null \
    || { printf '%s\n' "${body}" >&2; fail "smoke B: backend did not receive X-Bench-In: 1"; }
jq -e '.headers["X-Forwarded-For"] // empty' <<<"${body}" >/dev/null \
    && { printf '%s\n' "${body}" >&2; fail "smoke B: X-Forwarded-For was NOT dropped"; }

say "traefik/p12-full-pipeline ready"
