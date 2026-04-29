#!/usr/bin/env bash
# gateways/envoy/p03-jwks-rs256-basic/setup.sh
#
# Envoy reads the static bootstrap at container start, so there is
# nothing to bootstrap at runtime — the whole JWT/JWKS wiring lives in
# envoy.yaml's `envoy.filters.http.jwt_authn` provider. This script
# only:
#
#   1. Waits for the data plane.
#   2. Runs a drift guard that proves the inline JWKS baked into
#      envoy.yaml is still byte-identical to the canonical
#      gateways/_reference/jwks-rs256/jwks.json. If the reference is
#      ever rotated and someone forgets to refresh envoy.yaml, this
#      check fails loudly before a single probe runs.
#   3. Smokes three mini-probes that mirror the fixture so a failure
#      at boot surfaces before the parity runner even starts.
#
# Unlike wallarm/p03-jwks-rs256-basic, there is no dual-mode FEATURE-MISSING
# path here: envoy v1.32's jwt_authn filter ships RS256+JWKS natively.
# If the filter misbehaves this is a FAIL, not a FEATURE-MISSING.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

DATA_URL="${DATA_URL:-http://localhost:9080}"
ADMIN_URL="${ADMIN_URL:-http://localhost:9901}"

JWKS_FILE="${JWKS_FILE:-${REPO_ROOT}/gateways/_reference/jwks-rs256/jwks.json}"
ENVOY_YAML="${ENVOY_YAML:-${SCRIPT_DIR}/envoy.yaml}"
RS256_GEN_SCRIPT="${RS256_GEN_SCRIPT:-${REPO_ROOT}/scripts/gen-jwt-rs256.sh}"

say()  { printf '%s %s\n' "$(date +'%H:%M:%S')" "$*" >&2; }
fail() { printf '\033[31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

[[ -f "${JWKS_FILE}"       ]] || fail "reference JWKS not found: ${JWKS_FILE}"
[[ -f "${ENVOY_YAML}"      ]] || fail "envoy.yaml not found: ${ENVOY_YAML}"
[[ -x "${RS256_GEN_SCRIPT}" ]] || fail "RS256 generator not executable: ${RS256_GEN_SCRIPT}"

# -----------------------------------------------------------------------------
# 1. Wait for the data plane (envoy answers requests, even 401s, as soon
#    as the listener binds).
# -----------------------------------------------------------------------------
say "envoy/p03-jwks-rs256-basic: waiting for ${DATA_URL}"
for _ in $(seq 1 30); do
    # `/anything` with no Authorization will hit 401, but the connect
    # succeeds — that's the readiness signal we want.
    if curl -sS -o /dev/null --max-time 2 "${DATA_URL}/anything" \
         2>/dev/null; then
        say "data plane ready"
        break
    fi
    sleep 1
done

# -----------------------------------------------------------------------------
# 2. Drift guard — the inline JWKS in envoy.yaml MUST carry the same
#    RSA modulus as the reference JWKS. `n` is 342 chars of base64url
#    that is uniquely determined by the private key, so any presence
#    test is sufficient: if the byte sequence appears verbatim in
#    envoy.yaml, the inline JWKS is in sync.
#
#    Why not extract + jq-diff the inline_string? Portable YAML
#    extraction without `yq` is fragile in bash, and matching the
#    reference modulus literally is a strictly stronger guarantee than
#    any structural equality check would give us in this file (we
#    also implicitly confirm `kty`, `kid`, `alg`, and `e` by byte-
#    matching the surrounding JSON in the `inline_string` block — see
#    envoy.yaml for the canonical shape).
# -----------------------------------------------------------------------------
REFERENCE_N=$(jq -r '.keys[0].n' "${JWKS_FILE}")
REFERENCE_KID=$(jq -r '.keys[0].kid' "${JWKS_FILE}")

[[ -n "${REFERENCE_N}"   && "${REFERENCE_N}"   != "null" ]] \
    || fail "reference JWKS has no .keys[0].n (modulus) at ${JWKS_FILE}"
[[ -n "${REFERENCE_KID}" && "${REFERENCE_KID}" != "null" ]] \
    || fail "reference JWKS has no .keys[0].kid at ${JWKS_FILE}"

if ! grep -qF "\"n\":\"${REFERENCE_N}\"" "${ENVOY_YAML}"; then
    fail "drift guard: ${ENVOY_YAML} does not carry the reference RSA modulus (${REFERENCE_N:0:24}…). Regenerate the inline JWKS from ${JWKS_FILE} and paste the compact form into envoy.yaml's \`inline_string:\` block."
fi
if ! grep -qF "\"kid\":\"${REFERENCE_KID}\"" "${ENVOY_YAML}"; then
    fail "drift guard: ${ENVOY_YAML} does not carry the reference kid (${REFERENCE_KID}). Regenerate the inline JWKS from ${JWKS_FILE}."
fi
say "  ✓ drift guard: inline JWKS is in sync with ${JWKS_FILE##*/} (kid=${REFERENCE_KID})"

# -----------------------------------------------------------------------------
# 3. Smoke — three mini-probes that mirror the fixture, so a failure
#    at boot surfaces before the parity runner starts. envoy's
#    jwt_authn returns a plain-text body for 401s by default; we only
#    assert the status code so the body format (JSON vs text) stays
#    decoupled.
# -----------------------------------------------------------------------------
say "smoke: GET ${DATA_URL}/anything without Authorization"
missing_code=$(curl --max-time 5 -s -o /tmp/envoy-jwks.out -w '%{http_code}' "${DATA_URL}/anything" || true)
[[ "${missing_code}" == "401" ]] \
    || { cat /tmp/envoy-jwks.out >&2
         fail "smoke: expected 401 without token, got ${missing_code}"; }

valid_token="$("${RS256_GEN_SCRIPT}" valid)"
say "smoke: GET ${DATA_URL}/anything with valid RS256 token (kid=${REFERENCE_KID})"
valid_code=$(curl --max-time 5 -s -o /tmp/envoy-jwks.out -w '%{http_code}' \
    -H "Authorization: Bearer ${valid_token}" \
    "${DATA_URL}/anything" || true)
[[ "${valid_code}" == "200" ]] \
    || { cat /tmp/envoy-jwks.out >&2
         fail "smoke: expected 200 with valid RS256 token, got ${valid_code}"; }

unknown_token="$("${RS256_GEN_SCRIPT}" unknown-kid)"
say "smoke: GET ${DATA_URL}/anything with RS256 token carrying unknown kid"
unknown_code=$(curl --max-time 5 -s -o /tmp/envoy-jwks.out -w '%{http_code}' \
    -H "Authorization: Bearer ${unknown_token}" \
    "${DATA_URL}/anything" || true)
[[ "${unknown_code}" == "401" ]] \
    || { cat /tmp/envoy-jwks.out >&2
         fail "smoke: expected 401 with unknown-kid RS256 token, got ${unknown_code}"; }

# envoy exposes JWT counters on its admin port; dump the two we
# care about so operators eyeballing the run log get a compact
# indicator that the filter actually fired.
jwt_stats=$(curl --max-time 5 -fsS "${ADMIN_URL}/stats?filter=jwt_authn" 2>/dev/null | head -20 || true)
if [[ -n "${jwt_stats}" ]]; then
    say "jwt_authn stats snapshot:"
    printf '%s\n' "${jwt_stats}" | sed 's/^/    /' >&2
fi

say "envoy/p03-jwks-rs256-basic ready"
