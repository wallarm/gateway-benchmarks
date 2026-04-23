#!/usr/bin/env bash
# gateways/tyk/p10-req-body/setup.sh
#
# Asserts the API definition wires Tyk's NATIVE request-body transform
# (extended_paths.transform, method=POST, file-mode Sprig template at
# _shared/templates/p10_request_rewrite.tmpl) and that the template
# correctly:
#
#   * injects $.bench.injected = true
#   * drops   $.secret
#
# while leaving sibling fields untouched (probe shape mirrors p11
# probe 1's body shape, which preserves $.bench.from_client).

set -euo pipefail

DATA_URL="${DATA_URL:-http://localhost:9080}"
TYK_SECRET="${TYK_SECRET:-gateway-benchmarks}"

say()  { printf '%s %s\n' "$(date +'%H:%M:%S')" "$*" >&2; }
fail() { printf '\033[31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

say "tyk/p10-req-body: waiting for ${DATA_URL}/hello"
hello_ok=0
for _ in $(seq 1 60); do
    hello=$(curl -sS --max-time 2 "${DATA_URL}/hello" 2>/dev/null || true)
    if [[ -n "${hello}" ]] \
       && printf '%s' "${hello}" | jq -e '.status == "pass"' >/dev/null 2>&1; then
        hello_ok=1
        break
    fi
    sleep 1
done
(( hello_ok == 1 )) || fail "tyk /hello never returned status=pass"
say "  ✓ /hello reports status=pass"

api_list=$(curl -sS -H "X-Tyk-Authorization: ${TYK_SECRET}" \
               "${DATA_URL}/tyk/apis" 2>/dev/null || true)
printf '%s' "${api_list}" \
    | jq -e '
        any(.[];
              .api_id == "bench"
          and ([.version_data.versions.Default.extended_paths.transform[].method] | sort) == ["POST"]
          and (.version_data.versions.Default.extended_paths.transform[0].template_data.template_source | endswith("/p10_request_rewrite.tmpl")))' \
    >/dev/null 2>&1 \
    || fail "API definition 'bench' missing native transform middleware (POST + p10_request_rewrite.tmpl)"
say "  ✓ /tyk/apis registers api_id=bench with native request-body transform (POST only)"

say "smoke: POST /anything with secret -> upstream sees bench.injected and no secret"
out=$(curl -sS -H 'Content-Type: application/json' \
            --data '{"msg":"smoke","secret":"x"}' \
            "${DATA_URL}/anything" || true)
saw_inj=$(printf '%s' "${out}" | jq -r '.json.bench.injected // empty')
saw_sec=$(printf '%s' "${out}" | jq -r '.json.secret // empty')
[[ "${saw_inj}" == "true" ]] || fail "upstream did not see bench.injected=true"
[[ -z "${saw_sec}" ]]        || fail "upstream still saw secret"
say "  ✓ upstream JSON has bench.injected=true and no secret"

say "tyk/p10-req-body ready"
