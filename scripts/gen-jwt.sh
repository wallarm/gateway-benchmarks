#!/usr/bin/env bash
# shellcheck shell=bash
#
# Mint a HS256 JWT using the canonical benchmark material.
# No external packages: bash + openssl + jq only.
#
# Usage:
#   gen-jwt.sh <kind>
#     valid           — correctly signed, exp = now + JWT_EXPIRY_S (default 3600)
#     expired         — correctly signed, exp = now - 3600
#     wrong-secret    — signed with a different secret, otherwise valid
#
# Reads from gateways/_reference/jwt/{secret.txt,payload-template.json}
# so everything stays in sync with docs/POLICIES.md.

set -euo pipefail

# -----------------------------------------------------------------------------
# Locate the repo root (the script lives in <repo>/scripts/).
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REF="${REPO_ROOT}/gateways/_reference"

SECRET_FILE="${REF}/jwt/secret.txt"
PAYLOAD_FILE="${REF}/jwt/payload-template.json"

: "${JWT_EXPIRY_S:=3600}"
: "${JWT_KID:=bench-hs256-2026}"

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
die()  { printf 'gen-jwt.sh: %s\n' "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "missing dependency: $1"; }
need openssl
need jq
need date

b64url() {
    # RFC 7515 §2: base64url, no padding.
    openssl base64 -A | tr '+/' '-_' | tr -d '='
}

hmac_sha256_b64url() {
    local key="$1"
    openssl dgst -sha256 -hmac "${key}" -binary | b64url
}

# -----------------------------------------------------------------------------
# Arg parsing
# -----------------------------------------------------------------------------
KIND="${1:-valid}"
case "${KIND}" in
    valid|expired|wrong-secret) ;;
    *) die "unknown kind '${KIND}', expected: valid | expired | wrong-secret" ;;
esac

[[ -f "${SECRET_FILE}"  ]] || die "secret not found at ${SECRET_FILE}"
[[ -f "${PAYLOAD_FILE}" ]] || die "payload template not found at ${PAYLOAD_FILE}"

SECRET="$(tr -d '\n' < "${SECRET_FILE}")"
[[ -n "${SECRET}" ]] || die "secret file is empty"

# -----------------------------------------------------------------------------
# Build header + payload
# -----------------------------------------------------------------------------
now="$(date +%s)"

case "${KIND}" in
    valid)
        exp=$(( now + JWT_EXPIRY_S ))
        signing_secret="${SECRET}"
        ;;
    expired)
        exp=$(( now - 3600 ))
        signing_secret="${SECRET}"
        ;;
    wrong-secret)
        exp=$(( now + JWT_EXPIRY_S ))
        signing_secret="${SECRET}-tampered"
        ;;
esac

header_json=$(jq -cn --arg kid "${JWT_KID}" \
    '{alg:"HS256", typ:"JWT", kid:$kid}')

payload_json=$(jq -c \
    --argjson now "${now}" \
    --argjson exp "${exp}" \
    '. + {iat:$now, exp:$exp}' \
    "${PAYLOAD_FILE}")

h=$(printf '%s' "${header_json}"  | b64url)
p=$(printf '%s' "${payload_json}" | b64url)

signing_input="${h}.${p}"
sig=$(printf '%s' "${signing_input}" | hmac_sha256_b64url "${signing_secret}")

printf '%s.%s\n' "${signing_input}" "${sig}"
