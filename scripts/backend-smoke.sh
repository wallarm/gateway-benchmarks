#!/usr/bin/env bash
# shellcheck shell=bash
#
# Smoke-test the vendored go-httpbin backend.
# Exits non-zero on the first failed check.
#
# Usage: backend-smoke.sh [port]
#
set -euo pipefail

PORT="${1:-8080}"
BASE="http://localhost:${PORT}"

GREEN=$'\033[0;32m'
RED=$'\033[0;31m'
YELLOW=$'\033[1;33m'
NC=$'\033[0m'

pass=0
fail=0

check() {
    local name="$1"
    local expected="$2"
    local actual="$3"

    if [[ "${actual}" == "${expected}" ]]; then
        echo "  ${GREEN}PASS${NC}  ${name}  (got ${actual})"
        pass=$((pass + 1))
    else
        echo "  ${RED}FAIL${NC}  ${name}  (expected ${expected}, got ${actual})"
        fail=$((fail + 1))
    fi
}

echo "${YELLOW}==> waiting for backend at ${BASE}...${NC}"
for _ in $(seq 1 30); do
    if curl -fsS -o /dev/null "${BASE}/status/200" 2>/dev/null; then
        break
    fi
    sleep 1
done

if ! curl -fsS -o /dev/null "${BASE}/status/200" 2>/dev/null; then
    echo "${RED}ERROR${NC}  backend not reachable at ${BASE}"
    exit 1
fi

echo "${YELLOW}==> endpoints${NC}"

check "GET  /status/200 -> 200" \
    "200" \
    "$(curl -s -o /dev/null -w '%{http_code}' "${BASE}/status/200")"

check "GET  /status/404 -> 404" \
    "404" \
    "$(curl -s -o /dev/null -w '%{http_code}' "${BASE}/status/404")"

check "GET  /bytes/1024 -> 1024 bytes" \
    "1024" \
    "$(curl -s "${BASE}/bytes/1024" | wc -c | tr -d ' ')"

check "POST /post echoes body" \
    "hello-benchmark" \
    "$(curl -s -XPOST -d 'hello-benchmark' "${BASE}/post" \
        | python3 -c 'import sys,json; print(json.load(sys.stdin)["data"])' 2>/dev/null || echo '')"

check "GET  /anything echoes method" \
    "GET" \
    "$(curl -s "${BASE}/anything" \
        | python3 -c 'import sys,json; print(json.load(sys.stdin)["method"])' 2>/dev/null || echo '')"

check "GET  /headers echoes host" \
    "localhost:${PORT}" \
    "$(curl -s "${BASE}/headers" \
        | python3 -c 'import sys,json; h=json.load(sys.stdin)["headers"]; print(h.get("Host",[""])[0])' 2>/dev/null || echo '')"

check "GET  /gzip -> gzip encoding" \
    "gzip" \
    "$(curl -s --compressed -D - "${BASE}/gzip" -o /dev/null | awk -F': ' 'tolower($1) == "content-encoding" {print $2}' | tr -d '\r\n')"

echo
echo "${YELLOW}==> result${NC}"
if [[ ${fail} -eq 0 ]]; then
    echo "  ${GREEN}PASS${NC}  ${pass}/${pass} checks passed"
    exit 0
else
    echo "  ${RED}FAIL${NC}  ${fail} check(s) failed, ${pass} passed"
    exit 1
fi
