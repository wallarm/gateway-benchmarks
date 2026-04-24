#!/usr/bin/env bash
# shellcheck shell=bash
#
# Preflight check run before any Makefile target that boots a bench
# compose stack (perf-local-up, perf-local-run, parity-gateway*,
# load-gateway*, load-sweep).
#
# Both the long-running smoke stack (compose project
# `gateway-benchmarks-local` → container `gwb-local-gateway`) and the
# per-cell stacks (`gateway-benchmarks-<gw>` → `gwb-<gw>`) publish host
# ports :9080 and :9443. Running more than one at a time yields a
# cryptic `Bind for 0.0.0.0:9080 failed: port is already allocated` on
# the second stack. Instead of letting the operator debug that on their
# own, this script inspects the live Docker state, tells them exactly
# which stack is already up, and prints the single command that clears
# it. It is wired into the Makefile as a hidden prerequisite
# (.bench-ports-free) — there is no operator-visible target.
#
# Can be disabled per-invocation by exporting BENCH_SKIP_PORTS_CHECK=1
# (used by CI paths that know the host is clean).
#
# Exit codes:
#   0 — host is clean, safe to boot a bench stack
#   1 — a bench stack is already live (see stderr for which one)
#   2 — unexpected error (docker daemon unavailable, etc.)
#
set -euo pipefail

RED=$'\033[0;31m'
YELLOW=$'\033[1;33m'
GREEN=$'\033[0;32m'
CYAN=$'\033[0;36m'
NC=$'\033[0m'

if [[ "${BENCH_SKIP_PORTS_CHECK:-0}" == "1" ]]; then
    exit 0
fi

if ! command -v docker >/dev/null 2>&1; then
    printf "%s✗ docker not found — run 'make prereqs-check' first%s\n" \
        "$RED" "$NC" >&2
    exit 2
fi

if ! docker info >/dev/null 2>&1; then
    printf '%s✗ docker daemon is not reachable%s\n' "$RED" "$NC" >&2
    exit 2
fi

# All bench containers are named with the `gwb-` prefix (see
# `container_name:` in every compose file under gateways/ and
# infra/local/). Anything else on the host is not our concern.
stale=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -E '^gwb-' || true)

if [[ -z "$stale" ]]; then
    exit 0
fi

printf '\n%s✗ A bench stack is already running on host ports :9080 / :9443:%s\n\n' \
    "$RED" "$NC" >&2

while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    if [[ "$name" == gwb-local-* ]]; then
        printf '    %s%-30s%s  long-running smoke stack   (infra/local/docker-compose.yaml)\n' \
            "$YELLOW" "$name" "$NC" >&2
    else
        gw="${name#gwb-}"
        gw="${gw%%-*}"
        printf '    %s%-30s%s  orphan per-cell stack      (gateways/%s/docker-compose.yaml)\n' \
            "$YELLOW" "$name" "$NC" "$gw" >&2
    fi
done <<< "$stale"

# `perf-local-down` tears down BOTH the smoke stack and any orphan
# per-cell stacks (it calls scripts/bench-down-orphans.sh internally),
# so a single command always clears the host regardless of which kind
# of stack is up. Don't print compose-level commands here — operators
# should always reach for the make target.
printf '\n%sFree the host first, then retry the make target:%s\n' \
    "$CYAN" "$NC" >&2
printf '    %smake perf-local-down%s\n\n' "$GREEN" "$NC" >&2

exit 1
