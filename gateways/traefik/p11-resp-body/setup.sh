#!/usr/bin/env bash
# gateways/traefik/p11-resp-body/setup.sh
#
# Traefik has no runtime admin-API config surface we rely on; the
# whole profile is expressed in traefik.yaml + dynamic.yaml, both
# mounted read-only at container start. This script proves the data
# plane is up (traefik/backend health) and sanity-checks the
# response-body rewrite end-to-end — the formal parity verdict is
# rendered by parity-attestation against fixtures/p11-resp-body.jsonl.
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
say "traefik/p11-resp-body: waiting for ${DATA_URL}"
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
#    drop `$.origin` from the response body before the client sees it.
#    go-httpbin stamps `origin` on every response and also echoes the
#    method/path, so the fixture shape is falsifiable with a single
#    probe.
# -----------------------------------------------------------------------------
say "smoke: GET ${DATA_URL}/anything"
body=$(curl -fsS "${DATA_URL}/anything") \
    || fail "smoke /anything: curl failed"

jq -e '.bench.injected == true' <<<"${body}" >/dev/null \
    || { printf '%s\n' "${body}" >&2; fail "smoke: \$.bench.injected missing or != true"; }

jq -e '.origin // empty' <<<"${body}" >/dev/null \
    && { printf '%s\n' "${body}" >&2; fail "smoke: \$.origin was NOT dropped"; }

jq -e '.method == "GET"' <<<"${body}" >/dev/null \
    || { printf '%s\n' "${body}" >&2; fail "smoke: \$.method passthrough broken"; }

say "traefik/p11-resp-body ready"
