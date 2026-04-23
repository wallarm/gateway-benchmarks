#!/usr/bin/env bash
# gateways/nginx/p09-resp-headers/setup.sh
#
# Post-up smoke for nginx/p09-resp-headers. This profile runs on
# OpenResty (see .env in the same directory) so the config can use
# `more_clear_headers "Server"` from ngx_headers_more. The smoke
# verifies:
#   * the data plane answers;
#   * `add_header X-Bench-Out 1 always;` reaches the client;
#   * `more_clear_headers "Server";` actually deletes the Server
#     response header (not merely empties it).
#
# The full truth-table is exercised by scripts/parity-attestation.sh
# against fixtures/p09-resp-headers.jsonl.
set -euo pipefail

DATA_URL="${DATA_URL:-http://localhost:9080}"

say()  { printf '%s %s\n' "$(date +'%H:%M:%S')" "$*" >&2; }
fail() { printf '\033[31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

say "nginx/p09-resp-headers: waiting for ${DATA_URL}"
for _ in $(seq 1 30); do
    if curl -sS -o /dev/null --max-time 2 "${DATA_URL}/get" 2>/dev/null; then
        say "data plane ready"
        break
    fi
    sleep 1
done

say "smoke: HEAD ${DATA_URL}/get — checking response headers"
headers=$(curl -sSI "${DATA_URL}/get") \
    || fail "smoke: curl failed"

grep -qi '^x-bench-out:\s*1' <<<"${headers}" \
    || { printf '%s\n' "${headers}" >&2; fail "smoke: X-Bench-Out not seen in response"; }

if grep -qi '^server:' <<<"${headers}"; then
    printf '%s\n' "${headers}" >&2
    fail "smoke: Server header leaked — more_clear_headers did not fire"
fi

say "nginx/p09-resp-headers ready"
