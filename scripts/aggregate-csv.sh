#!/usr/bin/env bash
# shellcheck shell=bash
#
# Phase 4 — CSV aggregator. Walks reports/<RUN_ID>/raw/**/k6-summary.json
# and emits one wide CSV row per cell. The columns mirror what
# docs/REPORT.md § 5 calls out:
#
#   - identity:  gateway, policy, scenario, load, run_id
#   - verdict:   PASS / EXCLUDED
#   - traffic:   http_reqs, iteration_duration_avg, req_rate
#   - latency:   p50 / p90 / p95 / p99 / max (ms)
#   - policy 4-bucket: policy_2xx / policy_4xx_expected /
#                       policy_4xx_unexpected / policy_5xx_unexpected
#   - client-side errors: http_req_failed count
#   - docker stats (when the sidecar CSV is present):
#       mem_rss_peak_bytes, mem_rss_steady_bytes, cpu_pct_peak,
#       cpu_pct_steady
#
# Phase 6's Go orchestrator will subsume this with a proper report
# generator; for "Путь A" this shell version is enough to produce
# a human-readable CSV and a rough-cut Markdown table.
#
# Usage:
#   scripts/aggregate-csv.sh \
#     --run-id  <id>                       (required) e.g. 20260416T102030Z
#     [--output  <path>]                   default reports/<RUN_ID>/matrix.csv
#     [--format  csv|tsv|md]               default csv
#
# Exit codes:
#   0   aggregation completed
#   2   argument error
#   3   no per-cell summaries found

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

RUN_ID=""
OUTPUT=""
FORMAT="csv"

while (( $# > 0 )); do
    case "$1" in
        --run-id) RUN_ID="$2"; shift 2;;
        --output) OUTPUT="$2"; shift 2;;
        --format) FORMAT="$2"; shift 2;;
        -h|--help) sed -n '2,35p' "${BASH_SOURCE[0]}"; exit 0;;
        *) printf 'unknown arg: %s\n' "$1" >&2; exit 2;;
    esac
done

[[ -n "${RUN_ID}" ]] || { printf '%s\n' "--run-id is required" >&2; exit 2; }

case "${FORMAT}" in
    csv|tsv|md) ;;
    *) printf 'unknown --format: %s (csv|tsv|md)\n' "${FORMAT}" >&2; exit 2;;
esac

RUN_DIR="reports/${RUN_ID}"
[[ -d "${RUN_DIR}" ]] || { printf 'no such run directory: %s\n' "${RUN_DIR}" >&2; exit 3; }

if [[ -z "${OUTPUT}" ]]; then
    case "${FORMAT}" in
        csv) OUTPUT="${RUN_DIR}/matrix.csv";;
        tsv) OUTPUT="${RUN_DIR}/matrix.wide.tsv";;
        md)  OUTPUT="${RUN_DIR}/matrix.md";;
    esac
fi

# -----------------------------------------------------------------------------
# Per-cell projection — produce one JSON object per cell with all
# columns resolved. Downstream formatters convert to csv/tsv/md.
# -----------------------------------------------------------------------------
collect_cells() {
    local run_dir="$1"
    # Find both summary and excluded markers; merge their identity
    # information.
    while IFS= read -r summary_path; do
        local cell_dir
        cell_dir="$(dirname "${summary_path}")"
        local parity_path="${cell_dir}/parity.json"
        local stats_path="${cell_dir}/docker-stats.csv"

        # Parse the cell dir name: <policy>__<load>__<scenario>
        local cell_name
        cell_name="$(basename "${cell_dir}")"
        local policy load scenario gateway
        policy="${cell_name%%__*}"
        local rest="${cell_name#*__}"
        load="${rest%%__*}"
        scenario="${rest#*__}"
        gateway="$(basename "$(dirname "${cell_dir}")")"

        # Metrics projection from k6-summary.json
        jq -c \
            --arg gateway  "${gateway}" \
            --arg policy   "${policy}" \
            --arg scenario "${scenario}" \
            --arg load     "${load}" \
            --arg run_id   "${RUN_ID}" \
            --arg verdict  "PASS" \
            '{
                gateway:  $gateway,
                policy:   $policy,
                scenario: $scenario,
                load:     $load,
                run_id:   $run_id,
                verdict:  $verdict,
                http_reqs:               (.metrics.http_reqs.count // 0),
                http_req_rate:           (.metrics.http_reqs.rate // 0),
                iter_duration_avg_ms:    (.metrics.iteration_duration.avg // 0),
                http_req_duration_p50:   (.metrics.http_req_duration["p(50)"] // 0),
                http_req_duration_p90:   (.metrics.http_req_duration["p(90)"] // 0),
                http_req_duration_p95:   (.metrics.http_req_duration["p(95)"] // 0),
                http_req_duration_p99:   (.metrics.http_req_duration["p(99)"] // 0),
                http_req_duration_max:   (.metrics.http_req_duration.max // 0),
                http_req_failed_rate:    (.metrics.http_req_failed.value // 0),
                policy_2xx:              (.metrics.policy_2xx.count // 0),
                policy_4xx_expected:     (.metrics.policy_4xx_expected.count // 0),
                policy_4xx_unexpected:   (.metrics.policy_4xx_unexpected.count // 0),
                policy_5xx_unexpected:   (.metrics.policy_5xx_unexpected.count // 0),
                checks_total:            (.root_group.checks // [] | map(.passes + .fails) | add // 0),
                checks_passes:           (.root_group.checks // [] | map(.passes) | add // 0),
                checks_fails:            (.root_group.checks // [] | map(.fails) | add // 0)
            }' "${summary_path}" 2>/dev/null \
        | jq -c --arg parity_path "${parity_path}" --arg stats_path "${stats_path}" '
            . + (
                if ($parity_path | test("^reports/")) and (input_filename | type == "null") | not then {} else {} end
            )
        ' 2>/dev/null \
        | while IFS= read -r row; do
            # Add parity outcome
            local parity_status="UNKNOWN"
            if [[ -s "${parity_path}" ]]; then
                parity_status="$(jq -r '.status // "UNKNOWN"' "${parity_path}" 2>/dev/null || echo UNKNOWN)"
            fi

            # Add docker-stats rollup if CSV is present and has >1 data row.
            local mem_rss_peak=0 mem_rss_steady=0 cpu_pct_peak=0 cpu_pct_steady=0
            if [[ -s "${stats_path}" ]]; then
                read -r mem_rss_peak mem_rss_steady cpu_pct_peak cpu_pct_steady \
                    < <(rollup_stats_csv "${stats_path}")
            fi

            printf '%s\n' "${row}" | jq -c \
                --arg parity_status "${parity_status}" \
                --argjson mem_rss_peak     "${mem_rss_peak:-0}" \
                --argjson mem_rss_steady   "${mem_rss_steady:-0}" \
                --argjson cpu_pct_peak     "${cpu_pct_peak:-0}" \
                --argjson cpu_pct_steady   "${cpu_pct_steady:-0}" \
                '. + {
                    parity_status:    $parity_status,
                    mem_rss_peak:     $mem_rss_peak,
                    mem_rss_steady:   $mem_rss_steady,
                    cpu_pct_peak:     $cpu_pct_peak,
                    cpu_pct_steady:   $cpu_pct_steady
                }'
        done
    done < <(find "${run_dir}/raw" -type f -name 'k6-summary.json' 2>/dev/null | sort)

    # Also emit EXCLUDED rows (no k6-summary.json, only excluded.json)
    while IFS= read -r excluded_path; do
        jq -c '{
            gateway:  .gateway,
            policy:   .policy,
            scenario: .scenario,
            load:     .load,
            run_id:   .run_id,
            verdict:  "EXCLUDED",
            http_reqs: 0, http_req_rate: 0, iter_duration_avg_ms: 0,
            http_req_duration_p50: 0, http_req_duration_p90: 0,
            http_req_duration_p95: 0, http_req_duration_p99: 0,
            http_req_duration_max: 0, http_req_failed_rate: 0,
            policy_2xx: 0, policy_4xx_expected: 0,
            policy_4xx_unexpected: 0, policy_5xx_unexpected: 0,
            checks_total: 0, checks_passes: 0, checks_fails: 0,
            parity_status: (.reason // "N/A"),
            mem_rss_peak: 0, mem_rss_steady: 0,
            cpu_pct_peak: 0, cpu_pct_steady: 0
        }' "${excluded_path}" 2>/dev/null || true
    done < <(find "${run_dir}/raw" -type f -name 'excluded.json' 2>/dev/null | sort)
}

# -----------------------------------------------------------------------------
# docker-stats rollup — peak + steady-state RSS (bytes) and CPU% from
# the per-second CSV. "steady-state" = median of the second half.
#
# CPU% uses the classic docker formula:
#   cpu_delta = cpu_ns_total[i] - cpu_ns_total[i-1]
#   sys_delta = cpu_ns_system[i] - cpu_ns_system[i-1]
#   cpu_pct   = (cpu_delta / sys_delta) * cpu_online * 100
#
# Emits: "<peak_rss> <steady_rss> <peak_cpu> <steady_cpu>"
# -----------------------------------------------------------------------------
rollup_stats_csv() {
    local csv="$1"
    awk -F',' '
        NR == 1 { next }   # skip header
        NR == 2 { prev_cpu=$2+0; prev_sys=$3+0; online=$4+0; next }
        NR > 2 {
            cpu_d = ($2+0) - prev_cpu
            sys_d = ($3+0) - prev_sys
            cpu_pct = (sys_d > 0 && online > 0) ? (cpu_d / sys_d) * online * 100.0 : 0
            rss = $5+0

            rss_samples[NR-2] = rss
            cpu_samples[NR-2] = cpu_pct

            if (rss > rss_peak) rss_peak = rss
            if (cpu_pct > cpu_peak) cpu_peak = cpu_pct

            prev_cpu = $2+0
            prev_sys = $3+0
            online = ($4+0 > 0) ? $4+0 : online
            n = NR - 2
        }
        END {
            # steady-state = median of the second half.
            half = int(n / 2) + 1
            m = 0
            for (i = half; i <= n; i++) {
                rss_half[m] = rss_samples[i]
                cpu_half[m] = cpu_samples[i]
                m++
            }

            # Simple bubble sort for small arrays
            for (i = 0; i < m - 1; i++) {
                for (j = 0; j < m - 1 - i; j++) {
                    if (rss_half[j] > rss_half[j+1]) {
                        tmp = rss_half[j]; rss_half[j] = rss_half[j+1]; rss_half[j+1] = tmp
                    }
                    if (cpu_half[j] > cpu_half[j+1]) {
                        tmp = cpu_half[j]; cpu_half[j] = cpu_half[j+1]; cpu_half[j+1] = tmp
                    }
                }
            }
            rss_steady = (m > 0) ? rss_half[int(m/2)] : 0
            cpu_steady = (m > 0) ? cpu_half[int(m/2)] : 0

            printf "%d %d %.2f %.2f\n", rss_peak+0, rss_steady+0, cpu_peak+0, cpu_steady+0
        }
    ' "${csv}"
}

export -f rollup_stats_csv

# -----------------------------------------------------------------------------
# Column schema (single source of truth for all formatters)
# -----------------------------------------------------------------------------
COLUMNS=(
    gateway policy scenario load run_id verdict parity_status
    http_reqs http_req_rate iter_duration_avg_ms
    http_req_duration_p50 http_req_duration_p90 http_req_duration_p95
    http_req_duration_p99 http_req_duration_max
    http_req_failed_rate
    policy_2xx policy_4xx_expected policy_4xx_unexpected policy_5xx_unexpected
    checks_total checks_passes checks_fails
    mem_rss_peak mem_rss_steady cpu_pct_peak cpu_pct_steady
)

# -----------------------------------------------------------------------------
# Emitter
# -----------------------------------------------------------------------------
emit_header_csv() { (IFS=,; printf '%s\n' "${COLUMNS[*]}") > "$1"; }
emit_header_tsv() { (IFS=$'\t'; printf '%s\n' "${COLUMNS[*]}") > "$1"; }
emit_header_md()  {
    {
        (IFS='|'; printf '| %s |\n' "${COLUMNS[*]}" | sed 's/|/ | /g; s/^  / /; s/  $/ /')
        printf '|'; for _ in "${COLUMNS[@]}"; do printf -- '---|'; done; printf '\n'
    } > "$1"
}

cells="$(mktemp)"
collect_cells "${RUN_DIR}" > "${cells}"

cell_count="$(wc -l < "${cells}" | tr -d ' ')"
if [[ "${cell_count}" -eq 0 ]]; then
    printf 'no cells found under %s/raw/\n' "${RUN_DIR}" >&2
    exit 3
fi

mkdir -p "$(dirname "${OUTPUT}")"

case "${FORMAT}" in
    csv)
        emit_header_csv "${OUTPUT}"
        # Build jq projection for csv
        jq_expr='[.gateway,.policy,.scenario,.load,.run_id,.verdict,.parity_status,
                  .http_reqs,.http_req_rate,.iter_duration_avg_ms,
                  .http_req_duration_p50,.http_req_duration_p90,.http_req_duration_p95,
                  .http_req_duration_p99,.http_req_duration_max,
                  .http_req_failed_rate,
                  .policy_2xx,.policy_4xx_expected,.policy_4xx_unexpected,.policy_5xx_unexpected,
                  .checks_total,.checks_passes,.checks_fails,
                  .mem_rss_peak,.mem_rss_steady,.cpu_pct_peak,.cpu_pct_steady] | @csv'
        jq -r "${jq_expr}" "${cells}" >> "${OUTPUT}"
        ;;
    tsv)
        emit_header_tsv "${OUTPUT}"
        jq_expr='[.gateway,.policy,.scenario,.load,.run_id,.verdict,.parity_status,
                  .http_reqs,.http_req_rate,.iter_duration_avg_ms,
                  .http_req_duration_p50,.http_req_duration_p90,.http_req_duration_p95,
                  .http_req_duration_p99,.http_req_duration_max,
                  .http_req_failed_rate,
                  .policy_2xx,.policy_4xx_expected,.policy_4xx_unexpected,.policy_5xx_unexpected,
                  .checks_total,.checks_passes,.checks_fails,
                  .mem_rss_peak,.mem_rss_steady,.cpu_pct_peak,.cpu_pct_steady] | @tsv'
        jq -r "${jq_expr}" "${cells}" >> "${OUTPUT}"
        ;;
    md)
        emit_header_md "${OUTPUT}"
        # Markdown: keep numeric formatting reasonable
        jq -r '
            ["| " + .gateway + " | " + .policy + " | " + .scenario + " | " + .load + " | " + .run_id + " | " + .verdict + " | " + .parity_status + " | " +
             (.http_reqs|tostring) + " | " +
             (.http_req_rate|tostring) + " | " +
             ((.iter_duration_avg_ms*100|round)/100|tostring) + " | " +
             ((.http_req_duration_p50*100|round)/100|tostring) + " | " +
             ((.http_req_duration_p90*100|round)/100|tostring) + " | " +
             ((.http_req_duration_p95*100|round)/100|tostring) + " | " +
             ((.http_req_duration_p99*100|round)/100|tostring) + " | " +
             ((.http_req_duration_max*100|round)/100|tostring) + " | " +
             (.http_req_failed_rate|tostring) + " | " +
             (.policy_2xx|tostring) + " | " +
             (.policy_4xx_expected|tostring) + " | " +
             (.policy_4xx_unexpected|tostring) + " | " +
             (.policy_5xx_unexpected|tostring) + " | " +
             (.checks_total|tostring) + " | " +
             (.checks_passes|tostring) + " | " +
             (.checks_fails|tostring) + " | " +
             (.mem_rss_peak|tostring) + " | " +
             (.mem_rss_steady|tostring) + " | " +
             (.cpu_pct_peak|tostring) + " | " +
             (.cpu_pct_steady|tostring) + " |"][]
        ' "${cells}" >> "${OUTPUT}"
        ;;
esac

rm -f "${cells}"

printf 'wrote: %s  (%d cells, %s format)\n' "${OUTPUT}" "${cell_count}" "${FORMAT}"
exit 0
