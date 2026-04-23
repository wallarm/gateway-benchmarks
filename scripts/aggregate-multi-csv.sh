#!/usr/bin/env bash
# shellcheck shell=bash
#
# Phase 4 — cross-run aggregator. Takes N run-ids, produces one wide
# CSV/TSV/MD table that spans every cell across every run. Same column
# schema as `scripts/aggregate-csv.sh`; the only difference is that
# this script calls the single-run aggregator under the hood for each
# run-id and then concatenates the outputs with a single header row.
#
# Typical use: at the end of a Path-A sweep where you've run nginx on
# p1-baseline, nginx on p2-sustained, wallarm on p1-baseline, etc.,
# each of which produced its own reports/<run-id>/matrix.csv. This
# script rolls them into one combined CSV so the per-gateway /
# per-load / per-policy ranking can be read off in a single sheet.
#
# Why a separate script instead of a `--combine` flag on
# aggregate-csv.sh: keeping the single-run semantics simple means
# each per-run CSV stays a valid, self-contained artefact. This
# script is a pure concatenator on top — no jq / no k6-summary
# rewalking, so it can run in seconds even across a full 28-run
# matrix sweep.
#
# Usage:
#   scripts/aggregate-multi-csv.sh \
#     --run-ids  id1,id2,id3               (required, comma-separated)
#     [--output   <path>]                  default reports/combined-<ts>/matrix.<fmt>
#     [--format   csv|tsv|md]              default csv
#     [--regenerate]                       re-run the single-run aggregator
#                                          for each id before combining
#                                          (default: reuse existing
#                                          reports/<id>/matrix.<fmt> if present)
#
# Notes:
#   - Each run-id must have an existing `reports/<run-id>/` directory
#     (a completed sweep). Runs that only got partway through with
#     a half-populated raw/ tree will still aggregate — k6's summary
#     JSON is the source of truth, not matrix.tsv.
#   - Column schema matches aggregate-csv.sh exactly. The `run_id`
#     column in each row tells the report reader which sweep the
#     cell belongs to.
#   - No de-duplication on (gateway, policy, scenario, load) across
#     runs. If the same cell was run twice (e.g. during debugging),
#     it appears twice in the output — distinguished by run_id.
#     The report generator (Phase 7) will choose one row per cell
#     by timestamp; this script stays dumb.
#
# Exit codes:
#   0   combined output written
#   2   argument error
#   3   missing run directory
#   4   underlying aggregate-csv.sh failed

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

RUN_IDS_CSV=""
OUTPUT=""
FORMAT="csv"
REGENERATE=0

while (( $# > 0 )); do
    case "$1" in
        --run-ids)    RUN_IDS_CSV="$2"; shift 2;;
        --output)     OUTPUT="$2"; shift 2;;
        --format)     FORMAT="$2"; shift 2;;
        --regenerate) REGENERATE=1; shift;;
        -h|--help)    sed -n '2,55p' "${BASH_SOURCE[0]}"; exit 0;;
        *)            printf 'unknown arg: %s\n' "$1" >&2; exit 2;;
    esac
done

[[ -n "${RUN_IDS_CSV}" ]] || {
    printf '%s\n' "--run-ids is required (comma-separated, e.g. run1,run2)" >&2
    exit 2
}

case "${FORMAT}" in
    csv|tsv|md) ;;
    *) printf 'unknown --format: %s (csv|tsv|md)\n' "${FORMAT}" >&2; exit 2;;
esac

# Portable CSV split — mirrors the helper in load-orchestrator.sh.
# `eval "arr=(${csv})"` with IFS=',' does NOT split the way you'd
# expect because eval re-tokenises after expansion. Using a for-loop
# with IFS=',' on the unquoted expansion does.
split_csv_into_array() {
    local __name="$1"
    local __csv="$2"
    local __tok
    eval "${__name}=()"
    local IFS=','
    for __tok in ${__csv}; do
        __tok="${__tok#"${__tok%%[![:space:]]*}"}"
        __tok="${__tok%"${__tok##*[![:space:]]}"}"
        eval "${__name}+=(\"\${__tok}\")"
    done
}

split_csv_into_array RUN_IDS "${RUN_IDS_CSV}"

# Default output path (new combined-<ts> directory) if the operator
# did not override it. This keeps combined reports out of any single
# run's tree so re-running the same sweep does not nuke the combined
# artefact.
if [[ -z "${OUTPUT}" ]]; then
    ts="$(date -u +%Y%m%dT%H%M%SZ)"
    case "${FORMAT}" in
        csv) OUTPUT="reports/combined-${ts}/matrix.csv";;
        tsv) OUTPUT="reports/combined-${ts}/matrix.wide.tsv";;
        md)  OUTPUT="reports/combined-${ts}/matrix.md";;
    esac
fi

mkdir -p "$(dirname "${OUTPUT}")"

# Figure out the per-run artefact filename the single-run aggregator
# emits by default — mirrors the switch inside aggregate-csv.sh so
# --regenerate and the reuse path agree on where to look.
per_run_filename_for_format() {
    case "${FORMAT}" in
        csv) printf '%s\n' "matrix.csv";;
        tsv) printf '%s\n' "matrix.wide.tsv";;
        md)  printf '%s\n' "matrix.md";;
    esac
}
per_run_name="$(per_run_filename_for_format)"

# Step 1: make sure every run has a per-run CSV/TSV/MD. If --regenerate
# is set, always re-run the single-run aggregator; otherwise reuse
# existing artefacts when they are newer than any k6-summary.json in
# the raw/ tree (cheap heuristic — matches how aggregate-csv.sh
# actually consumes raw/).
declare -a per_run_paths=()
for id in "${RUN_IDS[@]}"; do
    [[ -d "reports/${id}" ]] || {
        printf 'missing run directory: reports/%s\n' "${id}" >&2
        exit 3
    }
    per_run_path="reports/${id}/${per_run_name}"
    if [[ "${REGENERATE}" -eq 1 || ! -f "${per_run_path}" ]]; then
        printf '=> regenerating reports/%s/%s\n' "${id}" "${per_run_name}"
        if ! bash scripts/aggregate-csv.sh --run-id "${id}" --format "${FORMAT}"; then
            printf 'aggregate-csv.sh failed for run-id %s\n' "${id}" >&2
            exit 4
        fi
    fi
    per_run_paths+=("${per_run_path}")
done

# Step 2: combine. The header from the first file is kept; headers
# from the rest are dropped. For CSV/TSV that is literally "skip the
# first line of every file except the first". For MD we also skip the
# separator row (line 2) of every file except the first.
case "${FORMAT}" in
    csv|tsv)
        head -n 1 "${per_run_paths[0]}" > "${OUTPUT}"
        for p in "${per_run_paths[@]}"; do
            tail -n +2 "${p}" >> "${OUTPUT}"
        done
        ;;
    md)
        head -n 2 "${per_run_paths[0]}" > "${OUTPUT}"
        for p in "${per_run_paths[@]}"; do
            tail -n +3 "${p}" >> "${OUTPUT}"
        done
        ;;
esac

row_count=$(( $(wc -l < "${OUTPUT}" | tr -d ' ') - 1 ))
[[ "${FORMAT}" == "md" ]] && row_count=$(( row_count - 1 ))

printf 'wrote: %s  (%d runs, %d cells, %s format)\n' \
    "${OUTPUT}" "${#RUN_IDS[@]}" "${row_count}" "${FORMAT}"
exit 0
