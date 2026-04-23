#!/usr/bin/env bash
# gateways/apisix/p03-jwks-rs256-basic/setup.sh
#
# Post-up readiness check + 3-probe smoke for the p03
# `p03-jwks-rs256-basic` scenario on apisix.
#
# The policy binding is a file-config binding: the route with the
# `openid-connect` plugin is materialised inside the container at
# boot from `apisix.yaml` (standalone mode). Nothing needs to be
# POSTed at runtime. This script therefore only:
#
#   1. Waits for the data plane.
#   2. Drift-guards the canonical JWKS file behind `oidc-server`
#      against `gateways/_reference/jwks-rs256/jwks.json`.
#   3. Smokes three mini-probes that mirror the fixture so a boot-
#      time misconfiguration surfaces before the parity runner even
#      starts.
#
# Non-zero exit codes:
#   1  — generic FAIL (configuration error, container misbehaving)
#   42 — FEATURE-MISSING (reserved; currently not reachable here
#                         because apisix 3.15 ships openid-connect
#                         with RS256+JWKS natively)
#
# Why no dual-mode path? APISIX 3.x ships `openid-connect` by default.
# A hypothetical future APISIX drop of the plugin or of the
# `use_jwks` flag would flip this to FEATURE-MISSING; for now a
# failure here is a real failure.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

DATA_URL="${DATA_URL:-http://localhost:9080}"

JWKS_FILE="${JWKS_FILE:-${REPO_ROOT}/gateways/_reference/jwks-rs256/jwks.json}"
APISIX_YAML="${APISIX_YAML:-${SCRIPT_DIR}/apisix.yaml}"
DISCOVERY_JSON="${DISCOVERY_JSON:-${REPO_ROOT}/gateways/apisix/_oidc-server/openid-configuration.json}"
RS256_GEN_SCRIPT="${RS256_GEN_SCRIPT:-${REPO_ROOT}/scripts/gen-jwt-rs256.sh}"

SMOKE_OUT="/tmp/apisix-p03-jwks-rs256-basic.out"

say()  { printf '%s %s\n' "$(date +'%H:%M:%S')" "$*" >&2; }
fail() { printf '\033[31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

[[ -f "${JWKS_FILE}"        ]] || fail "reference JWKS not found: ${JWKS_FILE}"
[[ -f "${APISIX_YAML}"      ]] || fail "apisix.yaml not found: ${APISIX_YAML}"
[[ -f "${DISCOVERY_JSON}"   ]] || fail "OIDC discovery doc not found: ${DISCOVERY_JSON}"
[[ -x "${RS256_GEN_SCRIPT}" ]] || fail "RS256 generator not executable: ${RS256_GEN_SCRIPT}"

# -----------------------------------------------------------------------------
# 1. Wait for the data plane.
#
#    APISIX's startup sequence (in standalone mode) is:
#      1) parse conf/config.yaml + conf/apisix.yaml
#      2) load plugins listed in `apisix.plugins`
#      3) open the data listener on :9080
#      4) start reloading apisix.yaml every second
#
#    Until step 3 the TCP connection fails; we poll until any HTTP
#    status comes back. The route we defined is a catch-all, so even
#    an unauthenticated request answers with 401 as soon as the
#    plugin chain is live — that is the readiness signal.
# -----------------------------------------------------------------------------
say "apisix/p03-jwks-rs256-basic: waiting for ${DATA_URL}"
ready=0
for _ in $(seq 1 60); do
    http_code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 2 \
        "${DATA_URL}/anything" 2>/dev/null || echo "000")
    if [[ "${http_code}" =~ ^[1-5][0-9]{2}$ ]]; then
        ready=1
        break
    fi
    sleep 1
done
(( ready == 1 )) || fail "apisix data plane never answered on ${DATA_URL}"
say "  ✓ data plane answering on ${DATA_URL}"

# -----------------------------------------------------------------------------
# 2. Drift guard — the JWKS `oidc-server` serves MUST match
#    `_reference/jwks-rs256/jwks.json`. Same pattern as
#    `gateways/tyk/p03-jwks-rs256-basic/setup.sh` — we dump the JWKS
#    from INSIDE the `oidc-server` container so what we verify is
#    what APISIX actually fetches over `bench-net`, not whatever
#    happens to be on the loadgen-side filesystem.
#
#    Also sanity-check the discovery document — `openid-connect`
#    expects `issuer` to match the JWT's `iss` claim and `jwks_uri`
#    to resolve. Both are hand-crafted in this repo so drift would
#    be a human error, not runtime rotation.
# -----------------------------------------------------------------------------
served_jwks=$(docker exec gwb-apisix-oidc-server sh -c \
    'wget -qO- http://127.0.0.1/.well-known/jwks.json' 2>/dev/null || true)
[[ -n "${served_jwks}" ]] || fail "oidc-server returned empty body for /.well-known/jwks.json"

served_discovery=$(docker exec gwb-apisix-oidc-server sh -c \
    'wget -qO- http://127.0.0.1/.well-known/openid-configuration' 2>/dev/null || true)
[[ -n "${served_discovery}" ]] || fail "oidc-server returned empty body for /.well-known/openid-configuration"

reference_n=$(jq -r   '.keys[0].n'   "${JWKS_FILE}")
reference_kid=$(jq -r '.keys[0].kid' "${JWKS_FILE}")
[[ -n "${reference_n}"   && "${reference_n}"   != "null" ]] \
    || fail "reference JWKS has no .keys[0].n"
[[ -n "${reference_kid}" && "${reference_kid}" != "null" ]] \
    || fail "reference JWKS has no .keys[0].kid"

served_n=$(  printf '%s' "${served_jwks}" | jq -r '.keys[0].n')
served_kid=$(printf '%s' "${served_jwks}" | jq -r '.keys[0].kid')

[[ "${served_n}"   == "${reference_n}"   ]] \
    || fail "drift guard: oidc-server served modulus differs from ${JWKS_FILE##*/} (got ${served_n:0:24}…, expected ${reference_n:0:24}…)"
[[ "${served_kid}" == "${reference_kid}" ]] \
    || fail "drift guard: oidc-server served kid '${served_kid}' != reference kid '${reference_kid}'"

# Discovery doc's `issuer` MUST match our JWT payload's `iss` claim
# (canonical `gateway-benchmarks`, see
# gateways/_reference/jwt/payload-template.json). If someone edits
# one without the other, bearer_jwt_verify rejects every token with
# `issuer mismatch` and the error would take five minutes to diagnose.
discovery_issuer=$(printf '%s' "${served_discovery}" | jq -r '.issuer')
discovery_jwks_uri=$(printf '%s' "${served_discovery}" | jq -r '.jwks_uri')
payload_iss=$(jq -r '.iss' "${REPO_ROOT}/gateways/_reference/jwt/payload-template.json")
[[ "${discovery_issuer}" == "${payload_iss}" ]] \
    || fail "drift guard: discovery.issuer '${discovery_issuer}' != JWT payload iss '${payload_iss}'"
[[ "${discovery_jwks_uri}" == "http://oidc-server/.well-known/jwks.json" ]] \
    || fail "drift guard: discovery.jwks_uri '${discovery_jwks_uri}' is not the canonical sidecar URL"
say "  ✓ drift guard: oidc-server is in sync with ${JWKS_FILE##*/} (kid=${reference_kid}, iss=${discovery_issuer})"

# -----------------------------------------------------------------------------
# 3. Smoke — three mini-probes that mirror the fixture.
#
#    No deviations expected: APISIX 3.15 + openid-connect returns a
#    canonical 401 on every rejection path (missing / expired /
#    unknown-kid), so smoke probes are strict on status.
#
#    First probe (no Authorization) can be served before the plugin's
#    JWKS cache has been warmed — it never reaches signature
#    verification. The second probe warms the cache; the third probe
#    then exercises kid-lookup against the same cached JWKS.
# -----------------------------------------------------------------------------
say "smoke: GET ${DATA_URL}/anything without Authorization"
missing_code=$(curl -s -o "${SMOKE_OUT}" -w '%{http_code}' \
    "${DATA_URL}/anything" || true)
[[ "${missing_code}" == "401" ]] \
    || { cat "${SMOKE_OUT}" >&2
         fail "smoke (no-auth): expected 401, got ${missing_code}"; }

valid_token="$("${RS256_GEN_SCRIPT}" valid)"
say "smoke: GET ${DATA_URL}/anything with valid RS256 token (kid=${reference_kid})"
valid_code=$(curl -s -o "${SMOKE_OUT}" -w '%{http_code}' \
    -H "Authorization: Bearer ${valid_token}" \
    "${DATA_URL}/anything" || true)
[[ "${valid_code}" == "200" ]] \
    || { cat "${SMOKE_OUT}" >&2
         fail "smoke (valid-token): expected 200, got ${valid_code} — signature / kid lookup broken"; }

unknown_token="$("${RS256_GEN_SCRIPT}" unknown-kid)"
say "smoke: GET ${DATA_URL}/anything with RS256 token carrying unknown kid"
unknown_code=$(curl -s -o "${SMOKE_OUT}" -w '%{http_code}' \
    -H "Authorization: Bearer ${unknown_token}" \
    "${DATA_URL}/anything" || true)
[[ "${unknown_code}" == "401" ]] \
    || { cat "${SMOKE_OUT}" >&2
         fail "smoke (unknown-kid): expected 401, got ${unknown_code} — kid lookup fell back to the one available key (collapsed probe 3)"; }

say "apisix/p03-jwks-rs256-basic ready"
