#!/usr/bin/env bash
# shellcheck shell=bash
#
# Mint an RS256 JWT using the `p03-jwks-rs256-basic` material.
# No external packages: bash + openssl + jq only.
#
# This generator is deliberately separate from `gen-jwt.sh` (HS256)
# so the canonical `p02-jwt` probe path stays untouched. It powers
# the p03-jwks-rs256-basic scenario described in
# [`fixtures/p03-jwks-rs256-basic.jsonl`](../fixtures/p03-jwks-rs256-basic.jsonl)
# and [`docs/POLICIES.md § p03-jwks-rs256-basic`](../docs/POLICIES.md).
#
# Usage:
#   gen-jwt-rs256.sh <kind>
#     valid         — correctly signed with the canonical kid,
#                     exp = now + JWT_EXPIRY_S (default 3600)
#     unknown-kid   — correctly signed, but `kid` header is set to an
#                     unknown value (default: `unknown-kid-2026`).
#                     Verifiers that perform a JWKS `kid` lookup must
#                     reject this token; verifiers that only check the
#                     signature against a single static key will
#                     accept it, and that is itself a diagnostic signal.
#
# Reads from gateways/_reference/jwks-rs256/{private.pem, kid.txt} and
# gateways/_reference/jwt/payload-template.json so the claim shape
# stays in lockstep with the HS256 probes.

set -euo pipefail

# -----------------------------------------------------------------------------
# Locate the repo root (the script lives in <repo>/scripts/).
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REF="${REPO_ROOT}/gateways/_reference"

PRIVATE_KEY_FILE="${PRIVATE_KEY_FILE:-${REF}/jwks-rs256/private.pem}"
KID_FILE="${KID_FILE:-${REF}/jwks-rs256/kid.txt}"
PAYLOAD_FILE="${PAYLOAD_FILE:-${REF}/jwt/payload-template.json}"

: "${JWT_EXPIRY_S:=86400}"
: "${JWT_UNKNOWN_KID_VALUE:=unknown-kid-2026}"

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
die()  { printf 'gen-jwt-rs256.sh: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing dependency: $1"; }
need openssl
need jq
need date

b64url() {
    # RFC 7515 §2: base64url, no padding.
    openssl base64 -A | tr '+/' '-_' | tr -d '='
}

rs256_sign_b64url() {
    # RS256 JWT signature = raw PKCS#1 v1.5 signature over SHA-256(signing_input),
    # base64url-encoded without padding. `openssl dgst -sha256 -sign <pem>`
    # emits exactly that raw byte string for RSA keys (no DER wrapper, unlike
    # ECDSA), so a straight `| b64url` does the job.
    local private_key_file="$1"
    openssl dgst -sha256 -sign "${private_key_file}" -binary | b64url
}

# -----------------------------------------------------------------------------
# Arg parsing
# -----------------------------------------------------------------------------
KIND="${1:-valid}"
case "${KIND}" in
    valid|unknown-kid) ;;
    *) die "unknown kind '${KIND}', expected: valid | unknown-kid" ;;
esac

[[ -f "${PRIVATE_KEY_FILE}" ]] || die "private key not found at ${PRIVATE_KEY_FILE}"
[[ -f "${KID_FILE}"         ]] || die "kid file not found at ${KID_FILE}"
[[ -f "${PAYLOAD_FILE}"     ]] || die "payload template not found at ${PAYLOAD_FILE}"

CANONICAL_KID="$(tr -d '\r\n' < "${KID_FILE}")"
[[ -n "${CANONICAL_KID}" ]] || die "kid file is empty"

# -----------------------------------------------------------------------------
# Pick the kid to stamp into the JWT header
# -----------------------------------------------------------------------------
case "${KIND}" in
    valid)
        header_kid="${CANONICAL_KID}"
        ;;
    unknown-kid)
        header_kid="${JWT_UNKNOWN_KID_VALUE}"
        ;;
esac

# -----------------------------------------------------------------------------
# Build header + payload
# -----------------------------------------------------------------------------
now="$(date +%s)"
exp=$(( now + JWT_EXPIRY_S ))

header_json=$(jq -cn --arg kid "${header_kid}" \
    '{alg:"RS256", typ:"JWT", kid:$kid}')

payload_json=$(jq -c \
    --argjson now "${now}" \
    --argjson exp "${exp}" \
    '. + {iat:$now, exp:$exp}' \
    "${PAYLOAD_FILE}")

h=$(printf '%s' "${header_json}"  | b64url)
p=$(printf '%s' "${payload_json}" | b64url)

signing_input="${h}.${p}"

# Always sign with the real private key — the `unknown-kid` case
# intentionally yields a token whose signature IS verifiable, but whose
# header claims a kid that the verifier's JWKS does not carry. That is
# exactly the scenario we want to measure: JWKS lookup by kid, not
# "does any signature we ever minted verify".
sig=$(printf '%s' "${signing_input}" | rs256_sign_b64url "${PRIVATE_KEY_FILE}")

printf '%s.%s\n' "${signing_input}" "${sig}"
