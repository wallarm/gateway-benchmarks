#!/usr/bin/env bash
# gateways/kong/p01-vanilla/setup.sh
#
# Post-up smoke for kong/p01-vanilla.

set -euo pipefail

DATA_URL="${DATA_URL:-http://localhost:9080}"

say()  { printf '%s %s\n' "$(date +'%H:%M:%S')" "$*" >&2; }
fail() { printf '\033[31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

say "kong/p01-vanilla: waiting for ${DATA_URL}"
for _ in $(seq 1 30); do
    if curl -sS -o /dev/null --max-time 2 "${DATA_URL}/anything" 2>/dev/null; then
        say "data plane ready"
        break
    fi
    sleep 1
done

say "smoke: GET /anything -> 200"
code=$(curl -sS -o /dev/null -w '%{http_code}' "${DATA_URL}/anything" || true)
[[ "${code}" == "200" ]] || fail "expected 200 on /anything, got ${code}"

say "kong/p01-vanilla ready"
