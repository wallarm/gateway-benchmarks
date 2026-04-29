#!/usr/bin/env bash
# gateways/nginx/p08-req-headers/setup.sh
#
# Post-up smoke for nginx/p08-req-headers. nginx has no admin API —
# the profile's behaviour is fully expressed in nginx.conf. This
# script only proves:
#   * the config parsed cleanly and the data plane answers;
#   * `proxy_set_header X-Bench-In "1"` actually reaches the backend;
#   * `proxy_set_header X-Forwarded-For ""` drops the client-supplied
#     X-Forwarded-For before it hits the backend.
#
# The full truth-table is exercised by scripts/parity-attestation.sh
# against fixtures/p08-req-headers.jsonl.
set -euo pipefail

DATA_URL="${DATA_URL:-http://localhost:9080}"

say()  { printf '%s %s\n' "$(date +'%H:%M:%S')" "$*" >&2; }
fail() { printf '\033[31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

say "nginx/p08-req-headers: waiting for ${DATA_URL}"
for _ in $(seq 1 30); do
    if curl -sS -o /dev/null --max-time 2 "${DATA_URL}/headers" 2>/dev/null; then
        say "data plane ready"
        break
    fi
    sleep 1
done

say "smoke: GET ${DATA_URL}/headers with X-Forwarded-For: 198.51.100.7"
body=$(curl --max-time 5 -fsS -H 'X-Forwarded-For: 198.51.100.7' "${DATA_URL}/headers") \
    || fail "smoke: curl --max-time 5 failed"

# go-httpbin echoes headers as {"headers": {"X-Foo": ["v", "v"]}}.
# A single-hop nginx forward gives us arrays of length 1.
jq -e '.headers["X-Bench-In"] // .headers["x-bench-in"] // [] | . == ["1"] or . == "1"' <<<"${body}" >/dev/null \
    || { printf '%s\n' "${body}" >&2; fail "smoke: backend did not see X-Bench-In: 1"; }

jq -e '((.headers["X-Forwarded-For"] // .headers["x-forwarded-for"]) // "__MISSING__") | . == "__MISSING__"' <<<"${body}" >/dev/null \
    || { printf '%s\n' "${body}" >&2; fail "smoke: backend unexpectedly saw X-Forwarded-For — drop is broken"; }

say "nginx/p08-req-headers ready"
