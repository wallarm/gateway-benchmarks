#!/usr/bin/env bash
# gateways/traefik/p08-req-headers/setup.sh
#
# Traefik has no runtime admin-API config surface we rely on; the
# whole profile is expressed in traefik.yaml + dynamic.yaml, both
# mounted read-only at container start. This script proves the data
# plane is up (traefik/backend health) and sanity-checks the header
# transform end-to-end — the formal parity verdict is rendered by
# parity-attestation against fixtures/p08-req-headers.jsonl.
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
#    timing.
# -----------------------------------------------------------------------------
say "traefik/p08-req-headers: waiting for ${DATA_URL}"
for _ in $(seq 1 30); do
    if curl -sS -o /dev/null --max-time 2 "${DATA_URL}/status/200" \
         2>/dev/null; then
        say "data plane ready"
        break
    fi
    sleep 1
done

# -----------------------------------------------------------------------------
# 2. Smoke — X-Bench-In must be injected, X-Forwarded-For must be
#    stripped. /headers echoes every header the backend received, so
#    the fixture's assertions are falsifiable from a single response.
# -----------------------------------------------------------------------------
say "smoke: GET ${DATA_URL}/headers with client-supplied X-Forwarded-For"
body=$(curl --max-time 5 -fsS -H 'X-Forwarded-For: 198.51.100.7' "${DATA_URL}/headers") \
    || fail "smoke /headers: curl --max-time 5 failed"

jq -e '.headers["X-Bench-In"] == ["1"]' <<<"${body}" >/dev/null \
    || { printf '%s\n' "${body}" >&2; fail "smoke: X-Bench-In missing or != 1"; }

jq -e '.headers["X-Forwarded-For"] // empty' <<<"${body}" >/dev/null \
    && { printf '%s\n' "${body}" >&2; fail "smoke: X-Forwarded-For was NOT dropped"; }

say "traefik/p08-req-headers ready"
