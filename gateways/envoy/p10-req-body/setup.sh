#!/usr/bin/env bash
# gateways/envoy/p10-req-body/setup.sh
#
# Post-up smoke for envoy/p10-req-body. Posts a JSON body to
# /anything and asserts the Lua filter injected `$.bench.injected`
# and dropped `$.secret` before the request reached go-httpbin.
#
# The full truth-table (inject + drop + empty body + Content-Length
# recalc) is exercised by scripts/parity-attestation.sh against
# fixtures/p10-req-body.jsonl.
set -euo pipefail

DATA_URL="${DATA_URL:-http://localhost:9080}"

say()  { printf '%s %s\n' "$(date +'%H:%M:%S')" "$*" >&2; }
fail() { printf '\033[31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

say "envoy/p10-req-body: waiting for ${DATA_URL}"
for _ in $(seq 1 30); do
    if curl -sS -o /dev/null --max-time 2 "${DATA_URL}/anything" 2>/dev/null; then
        say "data plane ready"
        break
    fi
    sleep 1
done

# -----------------------------------------------------------------------------
# Smoke A: POST with `secret` and nested `bench` — expect bench.injected
# added and secret stripped in what the backend echoes.
# -----------------------------------------------------------------------------
say "smoke A: POST /anything {msg, secret, bench.from_client} -> expect bench.injected + secret absent"
body=$(curl --max-time 5 -fsS -H 'Content-Type: application/json' \
    -d '{"msg":"hello","secret":"please-drop-me","bench":{"from_client":true}}' \
    "${DATA_URL}/anything") \
    || fail "curl --max-time 5 POST /anything failed"

jq -e '.json.bench.injected == true' <<<"${body}" >/dev/null \
    || { printf '%s\n' "${body}" >&2; fail "bench.injected: expected true, missing"; }
jq -e '.json.bench.from_client == true' <<<"${body}" >/dev/null \
    || { printf '%s\n' "${body}" >&2; fail "bench.from_client: expected true, missing"; }
jq -e '.json.msg == "hello"' <<<"${body}" >/dev/null \
    || { printf '%s\n' "${body}" >&2; fail "msg: expected 'hello', missing"; }
jq -e '.json.secret == null' <<<"${body}" >/dev/null \
    || { printf '%s\n' "${body}" >&2; fail "secret: expected absent, still present"; }

# -----------------------------------------------------------------------------
# Smoke B: POST with empty body {} — still gets bench.injected.
# -----------------------------------------------------------------------------
say "smoke B: POST /anything '{}' -> expect bench.injected added"
body=$(curl --max-time 5 -fsS -H 'Content-Type: application/json' \
    -d '{}' \
    "${DATA_URL}/anything") \
    || fail "curl --max-time 5 POST /anything (empty body) failed"

jq -e '.json.bench.injected == true' <<<"${body}" >/dev/null \
    || { printf '%s\n' "${body}" >&2; fail "empty-body bench.injected: missing"; }

say "envoy/p10-req-body ready"
