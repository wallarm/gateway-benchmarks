#!/usr/bin/env bash
# shellcheck shell=bash
#
# scripts/perf-local-cycle-smoke.sh
#
# Phase 5 — Local-mode end-to-end smoke. Exercises the 3-host
# emulation (loadgen ↔ gateway ↔ backend) brought up by
# `infra/local/docker-compose.yaml` with two minimal k6 scenarios:
#
#   1. s01-vanilla-http   over :9080        — proves the HTTP/1.1 data
#                                             plane round-trips end to
#                                             end through the gateway.
#   2. s13-vanilla-https  over :9443        — proves the Phase 5 TLS
#                                             plumbing terminates and
#                                             back-proxies cleanly
#                                             (only valid when the
#                                             active gateway profile
#                                             actually serves :9443 —
#                                             today p01-vanilla and
#                                             p12-full-pipeline do).
#
# Each scenario runs the lightest possible load profile (p1-baseline,
# 10 VUs × 60s) so the smoke completes in under two minutes wall time.
# k6 returns a non-zero exit on any failed threshold; this script
# bubbles that up unchanged so CI / Makefile fails loudly on
# regressions.
#
# Usage:
#
#   bash scripts/perf-local-cycle-smoke.sh
#       # uses GATEWAY_PROFILE from env (default: p01-vanilla)
#
# Prerequisites: `make perf-local-up` must have run first; this script
# only drives traffic through an already-up stack so that the up/down
# lifecycle is observable separately from the load itself.
#
# Output: writes summary JSONs to reports/local-smoke/ on the host
# (the loadgen container's /out is bind-mounted there per
# infra/local/.env.example).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

COMPOSE_FILE="infra/local/docker-compose.yaml"
ENV_FILE="infra/local/.env"
if [[ ! -f "${ENV_FILE}" ]]; then
    ENV_FILE="infra/local/.env.example"
fi

GATEWAY_PROFILE="${GATEWAY_PROFILE:-p01-vanilla}"
GATEWAY_NAME="${GATEWAY_NAME:-local-stack}"
RUN_ID="${RUN_ID:-local-smoke-$(date -u +%Y%m%dT%H%M%SZ)}"

echo "==> perf-local-cycle-smoke"
echo "    profile : ${GATEWAY_PROFILE}"
echo "    run-id  : ${RUN_ID}"
echo "    compose : ${COMPOSE_FILE}"
echo "    env-file: ${ENV_FILE}"
echo

# -----------------------------------------------------------------------------
# Sanity: the stack must already be up. We don't `up -d` here — that's
# the perf-local-up target's job. Forking lifecycle from work keeps
# debugging tractable when one or the other regresses.
# -----------------------------------------------------------------------------
if ! docker compose -f "${COMPOSE_FILE}" --env-file "${ENV_FILE}" ps --status running --format '{{.Service}}' | grep -q '^gateway$'; then
    echo "ERROR: the gateway service is not running."
    echo "       Run 'make perf-local-up' first, then re-invoke this script."
    exit 2
fi
if ! docker compose -f "${COMPOSE_FILE}" --env-file "${ENV_FILE}" ps --status running --format '{{.Service}}' | grep -q '^loadgen$'; then
    echo "ERROR: the loadgen service is not running."
    echo "       Run 'make perf-local-up' first, then re-invoke this script."
    exit 2
fi

# -----------------------------------------------------------------------------
# 1) HTTP/1.1 baseline — s01-vanilla-http over :9080
# -----------------------------------------------------------------------------
echo "==> [1/2] s01-vanilla-http over http://gateway:9080  (10 VUs × 60s)"

# k6 reads scenario from /k6/ (bind-mounted), writes summary to /out/
# (bind-mounted to reports/local-smoke/ on the host). Every BENCH_*
# env var matches scripts/load-gateway.sh's contract so the summary
# JSON is byte-equivalent to a Phase 4 sweep cell — the report
# generator (Phase 7) consumes it identically.
docker compose -f "${COMPOSE_FILE}" --env-file "${ENV_FILE}" exec -T \
    -e BENCH_TARGET_URL="http://gateway:9080" \
    -e BENCH_LOAD_PROFILE="p1-baseline" \
    -e BENCH_POLICY_PROFILE="${GATEWAY_PROFILE}" \
    -e BENCH_SCENARIO="s01-vanilla-http" \
    -e BENCH_GATEWAY="${GATEWAY_NAME}" \
    -e BENCH_RUN_ID="${RUN_ID}" \
    -e BENCH_RUN_SEED="42" \
    loadgen k6 run \
        --summary-export=/out/smoke-s01-summary.json \
        --quiet \
        /k6/scenarios/s01-vanilla-http.js

echo "    ✓ HTTP smoke passed"
echo

# -----------------------------------------------------------------------------
# 2) HTTPS baseline — s13-vanilla-https over :9443
# -----------------------------------------------------------------------------
# Only meaningful for profiles that actually expose :9443. Today that
# is p01-vanilla and p12-full-pipeline (each ships a `listen 9443
# ssl;` server block backed by gateways/_reference/tls/). For other
# profiles the 9443 port is unbound inside the container; we skip
# the HTTPS check rather than fail it, with a clear marker so the
# smoke remains useful as a fast feedback loop on every profile.
case "${GATEWAY_PROFILE}" in
    p01-vanilla|p12-full-pipeline)
        echo "==> [2/2] s13-vanilla-https over https://gateway:9443  (10 VUs × 60s)"

        # `--insecure-skip-tls-verify` because the cert is the
        # canonical self-signed bench.local pair under
        # gateways/_reference/tls/. Cert validation is meaningful
        # *internally* — k6 still negotiates a real handshake and the
        # `tls_handshaking observed on first iter` check fires inside
        # the scenario itself. The flag only opts out of CN/SAN +
        # CA-trust validation, not the handshake itself.
        docker compose -f "${COMPOSE_FILE}" --env-file "${ENV_FILE}" exec -T \
            -e BENCH_TARGET_URL="http://gateway:9080" \
            -e BENCH_TARGET_URL_HTTPS="https://gateway:9443" \
            -e BENCH_LOAD_PROFILE="p1-baseline" \
            -e BENCH_POLICY_PROFILE="${GATEWAY_PROFILE}" \
            -e BENCH_SCENARIO="s13-vanilla-https" \
            -e BENCH_GATEWAY="${GATEWAY_NAME}" \
            -e BENCH_RUN_ID="${RUN_ID}" \
            -e BENCH_RUN_SEED="42" \
            loadgen k6 run \
                --insecure-skip-tls-verify \
                --summary-export=/out/smoke-s13-summary.json \
                --quiet \
                /k6/scenarios/s13-vanilla-https.js

        echo "    ✓ HTTPS smoke passed"
        ;;
    *)
        echo "==> [2/2] HTTPS smoke skipped (GATEWAY_PROFILE=${GATEWAY_PROFILE} does not serve :9443)"
        echo "    Only p01-vanilla and p12-full-pipeline ship a TLS listener today;"
        echo "    re-run with GATEWAY_PROFILE=p01-vanilla to exercise s13/s14."
        ;;
esac

echo
echo "==> Summary JSONs:"
ls -lh "reports/local-smoke/smoke-"*.json 2>/dev/null || echo "    (no summaries on disk — bind-mount may have been overridden)"
echo
echo "All smoke checks PASSED."
