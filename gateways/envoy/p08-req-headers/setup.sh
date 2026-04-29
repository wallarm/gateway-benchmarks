#!/usr/bin/env bash
# gateways/envoy/p08-req-headers/setup.sh
#
# Post-up smoke for envoy/p08-req-headers. Confirms the two header
# transforms landed in envoy's HCM by bouncing a single GET /headers
# off the backend and inspecting the echoed request headers.
#
# The full truth-table (X-Bench-In always injected, X-Forwarded-For
# unconditionally dropped, unrelated client headers pass through
# unchanged) is exercised by scripts/parity-attestation.sh against
# fixtures/p08-req-headers.jsonl.
set -euo pipefail

DATA_URL="${DATA_URL:-http://localhost:9080}"

say()  { printf '%s %s\n' "$(date +'%H:%M:%S')" "$*" >&2; }
fail() { printf '\033[31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

say "envoy/p08-req-headers: waiting for ${DATA_URL}"
for _ in $(seq 1 30); do
    if curl -sS -o /dev/null --max-time 2 "${DATA_URL}/headers" 2>/dev/null; then
        say "data plane ready"
        break
    fi
    sleep 1
done

# -----------------------------------------------------------------------------
# Smoke A: gateway injects X-Bench-In even when client sent nothing.
# go-httpbin's /headers echoes the upstream-seen request headers back
# as JSON under `.headers`; we look for our marker there.
# -----------------------------------------------------------------------------
say "smoke A: GET /headers — expect X-Bench-In=1 at backend"
body=$(curl --max-time 5 -fsS "${DATA_URL}/headers") \
    || fail "curl --max-time 5 /headers failed"
# go-httpbin's /headers endpoint echoes each header as a JSON array
# (one element per repeat occurrence), e.g. `{"X-Bench-In":["1"]}`.
# We therefore index `[0]` after the name lookup. The lowercase
# fallback catches envoy's default HTTP/1.1 lowercased-header wire
# form in case a future envoy release changes the echo shape.
val=$(jq -r '(.headers["X-Bench-In"] // .headers["x-bench-in"] // [])[0] // empty' <<<"${body}")
[[ "${val}" == "1" ]] \
    || { printf '%s\n' "${body}" >&2; fail "X-Bench-In: expected 1, got '${val}'"; }

# -----------------------------------------------------------------------------
# Smoke B: X-Forwarded-For drop. Client sends one; backend must not
# see it.
# -----------------------------------------------------------------------------
say "smoke B: GET /headers with X-Forwarded-For — expect drop at backend"
body=$(curl --max-time 5 -fsS -H 'X-Forwarded-For: 198.51.100.7' "${DATA_URL}/headers") \
    || fail "curl --max-time 5 /headers (with xff) failed"
val=$(jq -r '(.headers["X-Forwarded-For"] // .headers["x-forwarded-for"] // [])[0] // empty' <<<"${body}")
[[ -z "${val}" ]] \
    || { printf '%s\n' "${body}" >&2; fail "X-Forwarded-For: expected absent, got '${val}'"; }

say "envoy/p08-req-headers ready"
