#!/usr/bin/env bash
# gateways/nginx/p11-resp-body/setup.sh
#
# Post-up smoke for nginx/p11-resp-body. Hits go-httpbin's /anything
# (which echoes an $.origin field) and asserts that the gateway has
# injected $.bench.injected = true AND removed $.origin from the
# client-visible payload.
set -euo pipefail

DATA_URL="${DATA_URL:-http://localhost:9080}"

say()  { printf '%s %s\n' "$(date +'%H:%M:%S')" "$*" >&2; }
fail() { printf '\033[31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

say "nginx/p11-resp-body: waiting for ${DATA_URL}"
for _ in $(seq 1 30); do
    if curl -sS -o /dev/null --max-time 2 "${DATA_URL}/anything" 2>/dev/null; then
        say "data plane ready"
        break
    fi
    sleep 1
done

say "smoke: GET /anything -> expect injected=true, origin dropped"
body=$(curl -sS "${DATA_URL}/anything")

echo "${body}" | jq -e '.bench.injected == true' >/dev/null \
    || fail "\$.bench.injected is not true in response body"
echo "${body}" | jq -e 'has("origin") | not' >/dev/null \
    || fail "\$.origin leaked through response rewrite"

say "nginx/p11-resp-body ready"
