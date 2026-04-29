#!/usr/bin/env bash
# gateways/envoy/p09-resp-headers/setup.sh
#
# Post-up smoke for envoy/p09-resp-headers. Confirms the two
# response-header transforms landed:
#   * X-Bench-Out: 1 present on every response
#   * Server: absent on every response (even when upstream synthesises one)
#
# The full matrix (always-present X-Bench-Out + unconditional Server
# drop) is exercised by scripts/parity-attestation.sh against
# fixtures/p09-resp-headers.jsonl.
set -euo pipefail

DATA_URL="${DATA_URL:-http://localhost:9080}"

say()  { printf '%s %s\n' "$(date +'%H:%M:%S')" "$*" >&2; }
fail() { printf '\033[31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

say "envoy/p09-resp-headers: waiting for ${DATA_URL}"
for _ in $(seq 1 30); do
    if curl -sS -o /dev/null --max-time 2 "${DATA_URL}/get" 2>/dev/null; then
        say "data plane ready"
        break
    fi
    sleep 1
done

# -----------------------------------------------------------------------------
# Smoke A: upstream-supplied Server must be dropped; X-Bench-Out must be set.
# go-httpbin's /response-headers?Server=<val> synthesises a Server header
# server-side, so any residual trace of "should-be-dropped" in the
# response means the transform didn't fire.
# -----------------------------------------------------------------------------
say "smoke A: GET /response-headers?Server=x-upstream — expect Server absent"
hdrs=$(curl --max-time 5 -sSI "${DATA_URL}/response-headers?Server=x-upstream")
grep -iq '^x-bench-out: 1' <<<"${hdrs}" \
    || { printf '%s\n' "${hdrs}" >&2; fail "X-Bench-Out: expected '1', not found"; }
if grep -iq '^server:' <<<"${hdrs}"; then
    printf '%s\n' "${hdrs}" >&2
    fail "Server header: expected absent, but present"
fi

# -----------------------------------------------------------------------------
# Smoke B: unconditional Server drop on a path that does not inject one.
# PASS_THROUGH on the HCM means envoy will NOT stamp `Server: envoy` on
# its own, so even when upstream emits nothing the client sees no Server.
# -----------------------------------------------------------------------------
say "smoke B: GET /get — expect Server absent, X-Bench-Out present"
hdrs=$(curl --max-time 5 -sSI "${DATA_URL}/get")
grep -iq '^x-bench-out: 1' <<<"${hdrs}" \
    || { printf '%s\n' "${hdrs}" >&2; fail "X-Bench-Out: expected '1', not found"; }
if grep -iq '^server:' <<<"${hdrs}"; then
    printf '%s\n' "${hdrs}" >&2
    fail "Server header: expected absent, but present"
fi

say "envoy/p09-resp-headers ready"
