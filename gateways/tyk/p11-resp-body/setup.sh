#!/usr/bin/env bash
# gateways/tyk/p11-resp-body/setup.sh

set -euo pipefail

DATA_URL="${DATA_URL:-http://localhost:9080}"
TYK_SECRET="${TYK_SECRET:-gateway-benchmarks}"

say()  { printf '%s %s\n' "$(date +'%H:%M:%S')" "$*" >&2; }
fail() { printf '\033[31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

say "tyk/p11-resp-body: waiting for ${DATA_URL}/hello"
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

# Verify the API def loaded with the transform_response wiring. Two
# entries: one for GET, one for POST, both pointing at the shared
# template file. The path-list assertion is intentionally tight — if
# Tyk silently dropped one of the entries (e.g. via path-pattern
# rejection), the count check below catches it.
api_list=$(curl --max-time 5 -sS -H "X-Tyk-Authorization: ${TYK_SECRET}" \
               "${DATA_URL}/tyk/apis" 2>/dev/null || true)
printf '%s' "${api_list}" \
    | jq -e '
        any(.[];
              .api_id == "bench"
          and (.version_data.versions.Default.extended_paths.transform_response | length) == 2
          and ([.version_data.versions.Default.extended_paths.transform_response[].method] | sort) == ["GET","POST"]
          and all(.version_data.versions.Default.extended_paths.transform_response[];
                  .template_data.input_type == "json"
                  and .template_data.template_mode == "file"
                  and (.template_data.template_source | endswith("/p11_response_rewrite.tmpl"))))' \
    >/dev/null 2>&1 \
    || fail "API definition 'bench' missing or transform_response not wired (GET+POST + shared template)"
say "  ✓ /tyk/apis registers bench with transform_response on GET+POST -> shared template"

say "smoke: GET /anything -> upstream JSON gets bench.injected and loses origin"
out=$(curl --max-time 5 -sS "${DATA_URL}/anything" || true)
saw_inj=$(printf '%s' "${out}" | jq -r '.bench.injected // empty')
saw_org=$(printf '%s' "${out}" | jq -r '.origin // empty')
[[ "${saw_inj}" == "true" ]] || fail "GET response did not have bench.injected=true (saw: '${saw_inj}')"
[[ -z "${saw_org}" ]]        || fail "GET response still has origin (saw: '${saw_org}')"
say "  ✓ GET /anything: bench.injected=true present, origin absent"

say "smoke: POST /anything -> response also rewritten"
out=$(curl --max-time 5 -sS -H 'Content-Type: application/json' \
            --data '{"msg":"smoke"}' \
            "${DATA_URL}/anything" || true)
saw_inj=$(printf '%s' "${out}" | jq -r '.bench.injected // empty')
saw_org=$(printf '%s' "${out}" | jq -r '.origin // empty')
[[ "${saw_inj}" == "true" ]] || fail "POST response did not have bench.injected=true (saw: '${saw_inj}')"
[[ -z "${saw_org}" ]]        || fail "POST response still has origin (saw: '${saw_org}')"
say "  ✓ POST /anything: bench.injected=true present, origin absent"

say "tyk/p11-resp-body ready"
