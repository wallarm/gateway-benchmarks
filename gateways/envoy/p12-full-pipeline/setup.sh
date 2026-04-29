#!/usr/bin/env bash
# gateways/envoy/p12-full-pipeline/setup.sh
#
# Post-up smoke for envoy/p12-full-pipeline. Exercises the happy path
# — valid JWT + below-limit POST with secret + bench payload —
# and asserts EVERY transform fired on a single round trip:
#
#   * 200 OK
#   * X-Bench-Out: 1 on response
#   * Server: absent on response
#   * response body: $.bench.injected=true, $.origin absent
#   * response body: $.json.msg="hello", $.json.bench.injected=true,
#                    $.json.bench.from_client=true, $.json.secret absent
#   * response body: backend saw X-Bench-In:1, did NOT see
#                    X-Forwarded-For (.headers echoed under $.headers)
#
# The full fixture (401 paths + 1200-req/s burst producing ≥150 × 429)
# is exercised by scripts/parity-attestation.sh against
# fixtures/p12-full-pipeline.jsonl.
set -euo pipefail

DATA_URL="${DATA_URL:-http://localhost:9080}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

say()  { printf '%s %s\n' "$(date +'%H:%M:%S')" "$*" >&2; }
fail() { printf '\033[31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

say "envoy/p12-full-pipeline: waiting for ${DATA_URL}"
for _ in $(seq 1 30); do
    if curl -sS -o /dev/null --max-time 2 "${DATA_URL}/anything" 2>/dev/null; then
        say "data plane ready"
        break
    fi
    sleep 1
done

# -----------------------------------------------------------------------------
# Smoke A: 401 on no-auth (JWT filter fires before body rewrite).
# -----------------------------------------------------------------------------
say "smoke A: POST /anything without Authorization -> expect 401"
code=$(curl --max-time 5 -sS -o /dev/null -w '%{http_code}' \
    -H 'Content-Type: application/json' \
    -d '{"msg":"x"}' \
    "${DATA_URL}/anything")
[[ "${code}" == "401" ]] \
    || fail "expected 401 with no auth, got ${code}"

# -----------------------------------------------------------------------------
# Smoke B: full pipeline with a valid JWT — one round trip must
# exercise every layer of transforms.
# -----------------------------------------------------------------------------
say "smoke B: full pipeline with valid JWT -> expect 200 + all transforms"
token=$("${REPO_ROOT}/scripts/gen-jwt.sh" valid)

# Capture headers and body together. go-httpbin's /anything echoes
# the backend-seen request headers under `.headers` as arrays.
resp=$(curl --max-time 5 -fsS -D /tmp/p11-envoy-hdrs.txt \
    -H "Authorization: Bearer ${token}" \
    -H 'Content-Type: application/json' \
    -H 'X-Forwarded-For: 198.51.100.7' \
    -d '{"msg":"hello","secret":"drop","bench":{"from_client":true}}' \
    "${DATA_URL}/anything") \
    || fail "curl --max-time 5 POST /anything (full pipeline) failed"

# p08: X-Bench-Out present, Server absent on downstream response.
grep -iq '^x-bench-out: 1' /tmp/p11-envoy-hdrs.txt \
    || { cat /tmp/p11-envoy-hdrs.txt >&2; fail "X-Bench-Out: missing on response"; }
if grep -iq '^server:' /tmp/p11-envoy-hdrs.txt; then
    cat /tmp/p11-envoy-hdrs.txt >&2
    fail "Server: present on response (expected absent)"
fi

# p10: response-body transforms.
jq -e '.bench.injected == true' <<<"${resp}" >/dev/null \
    || { printf '%s\n' "${resp}" >&2; fail "resp: .bench.injected missing"; }
jq -e '.origin == null' <<<"${resp}" >/dev/null \
    || { printf '%s\n' "${resp}" >&2; fail "resp: .origin still present"; }

# p09: request-body transforms (backend saw them).
jq -e '.json.bench.injected == true' <<<"${resp}" >/dev/null \
    || { printf '%s\n' "${resp}" >&2; fail "req: .json.bench.injected missing"; }
jq -e '.json.bench.from_client == true' <<<"${resp}" >/dev/null \
    || { printf '%s\n' "${resp}" >&2; fail "req: .json.bench.from_client missing"; }
jq -e '.json.msg == "hello"' <<<"${resp}" >/dev/null \
    || { printf '%s\n' "${resp}" >&2; fail "req: .json.msg missing"; }
jq -e '.json.secret == null' <<<"${resp}" >/dev/null \
    || { printf '%s\n' "${resp}" >&2; fail "req: .json.secret still present"; }

# p07: request-header transforms (backend saw them).
jq -e '(.headers["X-Bench-In"] // .headers["x-bench-in"] // [])[0] == "1"' <<<"${resp}" >/dev/null \
    || { printf '%s\n' "${resp}" >&2; fail "req: X-Bench-In missing at backend"; }
jq -e '((.headers | has("X-Forwarded-For")) or (.headers | has("x-forwarded-for"))) | not' <<<"${resp}" >/dev/null \
    || { printf '%s\n' "${resp}" >&2; fail "req: X-Forwarded-For still reached backend"; }

rm -f /tmp/p11-envoy-hdrs.txt
say "envoy/p12-full-pipeline ready"
