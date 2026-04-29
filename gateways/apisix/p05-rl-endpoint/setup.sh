#!/usr/bin/env bash
# gateways/apisix/p05-rl-endpoint/setup.sh
#
# Post-up smoke for apisix/p05-rl-endpoint. Two sanity checks:
#   * /anything/limited  - below 100 rps -> 200
#   * /anything/free     - below any limit -> 200
# The 1200-rps burst probes on both paths (which actually engage /
# negate the rate-limit bucket) live in parity-attestation.
set -euo pipefail

DATA_URL="${DATA_URL:-http://localhost:9080}"

say()  { printf '%s %s\n' "$(date +'%H:%M:%S')" "$*" >&2; }
fail() { printf '\033[31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

say "apisix/p05-rl-endpoint: waiting for ${DATA_URL}"
for _ in $(seq 1 30); do
    if curl -sS -o /dev/null --max-time 2 "${DATA_URL}/anything/free" 2>/dev/null; then
        say "data plane ready"
        break
    fi
    sleep 1
done

say "smoke: GET /anything/free -> 200"
code=$(curl --max-time 5 -sS -o /dev/null -w '%{http_code}' "${DATA_URL}/anything/free" || true)
[[ "${code}" == "200" ]] || fail "single free request: expected 200, got ${code}"

say "smoke: GET /anything/limited (below 100 rps) -> 200"
code=$(curl --max-time 5 -sS -o /dev/null -w '%{http_code}' "${DATA_URL}/anything/limited" || true)
[[ "${code}" == "200" ]] || fail "single limited-below-limit request: expected 200, got ${code}"

say "apisix/p05-rl-endpoint ready"
