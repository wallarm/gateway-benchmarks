#!/usr/bin/env bash
# gateways/envoy/p11-resp-body/setup.sh
#
# Post-up smoke for envoy/p11-resp-body. GETs /anything and asserts
# the Lua filter added `$.bench.injected` to the JSON response while
# dropping `$.origin` before the client saw the body.
#
# The full truth-table (GET inject + drop, POST inject + drop,
# passthrough of fields) is exercised by
# scripts/parity-attestation.sh against fixtures/p11-resp-body.jsonl.
set -euo pipefail

DATA_URL="${DATA_URL:-http://localhost:9080}"

say()  { printf '%s %s\n' "$(date +'%H:%M:%S')" "$*" >&2; }
fail() { printf '\033[31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

say "envoy/p11-resp-body: waiting for ${DATA_URL}"
for _ in $(seq 1 30); do
    if curl -sS -o /dev/null --max-time 2 "${DATA_URL}/anything" 2>/dev/null; then
        say "data plane ready"
        break
    fi
    sleep 1
done

# -----------------------------------------------------------------------------
# Smoke A: GET /anything — JSON body, origin present upstream. After
# the Lua filter, client sees bench.injected=true and no origin.
# -----------------------------------------------------------------------------
say "smoke A: GET /anything -> expect bench.injected=true + origin absent"
body=$(curl --max-time 5 -fsS "${DATA_URL}/anything") \
    || fail "curl --max-time 5 /anything failed"

jq -e '.bench.injected == true' <<<"${body}" >/dev/null \
    || { printf '%s\n' "${body}" >&2; fail "bench.injected: expected true, missing"; }
jq -e '.method == "GET"' <<<"${body}" >/dev/null \
    || { printf '%s\n' "${body}" >&2; fail "method: expected GET, missing"; }
jq -e '.origin == null' <<<"${body}" >/dev/null \
    || { printf '%s\n' "${body}" >&2; fail "origin: expected absent, still present"; }

# -----------------------------------------------------------------------------
# Smoke B: POST /anything — JSON body echoed under $.json; top-level
# origin must still be dropped and bench.injected still added.
# -----------------------------------------------------------------------------
say "smoke B: POST /anything {msg:bench} -> expect bench.injected + origin absent + json.msg=bench"
body=$(curl --max-time 5 -fsS -H 'Content-Type: application/json' \
    -d '{"msg":"bench"}' "${DATA_URL}/anything") \
    || fail "curl --max-time 5 POST /anything failed"

jq -e '.bench.injected == true' <<<"${body}" >/dev/null \
    || { printf '%s\n' "${body}" >&2; fail "bench.injected (POST): missing"; }
jq -e '.json.msg == "bench"' <<<"${body}" >/dev/null \
    || { printf '%s\n' "${body}" >&2; fail "json.msg (POST): missing"; }
jq -e '.origin == null' <<<"${body}" >/dev/null \
    || { printf '%s\n' "${body}" >&2; fail "origin (POST): still present"; }

say "envoy/p11-resp-body ready"
