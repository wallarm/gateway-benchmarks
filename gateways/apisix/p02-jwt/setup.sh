#!/usr/bin/env bash
# gateways/apisix/p02-jwt/setup.sh
#
# Post-up readiness + smoke for p02-jwt.

set -euo pipefail

DATA_URL="${DATA_URL:-http://localhost:9080}"

say()  { printf '%s %s\n' "$(date +'%H:%M:%S')" "$*" >&2; }
fail() { printf '\033[31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

say "apisix/p02-jwt: waiting for route reload"
# Readiness: once the serverless-pre-function is live we will see a
# 401 on an unauthenticated GET /anything. While the config is still
# reloading we get either a 200 (route not yet bound to plugin) or a
# connection reset.
for _ in $(seq 1 30); do
    code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 2 \
        "${DATA_URL}/anything" 2>/dev/null || true)
    if [[ "${code}" == "401" ]]; then
        say "data plane + JWT verifier ready"
        break
    fi
    sleep 1
done

say "smoke A: no Authorization -> 401"
code=$(curl -sS -o /dev/null -w '%{http_code}' "${DATA_URL}/anything" || true)
[[ "${code}" == "401" ]] || fail "expected 401 on missing Authorization, got ${code}"

say "smoke B: garbage bearer token -> 401"
code=$(curl -sS -o /dev/null -w '%{http_code}' \
    -H 'Authorization: Bearer not.a.jwt' \
    "${DATA_URL}/anything" || true)
[[ "${code}" == "401" ]] || fail "expected 401 on garbage bearer, got ${code}"

say "apisix/p02-jwt ready"
