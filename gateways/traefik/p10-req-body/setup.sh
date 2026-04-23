#!/usr/bin/env bash
# gateways/traefik/p10-req-body/setup.sh
#
# Traefik has no runtime admin-API config surface we rely on; the
# whole profile is expressed in traefik.yaml + dynamic.yaml, both
# mounted read-only at container start. This script proves the data
# plane is up (traefik/backend health) and sanity-checks the JSON
# body rewrite end-to-end — the formal parity verdict is rendered by
# parity-attestation against fixtures/p10-req-body.jsonl.
#
# Environment:
#   DATA_URL      (default http://localhost:9080) - data plane (smoke)
set -euo pipefail

DATA_URL="${DATA_URL:-http://localhost:9080}"

say()  { printf '%s %s\n' "$(date +'%H:%M:%S')" "$*" >&2; }
fail() { printf '\033[31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

# -----------------------------------------------------------------------------
# 1. Wait for the data plane. parity-gateway.sh already polls this,
#    but we re-poll here so the smoke checks below have meaningful
#    timing. The first poll after cold-start is noticeably slower on
#    p09 / p10 / p11 because Yaegi has to compile the plugin source.
# -----------------------------------------------------------------------------
say "traefik/p10-req-body: waiting for ${DATA_URL}"
for _ in $(seq 1 30); do
    if curl -sS -o /dev/null --max-time 2 "${DATA_URL}/status/200" \
         2>/dev/null; then
        say "data plane ready"
        break
    fi
    sleep 1
done

# -----------------------------------------------------------------------------
# 2. Smoke — the plugin must inject `$.bench.injected: true` and
#    strip `$.secret` from the request body before proxying. The
#    backend echoes the received body as `.json`, so we assert on
#    `.json.bench.injected` / `.json.secret`.
# -----------------------------------------------------------------------------
say "smoke: POST ${DATA_URL}/anything with secret+msg body"
body=$(curl -fsS -H 'Content-Type: application/json' \
            -d '{"msg":"hello","secret":"please-drop","bench":{"from_client":true}}' \
            "${DATA_URL}/anything") \
    || fail "smoke POST /anything: curl failed"

jq -e '.json.bench.injected == true' <<<"${body}" >/dev/null \
    || { printf '%s\n' "${body}" >&2; fail "smoke: bench.injected missing or != true"; }

jq -e '.json.secret // empty' <<<"${body}" >/dev/null \
    && { printf '%s\n' "${body}" >&2; fail "smoke: secret was NOT dropped"; }

jq -e '.json.msg == "hello"' <<<"${body}" >/dev/null \
    || { printf '%s\n' "${body}" >&2; fail "smoke: msg passthrough broken"; }

say "traefik/p10-req-body ready"
