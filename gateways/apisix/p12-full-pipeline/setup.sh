#!/usr/bin/env bash
# gateways/apisix/p12-full-pipeline/setup.sh
#
# Post-up readiness + smoke for apisix/p12-full-pipeline.
#
# This profile folds p02 + p03 + p07 + p08 + p09 + p10 into one
# route. Readiness is reached when the serverless-pre-function is
# live (401 on unauthenticated GET); the composite smoke probe then
# exercises every sub-policy in a single request, matching the shape
# of gateways/nginx/p12-full-pipeline/setup.sh so both rows in the
# ranking table are driven by an identical oracle.
#
# The 1200-rps burst (p03-style 429 saturation) is NOT exercised
# here — parity-attestation.sh runs the burst fixture separately.
set -euo pipefail

DATA_URL="${DATA_URL:-http://localhost:9080}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

say()  { printf '%s %s\n' "$(date +'%H:%M:%S')" "$*" >&2; }
fail() { printf '\033[31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

say "apisix/p12-full-pipeline: waiting for route reload"
# The serverless-pre-function owns JWT enforcement, so the absence
# of an Authorization header is our readiness signal — a plain
# `curl --max-time 5 /anything` must hit the 401 branch once the route is bound.
for _ in $(seq 1 30); do
    code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 2 \
        "${DATA_URL}/anything" 2>/dev/null || true)
    if [[ "${code}" == "401" ]]; then
        say "data plane + full pipeline ready"
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
[[ "${code}" == "200" ]] || fail "expected 200, got ${code} (body: $(cat "${tmp_body}"))"

# p08 — response-header transforms: X-Bench-Out present, Server absent.
grep -qi '^x-bench-out:' "${tmp_hdr}" \
    || fail "X-Bench-Out missing from client response (p08)"
grep -qi '^server:' "${tmp_hdr}" \
    && fail "Server header leaked to client (p08)"

# p09 — request-body rewrite: backend echoes the request body under
# $.json. We must see the injection and NOT see the stripped secret.
jq -e '.json.bench.injected == true' "${tmp_body}" >/dev/null \
    || fail "\$.json.bench.injected != true (p09)"
jq -e '.json | has("secret") | not' "${tmp_body}" >/dev/null \
    || fail "\$.json.secret leaked (p09)"

# p10 — response-body rewrite at the top level of go-httpbin's echo.
jq -e '.bench.injected == true' "${tmp_body}" >/dev/null \
    || fail "\$.bench.injected != true (p10)"
jq -e 'has("origin") | not' "${tmp_body}" >/dev/null \
    || fail "\$.origin leaked (p10)"

# p07 — request-header transforms echoed under $.headers.
jq -e '.headers."X-Bench-In" // empty | .[0] == "1"' "${tmp_body}" >/dev/null \
    || fail "backend did not see X-Bench-In: 1 (p07)"
jq -e '.headers | has("X-Forwarded-For") | not' "${tmp_body}" >/dev/null \
    || fail "backend still saw X-Forwarded-For (p07)"

say "apisix/p12-full-pipeline ready"
