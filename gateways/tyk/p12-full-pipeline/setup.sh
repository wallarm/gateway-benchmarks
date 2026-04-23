#!/usr/bin/env bash
# gateways/tyk/p12-full-pipeline/setup.sh
#
# Asserts the API definition wires every primitive p11 needs, in the
# order documented in apis/bench.json:
#
#   1. JWT (HS256, hash-keyed sessions, default policy)
#   2. global_rate_limit 1000/1s (RateLimitForAPI)
#   3. transform (native Go-template + Sprig request body rewrite,
#      method=POST only — see apis/bench.json _comment_4 for why this
#      replaced the JSVM `pre` middleware p11 originally tried)
#   4. transform_headers (POST + GET)
#   5. transform_response_headers (POST + GET)
#   6. transform_response (POST + GET)
#
# No probe smoke is run from setup.sh — the canonical
# parity-attestation.sh runner exercises all four probes and captures
# the cosmetic missing-Authorization 400/401 mismatch in the JSONL
# report on its own.

set -euo pipefail

DATA_URL="${DATA_URL:-http://localhost:9080}"
TYK_SECRET="${TYK_SECRET:-gateway-benchmarks}"

say()  { printf '%s %s\n' "$(date +'%H:%M:%S')" "$*" >&2; }
fail() { printf '\033[31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

say "tyk/p12-full-pipeline: waiting for ${DATA_URL}/hello"
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

# Verify the API def loaded with every primitive wired up:
#   - enable_jwt + HMAC + default policy
#   - global_rate_limit 1000/1s
#   - extended_paths.transform[]                  for POST
#   - extended_paths.transform_headers[]          for {GET,POST}
#   - extended_paths.transform_response_headers[] for {GET,POST}
#   - extended_paths.transform_response[]         for {GET,POST}
#
# `transform` deliberately registers POST only. mw_transform.go
# parses the body unconditionally on a path/method match, so wiring
# it on GET would force a body-parse round-trip on every burst hop
# for no semantic gain (probe 4 sends no body).
api_list=$(curl -sS -H "X-Tyk-Authorization: ${TYK_SECRET}" \
               "${DATA_URL}/tyk/apis" 2>/dev/null || true)
printf '%s' "${api_list}" \
    | jq -e '
        any(.[];
              .api_id == "bench"
          and .enable_jwt == true
          and .jwt_signing_method == "hmac"
          and .global_rate_limit.rate == 1000
          and .global_rate_limit.per  == 1
          and ([.version_data.versions.Default.extended_paths.transform[].method]                 | sort) == ["POST"]
          and (.version_data.versions.Default.extended_paths.transform[0].template_data.template_source | endswith("/p10_request_rewrite.tmpl"))
          and ([.version_data.versions.Default.extended_paths.transform_headers[].method]          | sort) == ["GET","POST"]
          and ([.version_data.versions.Default.extended_paths.transform_response_headers[].method] | sort) == ["GET","POST"]
          and ([.version_data.versions.Default.extended_paths.transform_response[].method]         | sort) == ["GET","POST"])' \
    >/dev/null 2>&1 \
    || fail "API definition 'bench' missing one of: enable_jwt, global_rate_limit, transform (POST), transform_headers, transform_response_headers, transform_response"
say "  ✓ /tyk/apis registers bench with full p11 pipeline (JWT + RL + native body rewrite + headers + response)"

# Confirm the policy that JWT-keyed sessions attach to is loaded and
# grants the bench API. Without this, every signed token is rejected
# with 'no session found for token user identity'.
policies=$(curl -sS -H "X-Tyk-Authorization: ${TYK_SECRET}" \
                "${DATA_URL}/tyk/policies" 2>/dev/null || true)
printf '%s' "${policies}" \
    | jq -e 'to_entries | any(.value.access_rights.bench.api_id == "bench")' \
    >/dev/null 2>&1 \
    || fail "bench-default-policy missing or does not grant access to api_id=bench"
say "  ✓ /tyk/policies has bench-default-policy with bench API in access_rights"

say "tyk/p12-full-pipeline ready (probe-by-probe verdicts deferred to parity-attestation)"
