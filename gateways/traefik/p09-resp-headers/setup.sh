#!/usr/bin/env bash
# gateways/traefik/p09-resp-headers/setup.sh
#
# Traefik has no runtime admin-API config surface we rely on; the
# whole profile is expressed in traefik.yaml + dynamic.yaml, both
# mounted read-only at container start. This script proves the data
# plane is up (traefik/backend health) and sanity-checks the
# response-header transform end-to-end — the formal parity verdict is
# rendered by parity-attestation against fixtures/p09-resp-headers.jsonl.
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
say "traefik/p09-resp-headers: waiting for ${DATA_URL}"
for _ in $(seq 1 30); do
    if curl -sS -o /dev/null --max-time 2 "${DATA_URL}/status/200" \
         2>/dev/null; then
        say "data plane ready"
        break
    fi
    sleep 1
done

# -----------------------------------------------------------------------------
# 2. Smoke — X-Bench-Out must be stamped, Server must be absent from
#    the downstream response (even when the fixture tries to sneak it
#    in via /response-headers?Server=...).
# -----------------------------------------------------------------------------
say "smoke: GET ${DATA_URL}/response-headers?Server=should-be-dropped"
headers_dump=$(curl -sSI "${DATA_URL}/response-headers?Server=should-be-dropped" \
    || fail "smoke /response-headers: curl failed")

grep -qi '^X-Bench-Out:' <<<"${headers_dump}" \
    || { printf '%s\n' "${headers_dump}" >&2; fail "smoke: X-Bench-Out missing"; }

grep -qi '^Server:' <<<"${headers_dump}" \
    && { printf '%s\n' "${headers_dump}" >&2; fail "smoke: Server was NOT dropped"; }

say "traefik/p09-resp-headers ready"
