#!/usr/bin/env bash
# gateways/apisix/p11-resp-body/setup.sh
#
# Post-up readiness + smoke for p11-resp-body.

set -euo pipefail

DATA_URL="${DATA_URL:-http://localhost:9080}"

say()  { printf '%s %s\n' "$(date +'%H:%M:%S')" "$*" >&2; }
fail() { printf '\033[31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

say "apisix/p11-resp-body: waiting for route reload"
for _ in $(seq 1 30); do
    probe=$(curl -sS --max-time 2 "${DATA_URL}/anything" 2>/dev/null || true)
    # Same space-tolerant pattern as p09 — go-httpbin pretty-prints.
    if printf '%s' "${probe}" | grep -qE '"injected":[[:space:]]*true'; then
        say "data plane + body rewrite ready"
        break
    fi
    sleep 1
done

say "smoke A: GET /anything -> client sees bench.injected=true, no origin"
body=$(curl -sS "${DATA_URL}/anything" || true)
printf '%s' "${body}" | grep -qE '"injected":[[:space:]]*true' \
    || fail "client did not see bench.injected=true; body:\n${body}"
# $.origin is the TOP-LEVEL go-httpbin field — our p10 drops it, so
# the client must not see it. A nested `"origin"` inside .headers
# does not exist (go-httpbin puts origin at top level), so a bare
# grep is sufficient here.
printf '%s' "${body}" | grep -q '"origin"' \
    && fail "client unexpectedly saw origin; body:\n${body}" \
    || true

say "apisix/p11-resp-body ready"
