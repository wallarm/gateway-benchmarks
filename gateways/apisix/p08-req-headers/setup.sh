#!/usr/bin/env bash
# gateways/apisix/p08-req-headers/setup.sh
set -euo pipefail

DATA_URL="${DATA_URL:-http://localhost:9080}"

say()  { printf '%s %s\n' "$(date +'%H:%M:%S')" "$*" >&2; }
fail() { printf '\033[31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

say "apisix/p08-req-headers: waiting for ${DATA_URL}"
for _ in $(seq 1 30); do
    if curl -sS -o /dev/null --max-time 2 "${DATA_URL}/anything" 2>/dev/null; then
        say "data plane ready"
        break
    fi
    sleep 1
done

say "smoke A: backend should see X-Bench-In: 1 on /headers"
body=$(curl -sS "${DATA_URL}/headers" || true)
printf '%s' "${body}" | grep -q '"X-Bench-In"' \
    || fail "backend did not receive X-Bench-In header; got:\n${body}"

say "smoke B: backend should NOT see X-Forwarded-For even if the client sent one"
body=$(curl -sS -H 'X-Forwarded-For: 198.51.100.7' "${DATA_URL}/headers" || true)
printf '%s' "${body}" | grep -q '"X-Forwarded-For"' \
    && fail "backend unexpectedly saw X-Forwarded-For; got:\n${body}" \
    || true

say "apisix/p08-req-headers ready"
