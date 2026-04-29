#!/usr/bin/env bash
# gateways/traefik/p06-rl-dynamic-low/setup.sh
#
# Traefik has no runtime admin-API config surface we rely on; the
# whole profile is expressed in traefik.yaml + dynamic.yaml, both
# mounted read-only at container start. This script just proves the
# data plane is up (traefik/backend health) — the rate-limit itself
# is validated by the parity-attestation burst probe.
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
say "traefik/p06-rl-dynamic-low: waiting for ${DATA_URL}"
for _ in $(seq 1 30); do
    if curl -sS -o /dev/null --max-time 2 "${DATA_URL}/status/200" \
         2>/dev/null; then
        say "data plane ready"
        break
    fi
    sleep 1
done

# -----------------------------------------------------------------------------
# 2. Smoke — exercise each of the four fixture paths so we catch config
#    drift before the more elaborate parity probes run.
# -----------------------------------------------------------------------------
say "smoke: GET ${DATA_URL}/status/200"
code=$(curl --max-time 5 -sS -o /dev/null -w '%{http_code}' "${DATA_URL}/status/200" || true)
[[ "${code}" == "200" ]] || fail "smoke /status/200: expected 200, got ${code}"

say "smoke: GET ${DATA_URL}/anything"
body=$(curl --max-time 5 -fsS "${DATA_URL}/anything") \
    || fail "smoke /anything: curl --max-time 5 failed"
jq -e '.method == "GET"' <<<"${body}" >/dev/null \
    || { printf '%s\n' "${body}" >&2; fail "smoke /anything: .method not GET"; }

say "smoke: POST ${DATA_URL}/anything"
body=$(curl --max-time 5 -fsS -H 'Content-Type: application/json' \
            -d '{"smoke":"ok"}' "${DATA_URL}/anything") \
    || fail "smoke POST /anything: curl --max-time 5 failed"
jq -e '.json.smoke == "ok"' <<<"${body}" >/dev/null \
    || { printf '%s\n' "${body}" >&2; fail "smoke POST /anything: json.smoke missing"; }

say "smoke: GET ${DATA_URL}/bytes/1024"
bytes=$(curl --max-time 5 -sS -o /dev/null -w '%{size_download}' "${DATA_URL}/bytes/1024" || true)
[[ "${bytes}" == "1024" ]] \
    || fail "smoke /bytes/1024: expected 1024 bytes, got ${bytes}"

say "traefik/p06-rl-dynamic-low ready"
