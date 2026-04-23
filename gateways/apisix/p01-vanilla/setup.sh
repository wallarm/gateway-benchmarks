#!/usr/bin/env bash
# gateways/apisix/p01-vanilla/setup.sh
#
# APISIX standalone mode has no admin API: the whole profile is
# expressed in `apisix.yaml`, which docker-compose mounts read-only at
# container start. There is nothing to bootstrap — this script only
# proves that APISIX came up and proxies the backend correctly before
# the parity attestation runs.
#
# Environment:
#   DATA_URL  (default http://localhost:9080) - data plane (smoke)
set -euo pipefail

DATA_URL="${DATA_URL:-http://localhost:9080}"

say()  { printf '%s %s\n' "$(date +'%H:%M:%S')" "$*" >&2; }
fail() { printf '\033[31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

say "apisix/p01-vanilla: waiting for ${DATA_URL}"
for _ in $(seq 1 30); do
    if curl -sS -o /dev/null --max-time 2 "${DATA_URL}/status/200" 2>/dev/null; then
        say "data plane ready"
        break
    fi
    sleep 1
done

say "smoke: GET ${DATA_URL}/status/200"
code=$(curl -sS -o /dev/null -w '%{http_code}' "${DATA_URL}/status/200" || true)
[[ "${code}" == "200" ]] || fail "smoke /status/200: expected 200, got ${code}"

say "smoke: GET ${DATA_URL}/anything"
body=$(curl -fsS "${DATA_URL}/anything") \
    || fail "smoke /anything: curl failed"
jq -e '.method == "GET"' <<<"${body}" >/dev/null \
    || { printf '%s\n' "${body}" >&2; fail "smoke /anything: .method not GET"; }

say "smoke: POST ${DATA_URL}/anything"
body=$(curl -fsS -H 'Content-Type: application/json' \
            -d '{"smoke":"ok"}' "${DATA_URL}/anything") \
    || fail "smoke POST /anything: curl failed"
jq -e '.json.smoke == "ok"' <<<"${body}" >/dev/null \
    || { printf '%s\n' "${body}" >&2; fail "smoke POST /anything: json.smoke missing"; }

say "apisix/p01-vanilla ready"
