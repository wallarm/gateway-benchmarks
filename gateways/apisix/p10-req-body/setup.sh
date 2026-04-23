#!/usr/bin/env bash
# gateways/apisix/p10-req-body/setup.sh
#
# Post-up readiness + smoke for p10-req-body.

set -euo pipefail

DATA_URL="${DATA_URL:-http://localhost:9080}"

say()  { printf '%s %s\n' "$(date +'%H:%M:%S')" "$*" >&2; }
fail() { printf '\033[31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

say "apisix/p10-req-body: waiting for route reload"
# APISIX standalone mode watches conf/apisix.yaml for changes via a
# 1 s polling timer (see apisix/core/config_yaml.lua). Even once the
# data port answers HTTP, the route table may still be empty for a
# cycle or two. Loop until the body-rewrite surgery is actually in
# effect — the canonical "injected" field is the readiness signal.
for _ in $(seq 1 30); do
    probe=$(curl -sS -X POST -H 'Content-Type: application/json' \
        -d '{"ping":true}' --max-time 2 \
        "${DATA_URL}/anything" 2>/dev/null || true)
    # go-httpbin pretty-prints; match `"injected": true` (with a space
    # between colon and literal) as well as the compact form.
    if printf '%s' "${probe}" | grep -qE '"injected":[[:space:]]*true'; then
        say "data plane + body rewrite ready"
        break
    fi
    sleep 1
done

say "smoke: POST /anything with {\"msg\":\"hi\",\"secret\":\"x\"} -> backend sees injected=true, no secret"
body=$(curl -sS -X POST -H 'Content-Type: application/json' \
    -d '{"msg":"hi","secret":"x"}' \
    "${DATA_URL}/anything" || true)
printf '%s' "${body}" | grep -qE '"injected":[[:space:]]*true' \
    || fail "backend did not see bench.injected=true; body:\n${body}"
# `"secret"` must NOT appear in the backend-echoed .data or .json
# sections. go-httpbin echoes the raw body under .data, so this
# `grep` catches both the structured and the textual mention.
printf '%s' "${body}" | grep -q '"secret"' \
    && fail "backend unexpectedly saw secret; body:\n${body}" \
    || true

say "apisix/p10-req-body ready"
