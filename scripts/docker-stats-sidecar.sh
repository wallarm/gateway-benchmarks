#!/usr/bin/env bash
# shellcheck shell=bash
#
# Phase 4 — docker-stats sidecar. Samples the gateway container's
# CPU / RSS / net-io / block-io every `INTERVAL` seconds while a k6
# load run is in flight, and appends each sample as one CSV row to
# the output file.
#
# This closes the gap called out in `k6/README.md` § "Known gaps":
#
#   > TASK §8 wants RSS peak + steady-state per cell. The runner
#   > captures a `compose.log` on teardown but doesn't sample
#   > memory/cpu. Phase 6 (orchestrator) adds the per-second
#   > `docker stats` sidecar.
#
# Lifecycle:
#
#   1. `scripts/load-gateway.sh` starts this in the background RIGHT
#      BEFORE `docker run grafana/k6` and captures its pid.
#   2. This script polls the Docker Engine REST API on the unix
#      socket (bypassing `docker stats`, which emits human-formatted
#      strings instead of raw bytes) and writes one CSV row per
#      `INTERVAL`.
#   3. The parent sends SIGTERM when k6 exits; the trap makes the
#      loop exit cleanly, the CSV is flushed, and the sidecar is
#      reaped by the parent via `wait`.
#
# Why the REST API and not `docker stats`:
#
#   `docker stats --format ...` outputs human-unit strings ("12.5MiB",
#   "0B / 0B") that require unit parsing and lose precision on fast
#   growth. The engine API's /containers/<id>/stats?stream=false
#   emits the same underlying counters as raw integers (nanoseconds
#   for CPU, bytes for memory/io) — lossless and self-describing.
#
# Usage:
#   scripts/docker-stats-sidecar.sh \
#       --container <name>                    e.g. gwb-nginx
#       --output    <path>                    e.g. reports/<run>/docker-stats.csv
#       [--interval <seconds>]                default 1
#       [--socket <path>]                     default auto-discover
#
# Dependencies: bash, curl, jq.
#
# Exit codes:
#   0   normal shutdown (SIGTERM received or loop exited cleanly)
#   2   argument error
#   3   socket / container not reachable at startup
#
# CSV schema (header is written on first start):
#
#   ts_utc, cpu_ns_total, cpu_ns_system, cpu_online, mem_bytes,
#   mem_limit, net_rx_bytes, net_tx_bytes, blkio_read_bytes,
#   blkio_write_bytes
#
# All cumulative (monotonic per-container) — the CSV aggregator
# computes deltas and peaks.

set -eo pipefail

# -----------------------------------------------------------------------------
# Args
# -----------------------------------------------------------------------------
CONTAINER=""
OUTPUT=""
INTERVAL=1
SOCKET=""

while (( $# > 0 )); do
    case "$1" in
        --container) CONTAINER="$2"; shift 2;;
        --output)    OUTPUT="$2";    shift 2;;
        --interval)  INTERVAL="$2";  shift 2;;
        --socket)    SOCKET="$2";    shift 2;;
        -h|--help)   sed -n '2,40p' "${BASH_SOURCE[0]}"; exit 0;;
        *) printf 'unknown arg: %s\n' "$1" >&2; exit 2;;
    esac
done

[[ -n "${CONTAINER}" ]] || { printf '%s\n' "--container is required" >&2; exit 2; }
[[ -n "${OUTPUT}"    ]] || { printf '%s\n' "--output is required"    >&2; exit 2; }

# -----------------------------------------------------------------------------
# Socket discovery — Docker Desktop on macOS ships at ~/.docker/run/
# while Linux distros ship at /var/run/. The parent can override with
# --socket or DOCKER_HOST_SOCK, otherwise we probe in order.
# -----------------------------------------------------------------------------
if [[ -z "${SOCKET}" ]]; then
    if [[ -n "${DOCKER_HOST_SOCK:-}" ]]; then
        SOCKET="${DOCKER_HOST_SOCK}"
    elif [[ -S "${HOME}/.docker/run/docker.sock" ]]; then
        SOCKET="${HOME}/.docker/run/docker.sock"
    elif [[ -S "/var/run/docker.sock" ]]; then
        SOCKET="/var/run/docker.sock"
    else
        printf '%s\n' "no docker socket found (tried \$DOCKER_HOST_SOCK, ~/.docker/run/docker.sock, /var/run/docker.sock)" >&2
        exit 3
    fi
fi

# -----------------------------------------------------------------------------
# Startup check — ping the engine, resolve the container name -> id.
# -----------------------------------------------------------------------------
if ! curl -sS --max-time 3 --unix-socket "${SOCKET}" http://localhost/_ping >/dev/null 2>&1; then
    printf 'docker engine did not respond on %s\n' "${SOCKET}" >&2
    exit 3
fi

CONTAINER_ID="$(curl -sS --max-time 3 --unix-socket "${SOCKET}" \
    "http://localhost/containers/${CONTAINER}/json" 2>/dev/null \
    | jq -r '.Id // empty' 2>/dev/null || true)"

if [[ -z "${CONTAINER_ID}" ]]; then
    printf 'container %s not found (is the stack up?)\n' "${CONTAINER}" >&2
    exit 3
fi

# -----------------------------------------------------------------------------
# CSV bootstrap
# -----------------------------------------------------------------------------
mkdir -p "$(dirname "${OUTPUT}")"
if [[ ! -s "${OUTPUT}" ]]; then
    printf '%s\n' 'ts_utc,cpu_ns_total,cpu_ns_system,cpu_online,mem_bytes,mem_limit,net_rx_bytes,net_tx_bytes,blkio_read_bytes,blkio_write_bytes' > "${OUTPUT}"
fi

# -----------------------------------------------------------------------------
# Signal handling — parent sends SIGTERM; exit cleanly.
# -----------------------------------------------------------------------------
SHUTDOWN=0
trap 'SHUTDOWN=1' TERM INT

# -----------------------------------------------------------------------------
# Sampling loop. One /stats?stream=false per INTERVAL; tolerate
# transient 404 (container restart) / empty-body errors by emitting
# a row of zeros rather than dying — the aggregator treats zero-row
# runs as "container not running this second".
# -----------------------------------------------------------------------------
while (( SHUTDOWN == 0 )); do
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    raw="$(curl -sS --max-time 2 --unix-socket "${SOCKET}" \
        "http://localhost/containers/${CONTAINER_ID}/stats?stream=false" 2>/dev/null || true)"

    if [[ -n "${raw}" ]]; then
        row="$(printf '%s' "${raw}" | jq -r --arg ts "${ts}" '
            [
                $ts,
                (.cpu_stats.cpu_usage.total_usage // 0),
                (.cpu_stats.system_cpu_usage // 0),
                (.cpu_stats.online_cpus // 0),
                (.memory_stats.usage // 0),
                (.memory_stats.limit // 0),
                ((.networks // {}) | to_entries | map(.value.rx_bytes // 0) | add // 0),
                ((.networks // {}) | to_entries | map(.value.tx_bytes // 0) | add // 0),
                (((.blkio_stats.io_service_bytes_recursive // []) | map(select((.op // "") | ascii_downcase == "read")) | map(.value // 0) | add) // 0),
                (((.blkio_stats.io_service_bytes_recursive // []) | map(select((.op // "") | ascii_downcase == "write")) | map(.value // 0) | add) // 0)
            ] | @csv' 2>/dev/null || true)"

        if [[ -n "${row}" ]]; then
            printf '%s\n' "${row}" >> "${OUTPUT}"
        fi
    fi

    # sleep is interruptible by SIGTERM because `wait` in bash can
    # interrupt it; use a short inner sleep so shutdown feels snappy
    # on sub-second shutdowns.
    remain="${INTERVAL}"
    while (( SHUTDOWN == 0 )) && [[ "${remain}" != "0" ]]; do
        sleep 1
        remain=$(( remain - 1 ))
    done
done

exit 0
