#!/usr/bin/env bash
# gateways/nginx/p04-rl-static/setup.sh
#
# nginx has no admin API: the whole profile is expressed in
# nginx.conf (limit_req_zone / limit_req at http{} / location{}).
# This script only proves the static config parsed cleanly and the
# proxy path still works under the rate-limit zone before the parity
# burst probe runs.
#
# Environment:
#   DATA_URL      (default http://localhost:9080) - data plane (smoke)
set -euo pipefail

DATA_URL="${DATA_URL:-http://localhost:9080}"

say()  { printf '%s %s\n' "$(date +'%H:%M:%S')" "$*" >&2; }
fail() { printf '\033[31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

# -----------------------------------------------------------------------------
# 1. Wait for the data plane
# -----------------------------------------------------------------------------
say "nginx/p04-rl-static: waiting for ${DATA_URL}"
for _ in $(seq 1 30); do
    if curl -sS -o /dev/null --max-time 2 "${DATA_URL}/anything" 2>/dev/null; then
        say "data plane ready"
        break
    fi
    sleep 1
done

# -----------------------------------------------------------------------------
# 2. Smoke — a single below-limit request must still return 200 and
#    echo the backend. This catches config drift where limit_req
#    accidentally drops everything (rate=0, wrong zone reference, …).
# -----------------------------------------------------------------------------
say "smoke: GET ${DATA_URL}/anything (below limit)"
body=$(curl --max-time 5 -fsS "${DATA_URL}/anything") \
    || fail "smoke /anything: curl --max-time 5 failed"
jq -e '.method == "GET"' <<<"${body}" >/dev/null \
    || { printf '%s\n' "${body}" >&2; fail "smoke /anything: .method not GET"; }

# NOTE: no standalone sanity "burst produces 429" check here. Under
# xargs-based parallelism the 429 rate is unreliable (curl --max-time 5 fork/TLS
# setup costs stretch a 500-req burst over ~1 s, which fits inside
# rate=1000r/s + burst=200 without triggering limit_req). The real
# burst assertion is delivered by `scripts/parity-attestation.sh`,
# which uses `curl --max-time 5 --parallel -K <config>` with
# BURST_PARALLELISM=128 — enough to compress 1200 requests into
# << 1 s and force the 429 path.

say "nginx/p04-rl-static ready"
