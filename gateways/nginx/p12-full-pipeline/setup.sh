#!/usr/bin/env bash
# gateways/nginx/p12-full-pipeline/setup.sh
#
# Post-up smoke for nginx/p12-full-pipeline. Exercises the whole
# chain in one probe:
#   - valid JWT         ← p02
#   - POST with secret  ← p09
#   - backend echoes    →
#     - $.json.bench.injected=true, $.json.secret absent (p09)
#     - $.bench.injected=true, $.origin absent (p10)
#   - X-Bench-Out present, Server absent (p08)
#   - backend saw X-Bench-In=1, did not see X-Forwarded-For (p07)
#
# The full-throughput burst (p03-style 1200 rps → ≥150×429) is
# exercised by parity-attestation.sh, not here — scripts/parity-gateway.sh
# runs both setup + attestation in sequence.
set -euo pipefail

DATA_URL="${DATA_URL:-http://localhost:9080}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

say()  { printf '%s %s\n' "$(date +'%H:%M:%S')" "$*" >&2; }
fail() { printf '\033[31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

say "nginx/p12-full-pipeline: waiting for ${DATA_URL}"
for _ in $(seq 1 30); do
    if curl -sS -o /dev/null --max-time 2 "${DATA_URL}/anything" 2>/dev/null; then
        say "data plane ready"
        break
    fi
    sleep 1
done

say "smoke: POST with valid JWT, secret -> expect full-pipeline transforms"
token=$("${REPO_ROOT}/scripts/gen-jwt.sh" valid)
tmp_body=$(mktemp)
tmp_hdr=$(mktemp)
trap 'rm -f "${tmp_body}" "${tmp_hdr}"' EXIT

code=$(curl --max-time 5 -sS -o "${tmp_body}" -D "${tmp_hdr}" -w '%{http_code}' \
    -X POST \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -H "X-Forwarded-For: 198.51.100.7" \
    -d '{"msg":"hello","secret":"please-drop-me"}' \
    "${DATA_URL}/anything")
[[ "${code}" == "200" ]] || fail "expected 200, got ${code}"

# p08 response-header transforms
grep -qi '^x-bench-out:' "${tmp_hdr}" \
    || fail "X-Bench-Out missing from client response (p08)"
grep -qi '^server:' "${tmp_hdr}" \
    && fail "Server header leaked to client (p08)"

# p09 request-body rewrite — backend echoes request body under $.json
jq -e '.json.bench.injected == true' "${tmp_body}" >/dev/null \
    || fail "\$.json.bench.injected != true (p09)"
jq -e '.json | has("secret") | not' "${tmp_body}" >/dev/null \
    || fail "\$.json.secret leaked (p09)"

# p10 response-body rewrite — at the root of the echoed response
jq -e '.bench.injected == true' "${tmp_body}" >/dev/null \
    || fail "\$.bench.injected != true (p10)"
jq -e 'has("origin") | not' "${tmp_body}" >/dev/null \
    || fail "\$.origin leaked (p10)"

# p07 request-header transforms — echoed under $.headers
jq -e '.headers."X-Bench-In" // empty | .[0] == "1"' "${tmp_body}" >/dev/null \
    || fail "backend did not see X-Bench-In: 1 (p07)"
jq -e '.headers | has("X-Forwarded-For") | not' "${tmp_body}" >/dev/null \
    || fail "backend still saw X-Forwarded-For (p07)"

say "nginx/p12-full-pipeline ready"
