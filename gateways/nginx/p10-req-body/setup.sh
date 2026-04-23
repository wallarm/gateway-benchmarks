#!/usr/bin/env bash
# gateways/nginx/p10-req-body/setup.sh
#
# Post-up smoke for nginx/p10-req-body. Sends a probe that carries
# $.secret and asserts:
#   * response 200
#   * go-httpbin echoes the rewritten body back under $.json
#   * $.bench.injected == true
#   * $.secret is absent
set -euo pipefail

DATA_URL="${DATA_URL:-http://localhost:9080}"

say()  { printf '%s %s\n' "$(date +'%H:%M:%S')" "$*" >&2; }
fail() { printf '\033[31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

say "nginx/p10-req-body: waiting for ${DATA_URL}"
for _ in $(seq 1 30); do
    if curl -sS -o /dev/null --max-time 2 "${DATA_URL}/anything" 2>/dev/null; then
        say "data plane ready"
        break
    fi
    sleep 1
done

say "smoke: POST with secret -> expect injected=true, secret dropped"
body=$(curl -sS -X POST \
    -H 'Content-Type: application/json' \
    -d '{"msg":"hello","secret":"please-drop-me"}' \
    "${DATA_URL}/anything")

# go-httpbin echoes the parsed body under $.json and the raw bytes
# under $.data — check $.json.bench.injected so we are asserting on
# the post-rewrite payload, not on some matching needle elsewhere.
echo "${body}" | jq -e '.json.bench.injected == true' >/dev/null \
    || fail "\$.json.bench.injected is not true in echoed body"
echo "${body}" | jq -e '.json | has("secret") | not' >/dev/null \
    || fail "\$.json.secret leaked through rewrite"

say "nginx/p10-req-body ready"
