#!/usr/bin/env bash
# shellcheck shell=bash
#
# Phase 4 — k6 load runner for a single (gateway, policy, scenario,
# load-profile) cell. Mirrors `scripts/parity-gateway.sh` byte-for-
# byte on lifecycle (compose up → setup → parity precondition →
# work → trap-based teardown), with the "work" step swapped from
# `parity-attestation.sh` to `k6 run`.
#
# Lifecycle:
#
#   1. docker compose up the gateway stack (gateway + backend) on
#      `bench-net`.
#   2. Wait for the data plane on host :9080 to answer.
#   3. Run gateways/<gw>/<policy>/setup.sh to configure policies.
#   4. Run scripts/parity-attestation.sh as a *precondition*. If the
#      cell would not pass parity, the load run is skipped (the
#      report would mark it `excluded` per docs/REPORT.md) — this
#      mirrors the orchestrator's plan in TASK §7.
#   5. Mint scenario-specific JWT(s) on the host (k6 cannot exec).
#   6. Launch `grafana/k6:1.7.1@sha256:...` on the same `bench-net`,
#      pointed at `http://gateway:9080`. The container mounts:
#         k6/         (read-only) → /k6
#         <output>    (read-write)→ /out
#      and emits k6-summary.json + (optional) stream.json.gz.
#   7. trap-based docker compose down regardless of outcome.
#
# Output layout (matches docs/REPORT.md § 5):
#
#   reports/<RUN_ID>/raw/<gw>/<policy>__<load>__<scenario>/
#   ├── k6-summary.json
#   ├── k6-stream.json.gz       (only when STREAM=1)
#   ├── parity.json             (the precondition result)
#   └── logs/
#       ├── compose.log
#       └── k6.log
#
# Usage:
#   scripts/load-gateway.sh \
#     --gateway  <name>         e.g. nginx
#     --policy   <pXX-slug>     e.g. p01-vanilla
#     --scenario <sNN-slug>     e.g. s01-vanilla-http
#     --load     <pN-slug>      e.g. p1-baseline | p2-sustained | p3-ramp | p4-stress
#     [--output  <dir>]         defaults to reports/<RUN_ID>/raw/<gw>/<policy>__<load>__<scenario>
#     [--stream]                also stream per-request timing JSON (large)
#     [--keep-up]               skip the final `docker compose down`
#     [--seed    <int>]         BENCH_RUN_SEED, default 42
#     [--verbose|-v]            chatty k6 stdout
#
# Dependencies: bash, docker, docker compose, curl, jq, openssl
# (transitively via gen-jwt.sh).
#
# Pinned image: grafana/k6:1.7.1
#   multi-arch index digest:
#   sha256:4fd3a694926b064d3491d9b02b01cde886583c4931f1223816e3d9a7bdfa7e0f
# Refresh with: docker pull grafana/k6:1.7.1 && \
#   docker buildx imagetools inspect grafana/k6:1.7.1 --format "{{.Manifest.Digest}}"

set -euo pipefail
shopt -s nullglob

# -----------------------------------------------------------------------------
# Paths
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

# -----------------------------------------------------------------------------
# Pinned k6 image
# -----------------------------------------------------------------------------
K6_IMAGE="${K6_IMAGE:-grafana/k6:1.7.1@sha256:4fd3a694926b064d3491d9b02b01cde886583c4931f1223816e3d9a7bdfa7e0f}"

# -----------------------------------------------------------------------------
# Arg parsing
# -----------------------------------------------------------------------------
GATEWAY=""
POLICY=""
SCENARIO=""
LOAD=""
OUTPUT=""
STREAM=0
KEEP_UP=0
VERBOSE=0
SEED="${BENCH_RUN_SEED:-42}"

usage() {
    sed -n '2,55p' "${BASH_SOURCE[0]}" >&2
    exit 2
}

while (( $# > 0 )); do
    case "$1" in
        --gateway)    GATEWAY="$2";  shift 2;;
        --policy)     POLICY="$2";   shift 2;;
        --scenario)   SCENARIO="$2"; shift 2;;
        --load)       LOAD="$2";     shift 2;;
        --output)     OUTPUT="$2";   shift 2;;
        --stream)     STREAM=1;      shift;;
        --keep-up)    KEEP_UP=1;     shift;;
        --seed)       SEED="$2";     shift 2;;
        --verbose|-v) VERBOSE=1;     shift;;
        -h|--help)    usage;;
        *) printf 'unknown arg: %s\n' "$1" >&2; usage;;
    esac
done

[[ -n "${GATEWAY}"  ]] || { printf '%s\n' "--gateway is required"  >&2; exit 2; }
[[ -n "${POLICY}"   ]] || { printf '%s\n' "--policy is required"   >&2; exit 2; }
[[ -n "${SCENARIO}" ]] || { printf '%s\n' "--scenario is required" >&2; exit 2; }
[[ -n "${LOAD}"     ]] || { printf '%s\n' "--load is required"     >&2; exit 2; }

# Accepted load profiles — closed-loop (p1/p2/p3/p4-*) plus paced-
# arrivals twins (p1c/p2c/p3c/p4c-paced). The `-paced` suffix is the
# gate for the `constant-arrival-rate` executors; see
# docs/LOAD-PROFILES.md § Paced-arrivals variants. Any new profile
# MUST be added here AND in `k6/lib/options.js`'s profileMap AND in
# `scripts/load-orchestrator.sh`.
case "${LOAD}" in
    p1-baseline|p2-sustained|p3-ramp|p4-stress) ;;
    p1c-paced|p2c-paced|p3c-paced|p4c-paced) ;;
    *) printf 'unknown --load %s; valid: p1-baseline|p2-sustained|p3-ramp|p4-stress|p1c-paced|p2c-paced|p3c-paced|p4c-paced\n' "${LOAD}" >&2; exit 2;;
esac

scenario_file="k6/scenarios/${SCENARIO}.js"
[[ -f "${scenario_file}" ]] \
    || { printf 'scenario script not found: %s\n' "${scenario_file}" >&2; exit 2; }

compose_file="gateways/${GATEWAY}/docker-compose.yaml"
profile_dir="gateways/${GATEWAY}/${POLICY}"
setup_script="${profile_dir}/setup.sh"
feature_missing="${profile_dir}/FEATURE-MISSING"

[[ -d "${profile_dir}" ]] || { printf 'profile directory not found: %s\n' "${profile_dir}" >&2; exit 2; }

# -----------------------------------------------------------------------------
# Output layout
# -----------------------------------------------------------------------------
RUN_ID="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
if [[ -z "${OUTPUT}" ]]; then
    OUTPUT="reports/${RUN_ID}/raw/${GATEWAY}/${POLICY}__${LOAD}__${SCENARIO}"
fi
LOGS_DIR="${OUTPUT}/logs"
mkdir -p "${OUTPUT}" "${LOGS_DIR}"

GATEWAY_HTTP_PORT="${GATEWAY_HTTP_PORT:-9080}"
GATEWAY_HTTPS_PORT="${GATEWAY_HTTPS_PORT:-9443}"
GATEWAY_ADMIN_PORT="${GATEWAY_ADMIN_PORT:-9081}"
GATEWAY_ENVOY_ADMIN_PORT="${GATEWAY_ENVOY_ADMIN_PORT:-9901}"
BENCH_COMPOSE_PROJECT="${BENCH_COMPOSE_PROJECT:-gateway-benchmarks-${GATEWAY}}"
BENCH_CONTAINER_PREFIX="${BENCH_CONTAINER_PREFIX:-gwb-${GATEWAY}}"
GATEWAY_TARGET="${GATEWAY_TARGET:-http://localhost:${GATEWAY_HTTP_PORT}}"
export GATEWAY_HTTP_PORT GATEWAY_HTTPS_PORT GATEWAY_ADMIN_PORT GATEWAY_ENVOY_ADMIN_PORT
export BENCH_COMPOSE_PROJECT BENCH_CONTAINER_PREFIX
export DATA_URL="${DATA_URL:-${GATEWAY_TARGET}}"
export ADMIN_URL="${ADMIN_URL:-http://localhost:${GATEWAY_ADMIN_PORT}}"

# -----------------------------------------------------------------------------
# Colors
# -----------------------------------------------------------------------------
C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_C=$'\033[36m'; C_N=$'\033[0m'
say()  { printf '%s%s%s\n' "${C_C}" "$*" "${C_N}" >&2; }
warn() { printf '%s%s%s\n' "${C_Y}" "$*" "${C_N}" >&2; }
ok()   { printf '%s%s%s\n' "${C_G}" "$*" "${C_N}" >&2; }
bad()  { printf '%s%s%s\n' "${C_R}" "$*" "${C_N}" >&2; }

# -----------------------------------------------------------------------------
# FEATURE-MISSING short-circuit (mirrors parity-gateway.sh)
# -----------------------------------------------------------------------------
if [[ -f "${feature_missing}" ]]; then
    reason="$(head -n 1 "${feature_missing}" 2>/dev/null || true)"
    say "=> ${GATEWAY} / ${POLICY}: FEATURE-MISSING marker found"
    [[ -n "${reason}" ]] && warn "   reason: ${reason}"
    jq -cn \
        --arg gateway  "${GATEWAY}" \
        --arg policy   "${POLICY}" \
        --arg scenario "${SCENARIO}" \
        --arg load     "${LOAD}" \
        --arg run_id   "${RUN_ID}" \
        --arg reason   "${reason}" \
        '{
            gateway:  $gateway,
            policy:   $policy,
            scenario: $scenario,
            load:     $load,
            run_id:   $run_id,
            status:   "EXCLUDED",
            reason:   "FEATURE-MISSING",
            details:  $reason
        }' > "${OUTPUT}/excluded.json"
    warn "verdict: EXCLUDED (FEATURE-MISSING)  ${OUTPUT}/excluded.json"
    exit 0
fi

[[ -f "${compose_file}" ]] || { printf 'compose file not found: %s\n' "${compose_file}" >&2; exit 2; }
[[ -f "${setup_script}" ]] || { printf 'setup script not found: %s\n' "${setup_script}" >&2; exit 2; }

# -----------------------------------------------------------------------------
# Compose driver (handles per-profile .env override identically to
# parity-gateway.sh — keeps the two lifecycles 100% consistent).
# -----------------------------------------------------------------------------
profile_env="gateways/${GATEWAY}/${POLICY}/.env"
compose_cmd=(docker compose -p "${BENCH_COMPOSE_PROJECT}")
if [[ -f "${profile_env}" ]]; then
    compose_cmd+=(--env-file "${profile_env}")
fi
compose_cmd+=(-f "${compose_file}")

# bench-net is named after the compose project — `name:` at the top of
# every `gateways/<gw>/docker-compose.yaml` is `gateway-benchmarks-<gw>`.
# Combined with the network alias `bench-net`, the resulting Docker
# network is `gateway-benchmarks-<gw>_bench-net`. We resolve the
# project name dynamically to stay agnostic of any future rename.
project_name="$("${compose_cmd[@]}" config --format json 2>/dev/null \
    | jq -r '.name' 2>/dev/null || true)"
project_name="${project_name:-gateway-benchmarks-${GATEWAY}}"
bench_network="${project_name}_bench-net"

# -----------------------------------------------------------------------------
# Teardown trap
# -----------------------------------------------------------------------------
teardown() {
    local rc=$?
    set +e
    if (( KEEP_UP == 1 )); then
        warn "keep-up requested — stack left running (tear down with: ${compose_cmd[*]} down -v)"
    else
        say "=> capturing logs & stopping stack"
        "${compose_cmd[@]}" logs --no-color > "${LOGS_DIR}/compose.log" 2>&1 || true
        "${compose_cmd[@]}" down --remove-orphans -v >/dev/null 2>&1 || true
    fi
    return "${rc}"
}
trap teardown EXIT

# -----------------------------------------------------------------------------
# 1. Bring up the stack
# -----------------------------------------------------------------------------
say "=> bringing up stack (${GATEWAY} / ${POLICY})"
"${compose_cmd[@]}" down --remove-orphans -v >/dev/null 2>&1 || true

if [[ -f "${profile_env}" ]]; then
    say "=> per-profile env: ${profile_env}"
fi

GATEWAY_PROFILE="${POLICY}" "${compose_cmd[@]}" up -d

# -----------------------------------------------------------------------------
# 2. Wait for the data plane on the host port (parity precondition
#    needs to talk to it from the host; k6 will use the in-network
#    `gateway:9080` alias instead).
# -----------------------------------------------------------------------------
say "=> waiting for ${GATEWAY_TARGET}"
ready=0
for _ in $(seq 1 60); do
    if curl -sS -o /dev/null -w '%{http_code}\n' --max-time 2 "${GATEWAY_TARGET}/" \
           2>/dev/null | grep -qE '^[0-9]{3}$'; then
        ready=1
        ok "gateway data plane answering"
        break
    fi
    sleep 1
done
if (( ready == 0 )); then
    bad "gateway never came up at ${GATEWAY_TARGET}"
    exit 3
fi

# -----------------------------------------------------------------------------
# 3. Run the profile-specific setup
# -----------------------------------------------------------------------------
say "=> running setup ${setup_script}"
RUNTIME_FEATURE_MISSING_REASON_FILE="${LOGS_DIR}/setup-feature-missing.txt"
SETUP_FEATURE_MISSING_RC=42

setup_rc=0
FEATURE_MISSING_REASON_FILE="${RUNTIME_FEATURE_MISSING_REASON_FILE}" \
    bash "${setup_script}" || setup_rc=$?

if (( setup_rc == SETUP_FEATURE_MISSING_RC )); then
    reason="$(sed -n '1p' "${RUNTIME_FEATURE_MISSING_REASON_FILE}" 2>/dev/null || true)"
    say "=> ${GATEWAY} / ${POLICY}: setup reported FEATURE-MISSING"
    [[ -n "${reason}" ]] && warn "   reason: ${reason}"
    jq -cn \
        --arg gateway  "${GATEWAY}" \
        --arg policy   "${POLICY}" \
        --arg scenario "${SCENARIO}" \
        --arg load     "${LOAD}" \
        --arg run_id   "${RUN_ID}" \
        --arg reason   "${reason}" \
        '{
            gateway:  $gateway,
            policy:   $policy,
            scenario: $scenario,
            load:     $load,
            run_id:   $run_id,
            status:   "EXCLUDED",
            reason:   "FEATURE-MISSING",
            details:  $reason
        }' > "${OUTPUT}/excluded.json"
    warn "verdict: EXCLUDED (FEATURE-MISSING)  ${OUTPUT}/excluded.json"
    exit 0
elif (( setup_rc != 0 )); then
    bad "setup script failed (exit ${setup_rc})"
    exit "${setup_rc}"
fi

# -----------------------------------------------------------------------------
# 4. Parity precondition. The orchestrator (Phase 6) will eventually
#    let the operator override this with --skip-parity for fast
#    iteration; for now it's mandatory — running load against a cell
#    that doesn't pass parity would feed misleading numbers into the
#    ranking.
# -----------------------------------------------------------------------------
say "=> parity precondition"
parity_out="${OUTPUT}/parity.json"
parity_args=(
    --gateway "${GATEWAY}"
    --profile "${POLICY}"
    --target  "${GATEWAY_TARGET}"
    --output  "${parity_out}"
)
bash scripts/parity-attestation.sh "${parity_args[@]}" >/dev/null 2>&1 || true
parity_status="$(jq -r '.status' "${parity_out}" 2>/dev/null || echo UNKNOWN)"
case "${parity_status}" in
    PASS)
        ok "parity: PASS — proceeding to load"
        ;;
    *)
        bad "parity: ${parity_status} — load run skipped"
        jq -cn \
            --arg gateway  "${GATEWAY}" \
            --arg policy   "${POLICY}" \
            --arg scenario "${SCENARIO}" \
            --arg load     "${LOAD}" \
            --arg run_id   "${RUN_ID}" \
            --arg pstatus  "${parity_status}" \
            '{
                gateway:  $gateway,
                policy:   $policy,
                scenario: $scenario,
                load:     $load,
                run_id:   $run_id,
                status:   "EXCLUDED",
                reason:   "PARITY_NOT_PASS",
                details:  ("parity status was " + $pstatus)
            }' > "${OUTPUT}/excluded.json"
        exit 0
        ;;
esac

# -----------------------------------------------------------------------------
# 5. Mint JWT(s) on the host (k6 has no openssl). Scenarios that do
#    not need a token simply ignore BENCH_JWT_VALID /
#    BENCH_JWT_VALID_RS256; both env vars are always set (even if to
#    an empty string) so k6's `__ENV` reader yields a stable shape.
#
#    Scenario name → token mint:
#      *jwt* | *full-pipeline*  → HS256 via gen-jwt.sh        (p02, p12)
#      *jwks*                   → RS256 via gen-jwt-rs256.sh  (p03)
# -----------------------------------------------------------------------------
BENCH_JWT_VALID=""
BENCH_JWT_VALID_RS256=""
case "${SCENARIO}" in
    *jwks*)
        say "=> minting RS256 token via scripts/gen-jwt-rs256.sh"
        BENCH_JWT_VALID_RS256="$(bash scripts/gen-jwt-rs256.sh valid)"
        [[ -n "${BENCH_JWT_VALID_RS256}" ]] || { bad "gen-jwt-rs256.sh returned empty"; exit 4; }
        ;;
    *jwt*|*full-pipeline*)
        say "=> minting HS256 token via scripts/gen-jwt.sh"
        BENCH_JWT_VALID="$(bash scripts/gen-jwt.sh valid)"
        [[ -n "${BENCH_JWT_VALID}" ]] || { bad "gen-jwt.sh returned empty"; exit 4; }
        ;;
esac

# -----------------------------------------------------------------------------
# 6. Run k6 inside the gateway's bench-net so it can talk to
#    `gateway:9080` via the service alias. The output volume mount is
#    bind-mounted with explicit `:rw` and an absolute host path
#    because Docker Desktop on macOS occasionally treats relative
#    bind paths as anonymous volumes.
# -----------------------------------------------------------------------------
say "=> running k6 (${SCENARIO} / ${LOAD}) on ${bench_network}"
abs_output="$(cd "${OUTPUT}" && pwd)"
abs_k6="$(cd "${REPO_ROOT}/k6" && pwd)"

k6_log="${LOGS_DIR}/k6.log"
k6_summary="${OUTPUT}/k6-summary.json"
k6_stream="${OUTPUT}/k6-stream.json.gz"

# k6 args — `--quiet` keeps stdout small in the runner; the per-second
# progress bars only matter for an interactive operator, and the
# orchestrator (Phase 6) will not tail them.
k6_args=(
    run
    "/k6/scenarios/${SCENARIO}.js"
    --summary-export "/out/k6-summary.json"
)
if (( STREAM == 1 )); then
    k6_args+=(--out "json=/out/k6-stream.json")
fi
if (( VERBOSE == 0 )); then
    k6_args+=(--quiet)
fi

# Pull the k6 image up front so the run timer doesn't include the
# image fetch on first invocation. `docker pull` is idempotent and
# fast once the digest is local.
docker pull "${K6_IMAGE}" >/dev/null 2>&1 || true

# -----------------------------------------------------------------------------
# docker-stats sidecar — per-second CPU / RSS / net-io / blkio CSV of the
# gateway container, started RIGHT BEFORE k6 so the baseline idle RSS
# is captured on row 1 and the "steady-state + peak" pair comes out
# cleanly in the post-run CSV aggregator.
#
# The container name follows the `gwb-<gateway>` convention enforced
# by every gateways/<gw>/docker-compose.yaml (the `gateway:` service
# block sets `container_name: gwb-<gw>`). Non-gateway service containers
# in the same compose (e.g. gwb-<gw>-oidc-server, gwb-<gw>-redis) are
# deliberately NOT sampled — only the data-plane process matters for
# the policy-overhead number.
# -----------------------------------------------------------------------------
STATS_CSV="${OUTPUT}/docker-stats.csv"
GATEWAY_CONTAINER="${BENCH_CONTAINER_PREFIX}"
SIDECAR_PID=""
# `bench run` (the Go orchestrator) owns its own native Go
# docker-stats collector (internal/stats) and suppresses this shell
# sidecar via BENCH_SKIP_DOCKER_STATS=1 so there's only ever one
# sampler writing docker-stats.csv. Pure-shell operators (running
# load-gateway.sh directly) fall through to the shell sidecar as
# before — BENCH_SKIP_DOCKER_STATS unset == legacy behaviour.
if [[ "${BENCH_SKIP_DOCKER_STATS:-0}" != "1" ]] && [[ -x scripts/docker-stats-sidecar.sh ]]; then
    bash scripts/docker-stats-sidecar.sh \
        --container "${GATEWAY_CONTAINER}" \
        --output    "${STATS_CSV}" \
        --interval  1 \
        >/dev/null 2>&1 &
    SIDECAR_PID=$!
    # Give it a moment to ping the engine, resolve the container id,
    # and write the CSV header. If it died early (container not found),
    # the kill below is a no-op and k6 still runs cleanly.
    sleep 1
    if ! kill -0 "${SIDECAR_PID}" 2>/dev/null; then
        warn "docker-stats sidecar failed to stay up (container ${GATEWAY_CONTAINER} not reachable?); continuing without sampling"
        SIDECAR_PID=""
    fi
fi

# Run the k6 container as the calling host UID/GID so files written
# into the bind-mounted /out (k6-summary.json, k6-stream.json) end up
# owned by the operator instead of by the in-image `k6` user (uid
# 12345). Without this, on Linux hosts the summary write fails with
# "permission denied" because the host directory is owned by ubuntu
# (uid 1000) and only group-writable. macOS Docker Desktop hides the
# uid mismatch via its filesystem shim, so this only manifests on
# Linux runners (verified empirically on EC2 c6i.2xlarge / Ubuntu
# 24.04 during the v0.1.0 canonical bring-up).
HOST_UID="$(id -u)"
HOST_GID="$(id -g)"

docker_run_args=(
    --rm
    --network "${bench_network}"
    --user "${HOST_UID}:${HOST_GID}"
    -v "${abs_k6}:/k6:ro"
    -v "${abs_output}:/out"
    -e "BENCH_TARGET_URL=http://gateway:9080"
    -e "BENCH_TARGET_URL_HTTPS=${BENCH_TARGET_URL_HTTPS:-https://gateway:9443}"
    -e "BENCH_LOAD_PROFILE=${LOAD}"
    -e "BENCH_POLICY_PROFILE=${POLICY}"
    -e "BENCH_SCENARIO=${SCENARIO}"
    -e "BENCH_GATEWAY=${GATEWAY}"
    -e "BENCH_RUN_ID=${RUN_ID}"
    -e "BENCH_RUN_SEED=${SEED}"
    -e "BENCH_JWT_VALID=${BENCH_JWT_VALID}"
    -e "BENCH_JWT_VALID_RS256=${BENCH_JWT_VALID_RS256}"
    -e "BENCH_STREAM_METRICS=${STREAM}"
)

k6_rc=0
docker run "${docker_run_args[@]}" "${K6_IMAGE}" "${k6_args[@]}" \
    > "${k6_log}" 2>&1 || k6_rc=$?

# Stop the stats sidecar now that k6 has finished. SIGTERM makes the
# loop break cleanly; `wait` reaps so the shell doesn't leave a zombie.
if [[ -n "${SIDECAR_PID}" ]]; then
    kill -TERM "${SIDECAR_PID}" 2>/dev/null || true
    wait "${SIDECAR_PID}" 2>/dev/null || true
fi

if (( STREAM == 1 )) && [[ -f "${OUTPUT}/k6-stream.json" ]]; then
    gzip -f "${OUTPUT}/k6-stream.json"
fi

# -----------------------------------------------------------------------------
# Gateway crash detection — writes gateway-crash.json if the gateway
# container has exited mid-run (non-zero exit, or OOM-killed). The
# `bench run` orchestrator turns that sentinel into a CRASHED verdict
# (distinct from FAIL) so downstream scoring can penalise crashes and
# optionally retry the cell. This block is guarded by
# BENCH_CHECK_GATEWAY_CRASH so direct shell invocations keep their
# historical "exit non-zero on failure" contract.
#
# The check runs BEFORE the EXIT trap's teardown so the container is
# still inspectable — once `docker compose down` runs, the container
# is gone and we can't ask Docker what its exit state was.
# -----------------------------------------------------------------------------
CRASH_JSON="${OUTPUT}/gateway-crash.json"
if [[ "${BENCH_CHECK_GATEWAY_CRASH:-0}" == "1" ]]; then
    # `docker inspect` returns non-zero when the container is missing;
    # tolerate that by falling back to a synthetic "missing" row.
    inspect_out="$(docker inspect "${GATEWAY_CONTAINER}" \
        --format '{{.State.Status}}|{{.State.ExitCode}}|{{.State.OOMKilled}}|{{.State.FinishedAt}}' \
        2>/dev/null || echo 'missing|-1|false|')"
    IFS='|' read -r cstatus cexit coom cfinished <<<"${inspect_out}"
    case "${cstatus}" in
        exited|dead|missing)
            # exit_code=0 with status=exited is a clean shutdown of a
            # process that runs-then-exits (none of our gateways do
            # that) — we still flag it CRASHED because the gateway is
            # expected to be alive for the full cell.
            jq -cn \
                --arg  container   "${GATEWAY_CONTAINER}" \
                --arg  status      "${cstatus}" \
                --argjson exit_code "${cexit:-0}" \
                --argjson oom      "${coom:-false}" \
                --arg  finished_at "${cfinished}" \
                --arg  gateway     "${GATEWAY}" \
                --arg  policy      "${POLICY}" \
                --arg  scenario    "${SCENARIO}" \
                --arg  load        "${LOAD}" \
                --arg  run_id      "${RUN_ID}" \
                '{
                    gateway:     $gateway,
                    policy:      $policy,
                    scenario:    $scenario,
                    load:        $load,
                    run_id:      $run_id,
                    container:   $container,
                    status:      $status,
                    exit_code:   $exit_code,
                    oom_killed:  $oom,
                    finished_at: $finished_at
                }' > "${CRASH_JSON}"
            bad "gateway ${GATEWAY_CONTAINER}: status=${cstatus} exit=${cexit} oom=${coom}"
            # Rewrite k6_rc so the Verdict section below falls into the
            # error exit path even when k6 itself got 0 — the cell is
            # not PASS regardless.
            if (( k6_rc == 0 )); then
                k6_rc=6
            fi
            ;;
    esac
fi

# -----------------------------------------------------------------------------
# 7. Verdict
# -----------------------------------------------------------------------------
if (( k6_rc != 0 )); then
    bad "k6 exited non-zero (${k6_rc}); see ${k6_log}"
    exit "${k6_rc}"
fi

if [[ ! -s "${k6_summary}" ]]; then
    bad "k6 summary not written: ${k6_summary}"
    exit 5
fi

# Quick sanity readout — three numbers the operator usually wants to
# see immediately, the rest is in the JSON.
http_reqs="$(jq -r '.metrics.http_reqs.count // 0' "${k6_summary}" 2>/dev/null)"
p95_ms="$(jq -r '.metrics.http_req_duration["p(95)"] // 0' "${k6_summary}" 2>/dev/null)"
fail_rate="$(jq -r '.metrics.http_req_failed.value // 0' "${k6_summary}" 2>/dev/null)"

ok "verdict: PASS"
ok "  reqs:      ${http_reqs}"
ok "  p95 (ms):  ${p95_ms}"
ok "  failed:    ${fail_rate}"
ok "  summary:   ${k6_summary}"
ok "  log:       ${k6_log}"
[[ -f "${k6_stream}" ]] && ok "  stream:    ${k6_stream}"
[[ -s "${parity_out}" ]] && ok "  parity:    ${parity_out}"
if [[ -s "${STATS_CSV}" ]]; then
    stats_rows="$(($(wc -l < "${STATS_CSV}") - 1))"
    ok "  stats:     ${STATS_CSV} (${stats_rows} samples)"
fi

# -----------------------------------------------------------------------------
# 8. HTML report (best-effort, opt-out via BENCH_LOCAL_REPORT=0)
# -----------------------------------------------------------------------------
# Aggregate + render the same Go-pipeline HTML the AWS sweep produces,
# but for the single cell the operator just ran. Cheap (~1 second on a
# single cell) and uses the artefacts already on disk — no extra
# benchmark work. Skip silently if the orchestrator binary isn't built:
# the script's primary job (load + raw artefacts) has already
# succeeded, and a missing binary should not flunk the whole verdict.
if [[ "${BENCH_LOCAL_REPORT:-1}" == "1" ]]; then
    bench_bin="${REPO_ROOT}/orchestrator/bin/bench"
    if [[ ! -x "${bench_bin}" ]]; then
        printf '  (HTML report skipped: %s not built — `cd orchestrator && go build -o bin/bench .`)\n' "${bench_bin}" >&2
    elif "${bench_bin}" --repo-root "${REPO_ROOT}" aggregate --run-id "${RUN_ID}" -q >/dev/null 2>&1 \
        && "${bench_bin}" --repo-root "${REPO_ROOT}" report --run-id "${RUN_ID}" >/dev/null 2>&1; then
        ok "  report:    reports/${RUN_ID}/report.html"
    else
        printf '  (HTML report failed — re-run \`bench aggregate / report --run-id %s\` to see the error)\n' "${RUN_ID}" >&2
    fi
fi

exit 0
