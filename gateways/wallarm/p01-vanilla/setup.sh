#!/usr/bin/env bash
# gateways/wallarm/p01-vanilla/setup.sh
#
# Bootstrap the p01-vanilla policy profile via the Wallarm Admin API.
# Idempotent: safe to re-run — duplicate-create errors (409) are tolerated.
#
# NOTE: the Wallarm gateway (the pinned image) rejects `base_path: "/"`
# with error INVALID_BASE_PATH. Catch-all support was added after that
# public release. As a workaround we register one service per path
# prefix used by the fixtures. See NOTES.md § Deviations for details.
#
# Environment:
#   ADMIN_URL     (default http://localhost:9081) - Admin API base
#   DATA_URL      (default http://localhost:9080) - data plane (smoke)
#   BACKEND_URL   (default http://backend:8080)  - upstream, resolved
#                                                  from inside the gateway
#                                                  container via docker DNS
set -euo pipefail

ADMIN_URL="${ADMIN_URL:-http://localhost:9081}"
DATA_URL="${DATA_URL:-http://localhost:9080}"
BACKEND_URL="${BACKEND_URL:-http://backend:8080}"

say()  { printf '%s %s\n' "$(date +'%H:%M:%S')" "$*" >&2; }
fail() { printf '\033[31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

# -----------------------------------------------------------------------------
# 1. Wait for the Admin API
# -----------------------------------------------------------------------------
say "wallarm/p01-vanilla: bootstrap via ${ADMIN_URL}"
for _ in $(seq 1 60); do
    if curl -fsS "${ADMIN_URL}/health" >/dev/null 2>&1; then
        say "admin API ready"
        break
    fi
    sleep 1
done
curl -fsS "${ADMIN_URL}/health" >/dev/null 2>&1 \
    || fail "admin API did not come up at ${ADMIN_URL}"

# -----------------------------------------------------------------------------
# 2. Register one service per path prefix
#
# For a true catch-all we would register `base_path: "/"` once, but
# the Wallarm gateway forbids that. On top of that, wallarm STRIPS base_path
# before forwarding upstream, so we point each service's target URL at
# the matching backend prefix. Net effect for the client:
#
#   GET /anything/foo  →  (strip /anything) →  upstream /anything/foo
#
# The set below covers every prefix the fixtures touch for p01..p12.
# -----------------------------------------------------------------------------
create_service() {
    local name="$1" prefix="$2"
    local body
    body=$(jq -cn \
        --arg name    "${name}" \
        --arg bp      "${prefix}" \
        --arg backend "${BACKEND_URL}${prefix}" \
        '{name:$name, base_path:$bp, target:{endpoint:{url:$backend}}}')

    local http_code
    http_code=$(curl -sS -o /tmp/wallarm-setup.out -w '%{http_code}' \
        -X POST "${ADMIN_URL}/services" \
        -H "Content-Type: application/json" \
        -d "${body}" || true)

    case "${http_code}" in
        200|201) say "  ✓ service ${name} (base_path=${prefix} → ${BACKEND_URL}${prefix})";;
        409)     say "  · service ${name} already exists";;
        *)       cat /tmp/wallarm-setup.out >&2
                 fail "service ${name} create returned ${http_code}";;
    esac

    # Attach a catch-all route so that /<prefix>/<suffix> passes through.
    local route_code
    route_code=$(curl -sS -o /tmp/wallarm-setup.out -w '%{http_code}' \
        -X POST "${ADMIN_URL}/services/${name}/routes" \
        -H "Content-Type: application/json" \
        -d '{"id":"catchall","condition":{"path":["/**"]}}' || true)
    case "${route_code}" in
        200|201|409) ;;
        *) cat /tmp/wallarm-setup.out >&2
           fail "service ${name} route create returned ${route_code}";;
    esac
}

create_service "bench-anything"         "/anything"
create_service "bench-bytes"            "/bytes"
create_service "bench-status"           "/status"
# The two below are not required by p01 but are registered anyway so
# the same setup.sh can be re-used by p07/p08 once those profiles land.
create_service "bench-headers"          "/headers"
create_service "bench-response-headers" "/response-headers"

# -----------------------------------------------------------------------------
# 3. Smoke — confirm the data plane proxies at least one endpoint.
# -----------------------------------------------------------------------------
say "smoke: GET ${DATA_URL}/anything"
smoke=$(curl -fsS "${DATA_URL}/anything" 2>&1) || {
    printf '%s\n' "${smoke}" >&2
    fail "smoke request failed"
}
printf '%s\n' "${smoke}" | jq -c '{smoke:"ok", method:.method, url:.url}' >&2

say "wallarm/p01-vanilla ready"
