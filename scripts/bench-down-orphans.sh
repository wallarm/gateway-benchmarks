#!/usr/bin/env bash
# shellcheck shell=bash
#
# Tear down stale per-cell bench compose stacks (`gwb-<gw>*`) that may
# have been left behind by a hard-killed orchestrator run.
#
# Walks every `gateways/<gw>/docker-compose.yaml` in the repo, checks
# whether any `gwb-<gw>` or `gwb-<gw>-*` container is currently live,
# and if yes — runs `docker compose down --remove-orphans -v` against
# the matching compose file. This guarantees the matching networks and
# volumes are wiped together with the containers (a plain `docker rm
# -f` would orphan them).
#
# Smoke-stack containers (`gwb-local-*`) are intentionally ignored —
# they belong to `infra/local/docker-compose.yaml` and are torn down
# by `make perf-local-down` itself *before* this helper runs.
#
# Idempotent: prints nothing and exits 0 when there is nothing to clean.
# That makes it safe to wire into `make perf-local-down` as the second
# step regardless of whether the smoke stack was up or not.
#
set -euo pipefail

GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
NC=$'\033[0m'

if ! command -v docker >/dev/null 2>&1; then
    exit 0
fi

if ! docker info >/dev/null 2>&1; then
    exit 0
fi

stale=$(docker ps --format '{{.Names}}' 2>/dev/null \
    | grep -E '^gwb-' \
    | grep -vE '^gwb-local-' \
    || true)

if [[ -z "$stale" ]]; then
    exit 0
fi

cleaned_any=0
for compose_file in gateways/*/docker-compose.yaml; do
    [[ -f "$compose_file" ]] || continue
    gw="$(basename "$(dirname "$compose_file")")"

    # Match `gwb-<gw>` exactly OR `gwb-<gw>-<suffix>` (e.g.
    # `gwb-nginx-backend`, `gwb-tyk-redis`). Not `gwb-<gw>foo` —
    # that would be a different gateway.
    if echo "$stale" | grep -qE "^gwb-${gw}(\$|-)"; then
        printf '%sperf-local-down: removing orphan per-cell stack gwb-%s* (%s)%s\n' \
            "$YELLOW" "$gw" "$compose_file" "$NC"
        docker compose -f "$compose_file" down --remove-orphans -v >/dev/null
        cleaned_any=1
    fi
done

# Compose-down only catches containers with the right compose labels.
# A really wild orphan (e.g. one launched manually with `docker run
# --name gwb-foo`, or a half-migrated container from an aborted rename)
# would survive the loop above. Force-remove anything left behind so
# `perf-local-down` makes a hard guarantee about the host being clean.
remaining=$(docker ps --format '{{.Names}}' 2>/dev/null \
    | grep -E '^gwb-' \
    | grep -vE '^gwb-local-' \
    || true)

if [[ -n "$remaining" ]]; then
    printf '%sperf-local-down: force-removing unmanaged gwb-* containers:%s\n' \
        "$YELLOW" "$NC"
    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        printf '    %s%s%s\n' "$YELLOW" "$name" "$NC"
        docker rm -f "$name" >/dev/null 2>&1 || true
    done <<< "$remaining"
    cleaned_any=1
fi

if [[ $cleaned_any -eq 1 ]]; then
    printf '%s✓ orphan per-cell stacks removed%s\n' "$GREEN" "$NC"
fi
