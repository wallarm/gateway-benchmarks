#!/usr/bin/env bash
# gateways/apisix/p09-resp-headers/setup.sh
#
# Post-up readiness + smoke for p09-resp-headers.

set -euo pipefail

DATA_URL="${DATA_URL:-http://localhost:9080}"

say()  { printf '%s %s\n' "$(date +'%H:%M:%S')" "$*" >&2; }
fail() { printf '\033[31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

say "apisix/p09-resp-headers: waiting for ${DATA_URL}"
for _ in $(seq 1 30); do
    if curl -sS -o /dev/null --max-time 2 "${DATA_URL}/get" 2>/dev/null; then
        say "data plane ready"
        break
    fi
    sleep 1
done

say "smoke A: client should see X-Bench-Out on /get"
hdrs=$(curl -sS -D - -o /dev/null "${DATA_URL}/get" || true)
printf '%s' "${hdrs}" | grep -qi '^X-Bench-Out:' \
    || fail "client did not see X-Bench-Out; headers dump:\n${hdrs}"

say "smoke B: client must NOT see Server header"
hdrs=$(curl -sS -D - -o /dev/null "${DATA_URL}/get" || true)
if printf '%s' "${hdrs}" | grep -qi '^Server:'; then
    fail "client unexpectedly saw a Server header; headers dump:\n${hdrs}"
fi

say "apisix/p09-resp-headers ready"
