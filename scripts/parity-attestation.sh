#!/usr/bin/env bash
# shellcheck shell=bash
#
# Parity attestation runner — Phase 3 foundation.
#
# Runs the per-profile probe sets from ./fixtures/p<XX>-*.jsonl against a
# gateway (or directly against the backend for bootstrapping) and emits a
# machine-readable result:
#
#   {
#     "gateway":    "<name>",
#     "profile":    "p01",
#     "target":     "http://localhost:8080",
#     "status":     "PASS"|"FAIL"|"FEATURE-MISSING",
#     "probes":     24,
#     "passed":     24,
#     "failed":     0,
#     "skipped":    0,
#     "deviations": []
#   }
#
# Usage:
#   parity-attestation.sh \
#     --gateway <name> \
#     --profile <pXX[-slug]> \
#     --target  <url>            # gateway endpoint, e.g. http://localhost:9080
#     [--backend-peek <url>]     # backend introspection URL for p06/p10 checks
#     [--feature-missing]        # mark the whole cell as FEATURE-MISSING
#     [--output    <path>]       # JSON result file (default: stdout only)
#     [--verbose]                # print each probe's result
#
# Dependencies: bash, curl, jq. No root, no containers needed.
#
# Coverage:
#   - Simple probes (single HTTP request + assertion set).
#   - Burst probes: fanned out over `xargs -P` with per-request key-header
#     rotation, then the 2xx / 429 / 5xx counts are asserted against the
#     tolerances in docs/POLICIES.md § rate-limit probes.
#   - Placeholder substitution: ${JWT_VALID}, ${JWT_EXPIRED}, ${JWT_WRONG}.

set -euo pipefail
shopt -s nullglob

# -----------------------------------------------------------------------------
# Paths
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
FIXTURES_DIR="${REPO_ROOT}/fixtures"

# -----------------------------------------------------------------------------
# Dependencies
# -----------------------------------------------------------------------------
for dep in curl jq; do
    command -v "${dep}" >/dev/null 2>&1 || {
        printf 'parity-attestation.sh: missing dependency: %s\n' "${dep}" >&2
        exit 2
    }
done

# -----------------------------------------------------------------------------
# Arg parsing
# -----------------------------------------------------------------------------
GATEWAY=""
PROFILE=""
TARGET=""
BACKEND_PEEK=""
OUTPUT=""
VERBOSE=0
FEATURE_MISSING=0

usage() {
    sed -n '2,28p' "${BASH_SOURCE[0]}" >&2
    exit 2
}

while (( $# > 0 )); do
    case "$1" in
        --gateway)          GATEWAY="$2"; shift 2;;
        --profile)          PROFILE="$2"; shift 2;;
        --target)           TARGET="$2"; shift 2;;
        --backend-peek)     BACKEND_PEEK="$2"; shift 2;;
        --output)           OUTPUT="$2"; shift 2;;
        --feature-missing)  FEATURE_MISSING=1; shift;;
        --verbose|-v)       VERBOSE=1; shift;;
        -h|--help)          usage;;
        *) printf 'unknown arg: %s\n' "$1" >&2; usage;;
    esac
done

[[ -n "${GATEWAY}" ]] || { printf '%s\n' "--gateway is required" >&2; exit 2; }
[[ -n "${PROFILE}" ]] || { printf '%s\n' "--profile is required" >&2; exit 2; }
[[ -n "${TARGET}"  ]] || { printf '%s\n' "--target is required"  >&2; exit 2; }

TARGET="${TARGET%/}"
[[ -n "${BACKEND_PEEK}" ]] && BACKEND_PEEK="${BACKEND_PEEK%/}"

# -----------------------------------------------------------------------------
# Find the fixture file
# -----------------------------------------------------------------------------
fixture_file=""
for candidate in \
    "${FIXTURES_DIR}/${PROFILE}.jsonl" \
    "${FIXTURES_DIR}/${PROFILE}-"*.jsonl; do
    [[ -f "${candidate}" ]] && { fixture_file="${candidate}"; break; }
done
[[ -n "${fixture_file}" ]] \
    || { printf 'parity: no fixture matching %s in %s\n' "${PROFILE}" "${FIXTURES_DIR}" >&2; exit 2; }

# -----------------------------------------------------------------------------
# Feature-missing short-circuit
# -----------------------------------------------------------------------------
if (( FEATURE_MISSING == 1 )); then
    result=$(jq -cn \
        --arg gateway "${GATEWAY}" \
        --arg profile "${PROFILE}" \
        --arg target  "${TARGET}" \
        --arg fixture "${fixture_file#"${REPO_ROOT}"/}" \
        '{gateway:$gateway, profile:$profile, target:$target, fixture:$fixture,
          status:"FEATURE-MISSING", probes:0, passed:0, failed:0, skipped:0, results:[], deviations:[]}')
    if [[ -n "${OUTPUT}" ]]; then
        mkdir -p "$(dirname "${OUTPUT}")"
        printf '%s\n' "${result}" > "${OUTPUT}"
    fi
    printf '%s\n' "${result}"
    printf '==> %s / %s: FEATURE-MISSING\n' "${GATEWAY}" "${PROFILE}" >&2
    exit 0
fi

# -----------------------------------------------------------------------------
# JWT placeholders — generated lazily on first use.
# -----------------------------------------------------------------------------
JWT_VALID=""
JWT_EXPIRED=""
JWT_WRONG=""

lazy_jwt() {
    case "$1" in
        valid)
            [[ -n "${JWT_VALID}"   ]] || JWT_VALID="$("${SCRIPT_DIR}/gen-jwt.sh" valid)"
            printf '%s' "${JWT_VALID}";;
        expired)
            [[ -n "${JWT_EXPIRED}" ]] || JWT_EXPIRED="$("${SCRIPT_DIR}/gen-jwt.sh" expired)"
            printf '%s' "${JWT_EXPIRED}";;
        wrong)
            [[ -n "${JWT_WRONG}"   ]] || JWT_WRONG="$("${SCRIPT_DIR}/gen-jwt.sh" wrong-secret)"
            printf '%s' "${JWT_WRONG}";;
    esac
}

substitute_placeholders() {
    # Echo "$1" with ${JWT_*} replaced by the live token.
    # The single-quoted needles are intentional — we're looking for the
    # literal string "${JWT_VALID}" in the probe, not for the value of
    # the shell variable. (Shellcheck SC2016: accepted.)
    local s="$1"
    # shellcheck disable=SC2016
    [[ "${s}" != *'${JWT_VALID}'*   ]] || s="${s//\$\{JWT_VALID\}/$(lazy_jwt valid)}"
    # shellcheck disable=SC2016
    [[ "${s}" != *'${JWT_EXPIRED}'* ]] || s="${s//\$\{JWT_EXPIRED\}/$(lazy_jwt expired)}"
    # shellcheck disable=SC2016
    [[ "${s}" != *'${JWT_WRONG}'*   ]] || s="${s//\$\{JWT_WRONG\}/$(lazy_jwt wrong)}"
    printf '%s' "${s}"
}

# -----------------------------------------------------------------------------
# Probe execution
#
# Each probe is a JSON object loaded from the fixture file. We:
#   1. Read its request description.
#   2. Run curl, dump status/headers/body to temp files.
#   3. Evaluate each assertion in the "expect" block.
#   4. Append a per-probe result object into RESULTS_JSON (jq stream).
# -----------------------------------------------------------------------------
RESULTS_JSON='[]'
TOTAL=0
PASSED=0
FAILED=0
SKIPPED=0
declare -a fails=()

tmpdir="$(mktemp -d 2>/dev/null || mktemp -d -t parity)"
trap 'rm -rf "${tmpdir}"' EXIT

run_probe() {
    local probe_json="$1"

    local kind
    kind=$(jq -r '.kind // "simple"' <<< "${probe_json}")

    case "${kind}" in
        simple) ;;                                   # falls through to the simple runner below
        burst)  run_burst_probe "${probe_json}"; return;;
        *)
            SKIPPED=$(( SKIPPED + 1 ))
            (( VERBOSE == 1 )) && \
                printf '  ~ SKIP   [%s] %s\n' "${kind}" "$(jq -r '.name' <<< "${probe_json}")"
            RESULTS_JSON=$(jq -c \
                --argjson p "${probe_json}" \
                --arg    reason "unknown probe kind: ${kind}" \
                '. + [$p + {_runtime: {status: "skipped", reason: $reason}}]' \
                <<< "${RESULTS_JSON}")
            return
            ;;
    esac

    local name method path body_raw url
    name=$(jq -r '.name' <<< "${probe_json}")
    method=$(jq -r '.request.method // "GET"' <<< "${probe_json}")
    path=$(jq -r '.request.path // "/"'       <<< "${probe_json}")

    # Query params -> concatenate into path
    local query
    query=$(jq -r '
        (.request.query // {}) | to_entries
        | map("\(.key)=\(.value|@uri)") | join("&")
    ' <<< "${probe_json}")
    if [[ -n "${query}" ]]; then
        if [[ "${path}" == *\?* ]]; then path="${path}&${query}"; else path="${path}?${query}"; fi
    fi

    url="${TARGET}${path}"

    # Body
    body_raw=""
    if jq -e '.request.body_json' <<< "${probe_json}" >/dev/null; then
        body_raw=$(jq -c '.request.body_json' <<< "${probe_json}")
    elif jq -e '.request.body' <<< "${probe_json}" >/dev/null; then
        body_raw=$(jq -r '.request.body' <<< "${probe_json}")
    fi

    # curl args
    local curl_args=(-sS -o "${tmpdir}/body" -D "${tmpdir}/headers" -w '%{http_code}' -X "${method}")

    # Headers
    while IFS= read -r line; do
        [[ -z "${line}" ]] && continue
        curl_args+=(-H "$(substitute_placeholders "${line}")")
    done < <(jq -r '(.request.headers // {}) | to_entries[] | "\(.key): \(.value)"' <<< "${probe_json}")

    if [[ -n "${body_raw}" ]]; then
        printf '%s' "${body_raw}" > "${tmpdir}/reqbody"
        curl_args+=(--data-binary "@${tmpdir}/reqbody")
    fi

    # Execute
    local status_code
    : > "${tmpdir}/headers"
    : > "${tmpdir}/body"
    status_code=$(curl "${curl_args[@]}" "${url}" 2>/dev/null || true)

    # Evaluate assertions. `fails` is intentionally declared outside the
    # function body so that assert_all can push into it, and we use
    # `"${fails[@]+"${fails[@]}"}"` everywhere to survive `set -u` on
    # empty arrays.
    fails=()
    assert_all "${probe_json}" "${status_code}" || true

    TOTAL=$(( TOTAL + 1 ))
    local outcome
    if (( ${#fails[@]} == 0 )); then
        PASSED=$(( PASSED + 1 ))
        outcome="pass"
        (( VERBOSE == 1 )) && printf '  %s PASS   %s\n' "$(printf '\xe2\x9c\x93')" "${name}"
    else
        FAILED=$(( FAILED + 1 ))
        outcome="fail"
        if (( VERBOSE == 1 )); then
            printf '  %s FAIL   %s\n' "$(printf '\xe2\x9c\x97')" "${name}"
            for msg in "${fails[@]}"; do printf '           - %s\n' "${msg}"; done
        fi
    fi

    local fail_arr
    if (( ${#fails[@]} == 0 )); then
        fail_arr='[]'
    else
        fail_arr=$(printf '%s\n' "${fails[@]}" | jq -R . | jq -cs .)
    fi
    RESULTS_JSON=$(jq -c \
        --argjson p "${probe_json}" \
        --arg outcome "${outcome}" \
        --argjson status "${status_code:-0}" \
        --argjson fails "${fail_arr}" \
        '. + [$p + {_runtime: {status: $outcome, http_status: $status, failures: $fails}}]' \
        <<< "${RESULTS_JSON}")
}

# -----------------------------------------------------------------------------
# Burst probes — rate-limit parity attestation
#
# A "burst" probe fires N requests over D seconds, optionally distributing
# them across K different keys (e.g. X-Real-IP values). Responses are
# tallied into {2xx, 429, 5xx, other} and compared against the expected
# thresholds from the fixture (`status_429_min`, `status_2xx_min`,
# `status_429_tolerance`).
#
# Parallelism is capped at BURST_PARALLELISM to keep the harness portable
# (no `hey`, no `ab`, no `vegeta` — just `curl` + `xargs -P`).
# -----------------------------------------------------------------------------
BURST_PARALLELISM="${BURST_PARALLELISM:-32}"

expand_key_pool() {
    # "10.0.0.1..10.0.0.10" -> "10.0.0.1 10.0.0.2 ... 10.0.0.10"
    # "10.5.9.9"            -> "10.5.9.9"
    local pool="$1"
    if [[ "${pool}" != *..* ]]; then
        printf '%s\n' "${pool}"
        return
    fi
    local start_ip="${pool%..*}" end_ip="${pool#*..}"
    local prefix="${start_ip%.*}"
    local first="${start_ip##*.}" last="${end_ip##*.}"
    local i
    for (( i = first; i <= last; i++ )); do
        printf '%s.%s\n' "${prefix}" "${i}"
    done
}

run_burst_probe() {
    local probe_json="$1"

    local name method path
    name=$(jq -r '.name'                           <<< "${probe_json}")
    method=$(jq -r '.burst.request.method // "GET"' <<< "${probe_json}")
    path=$(jq -r   '.burst.request.path   // "/"'  <<< "${probe_json}")

    local total duration_s key_header key_pool
    total=$(jq -r       '.burst.total_requests'     <<< "${probe_json}")
    duration_s=$(jq -r  '.burst.duration_s // 1'    <<< "${probe_json}")
    key_header=$(jq -r  '.burst.key_header // ""'   <<< "${probe_json}")
    key_pool=$(jq -r    '.burst.key_pool   // ""'   <<< "${probe_json}")

    local url="${TARGET}${path}"

    local -a static_headers=()
    while IFS= read -r line; do
        [[ -z "${line}" ]] && continue
        static_headers+=("$(substitute_placeholders "${line}")")
    done < <(jq -r '(.burst.headers // {}) | to_entries[] | "\(.key): \(.value)"' <<< "${probe_json}")

    # Key rotation
    local -a keys=()
    if [[ -n "${key_pool}" ]]; then
        while IFS= read -r k; do keys+=("${k}"); done < <(expand_key_pool "${key_pool}")
    fi

    # Compose a single curl config file with one `--next` block per
    # request. curl (>= 7.66) runs the whole file in parallel inside
    # one process when we pass `--parallel --parallel-max N` — no
    # fork-per-request, no shell round-trips, and bounded concurrency
    # comes for free. This is what lets the p03 burst actually fit
    # inside the 1-second window so the rate limiter engages.
    local config_file="${tmpdir}/burst.curl"
    local codes="${tmpdir}/burst_codes.txt"
    : > "${config_file}"
    : > "${codes}"

    local i header_line=""
    for (( i = 0; i < total; i++ )); do
        if [[ -n "${key_header}" && ${#keys[@]} -gt 0 ]]; then
            header_line="${key_header}: ${keys[$(( i % ${#keys[@]} ))]}"
        else
            header_line=""
        fi
        {
            printf -- 'request = "%s"\n' "${method}"
            local hdr
            for hdr in "${static_headers[@]+"${static_headers[@]}"}"; do
                printf -- 'header = "%s"\n' "${hdr}"
            done
            [[ -n "${header_line}" ]] && printf -- 'header = "%s"\n' "${header_line}"
            printf -- 'silent\n'
            printf -- 'output = "/dev/null"\n'
            printf -- 'write-out = "%%{http_code}\\n"\n'
            printf -- 'url = "%s"\n' "${url}"
            (( i + 1 < total )) && printf -- 'next\n'
        } >> "${config_file}"
    done

    local par="${BURST_PARALLELISM}"
    (( par > total )) && par="${total}"

    local burst_start burst_end elapsed_s
    burst_start=$(date +%s)

    curl --parallel --parallel-max "${par}" -K "${config_file}" \
        > "${codes}" 2>/dev/null || true

    burst_end=$(date +%s)
    elapsed_s=$(( burst_end - burst_start ))

    # Aggregate
    local n_total n_2xx n_429 n_5xx n_other
    n_total=$(wc -l < "${codes}" | tr -d ' ')
    n_2xx=$(grep -cE '^2[0-9]{2}$' "${codes}" || true)
    n_429=$(grep -c '^429$'        "${codes}" || true)
    n_5xx=$(grep -cE '^5[0-9]{2}$' "${codes}" || true)
    n_other=$(( n_total - n_2xx - n_429 - n_5xx ))

    # Assertions
    fails=()
    local e_429_min e_429_tol e_2xx_min
    e_429_min=$(jq -r '.expect.status_429_min // empty'      <<< "${probe_json}")
    e_429_tol=$(jq -r '.expect.status_429_tolerance // 0'    <<< "${probe_json}")
    e_2xx_min=$(jq -r '.expect.status_2xx_min // empty'      <<< "${probe_json}")

    if [[ -n "${e_429_min}" ]]; then
        local threshold=$(( e_429_min - e_429_tol ))
        (( threshold < 0 )) && threshold=0
        if (( n_429 < threshold )); then
            fails+=("burst: expected >= ${e_429_min} (+/- ${e_429_tol}) × 429, got ${n_429}")
        fi
    fi

    if [[ -n "${e_2xx_min}" ]]; then
        if (( n_2xx < e_2xx_min )); then
            fails+=("burst: expected >= ${e_2xx_min} × 2xx, got ${n_2xx}")
        fi
    fi

    # Some gateways surface rate-limit denials as 5xx when the upstream
    # is saturated. That's a real signal worth catching.
    if (( n_5xx > 0 )); then
        fails+=("burst: unexpected ${n_5xx} × 5xx (should be 2xx or 429)")
    fi

    TOTAL=$(( TOTAL + 1 ))
    local outcome
    if (( ${#fails[@]} == 0 )); then
        PASSED=$(( PASSED + 1 ))
        outcome="pass"
        (( VERBOSE == 1 )) && printf '  %s PASS   %s  [burst: %dx, %.0fs, 2xx=%d 429=%d 5xx=%d]\n' \
            "$(printf '\xe2\x9c\x93')" "${name}" "${n_total}" "${elapsed_s}" \
            "${n_2xx}" "${n_429}" "${n_5xx}"
    else
        FAILED=$(( FAILED + 1 ))
        outcome="fail"
        if (( VERBOSE == 1 )); then
            printf '  %s FAIL   %s  [burst: %dx, %.0fs, 2xx=%d 429=%d 5xx=%d]\n' \
                "$(printf '\xe2\x9c\x97')" "${name}" "${n_total}" "${elapsed_s}" \
                "${n_2xx}" "${n_429}" "${n_5xx}"
            for msg in "${fails[@]}"; do printf '           - %s\n' "${msg}"; done
        fi
    fi

    local fail_arr
    if (( ${#fails[@]} == 0 )); then
        fail_arr='[]'
    else
        fail_arr=$(printf '%s\n' "${fails[@]}" | jq -R . | jq -cs .)
    fi

    RESULTS_JSON=$(jq -c \
        --argjson p "${probe_json}" \
        --arg     outcome    "${outcome}" \
        --argjson total      "${n_total}" \
        --argjson n_2xx      "${n_2xx}" \
        --argjson n_429      "${n_429}" \
        --argjson n_5xx      "${n_5xx}" \
        --argjson n_other    "${n_other}" \
        --argjson elapsed_s  "${elapsed_s}" \
        --argjson parallel   "${par}" \
        --argjson fails      "${fail_arr}" \
        '. + [$p + {_runtime: {
            status: $outcome,
            burst: {
                total: $total,
                "2xx": $n_2xx,
                "429": $n_429,
                "5xx": $n_5xx,
                other: $n_other,
                elapsed_s: $elapsed_s,
                parallelism: $parallel
            },
            failures: $fails
        }}]' \
        <<< "${RESULTS_JSON}")
}

# ----- assertions -------------------------------------------------------------
# Pipes and helpers reuse "${tmpdir}/headers" / "${tmpdir}/body" populated
# by run_probe.

assert_all() {
    local probe_json="$1" status_code="$2"
    local expected

    # status
    expected=$(jq -r '.expect.status // empty' <<< "${probe_json}")
    if [[ -n "${expected}" && "${expected}" != "${status_code}" ]]; then
        fails+=("expected HTTP ${expected}, got ${status_code}")
    fi

    # response_header_present
    while IFS= read -r hdr; do
        [[ -z "${hdr}" ]] && continue
        assert_header_present "${hdr}" || fails+=("missing response header: ${hdr}")
    done < <(jq -r '.expect.response_header_present // [] | .[]' <<< "${probe_json}")

    # response_header_absent
    while IFS= read -r hdr; do
        [[ -z "${hdr}" ]] && continue
        assert_header_absent "${hdr}" || fails+=("unexpected response header: ${hdr}")
    done < <(jq -r '.expect.response_header_absent // [] | .[]' <<< "${probe_json}")

    # response_body_json_contains (map path -> expected).
    #
    # Uses assert_json_contains_value, which — like assert_json_has_string
    # for backend-saw-header — accepts both a scalar and an array-of-one
    # representation at `${path}`. This matters because go-httpbin encodes
    # query args as `"q": ["hello"]` (potentially multi-value) while other
    # echo backends / real upstreams emit `"q": "hello"`. The fixture
    # should express the *intent* ("arg q equals hello") and stay agnostic
    # of how the backend chooses to echo it.
    while IFS=$'\t' read -r path expected; do
        [[ -z "${path}" ]] && continue
        assert_json_contains_value "${path}" "${expected}" \
            || fails+=("body at ${path}: expected ${expected}, got $(json_get "${path}" | tr '\n' ' ' | sed 's/  */ /g')")
    done < <(jq -r '(.expect.response_body_json_contains // {}) | to_entries[] | "\(.key)\t\(.value|tostring)"' <<< "${probe_json}")

    # response_body_json_absent
    while IFS= read -r path; do
        [[ -z "${path}" ]] && continue
        assert_json_missing "${path}" || fails+=("body at ${path}: unexpectedly present")
    done < <(jq -r '.expect.response_body_json_absent // [] | .[]' <<< "${probe_json}")

    # backend_saw_header / backend_missed_header (via the backend echo at .headers)
    #
    # go-httpbin returns each request header as a JSON array of strings,
    # e.g. `"X-Bench-In": ["1"]`. assert_json_has_string accepts both
    # a plain string and an array-of-strings shape, so fixtures stay
    # gateway-agnostic (a gateway whose backend emits the header as a
    # scalar string still passes the same probe).
    while IFS=$'\t' read -r hdr want; do
        [[ -z "${hdr}" ]] && continue
        local path=".headers.\"${hdr}\""
        assert_json_has_string "${path}" "${want}" \
            || fails+=("backend did not see header ${hdr}=${want}")
    done < <(jq -r '(.expect.backend_saw_header // {}) | to_entries[] | "\(.key)\t\(.value)"' <<< "${probe_json}")

    while IFS= read -r hdr; do
        [[ -z "${hdr}" ]] && continue
        assert_json_missing ".headers.\"${hdr}\"" \
            || fails+=("backend unexpectedly saw header ${hdr}")
    done < <(jq -r '.expect.backend_missed_header // [] | .[]' <<< "${probe_json}")
}

header_names_lc() {
    # Print one lower-cased header name per line from the captured headers file.
    awk -F ':' 'NR>1 && NF>=2 {name=$1; gsub(/\r/,"",name); print tolower(name)}' "${tmpdir}/headers"
}

assert_header_present() {
    local name_lc; name_lc=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
    header_names_lc | grep -qx "${name_lc}"
}

assert_header_absent() {
    local name_lc; name_lc=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
    ! header_names_lc | grep -qx "${name_lc}"
}

json_get() {
    # jsonpath "$.a.b" -> body slice using jq
    local path="$1"
    local jq_path="${path/#\$/}"
    [[ "${jq_path}" = "" ]] && jq_path="."
    # If path begins with a dot key already ("." in front), leave as is.
    jq -r "${jq_path} // empty" "${tmpdir}/body" 2>/dev/null || true
}

assert_json_eq() {
    # $1 = path, $2 = expected scalar serialised as string
    local path="$1" want="$2"
    local got
    got=$(json_get "${path}")
    # True/false/null come out lower-case from jq -r; numbers come out as numbers.
    [[ "${got}" == "${want}" ]]
}

assert_json_match_string() {
    local path="$1" want="$2"
    local got
    got=$(json_get "${path}")
    [[ "${got}" == "${want}" ]]
}

# Accepts either scalar string or array-of-strings at ${path}. This makes
# fixture assertions work uniformly across backends (e.g. go-httpbin emits
# `"X-Foo": ["1"]`, while a proxy echo endpoint might emit `"X-Foo": "1"`).
assert_json_has_string() {
    local path="$1" want="$2"
    local jq_path="${path/#\$/}"
    [[ "${jq_path}" = "" ]] && jq_path="."
    jq -e --arg want "${want}" \
        "(${jq_path}) as \$v |
            if   \$v | type == \"string\" then \$v == \$want
            elif \$v | type == \"array\"  then (\$v | map(tostring) | index(\$want) != null)
            else false
            end" \
        "${tmpdir}/body" >/dev/null 2>&1
}

# Superset of assert_json_has_string: also accepts booleans/numbers by
# comparing their `tostring` form. Null / missing is always a miss.
# Used for `response_body_json_contains`, where a fixture may assert e.g.
# `$.bench.injected == true` (bool), `$.status == 200` (number), or
# `$.args.q == "hello"` (scalar-or-array from an echo backend).
assert_json_contains_value() {
    local path="$1" want="$2"
    local jq_path="${path/#\$/}"
    [[ "${jq_path}" = "" ]] && jq_path="."
    jq -e --arg want "${want}" \
        "(${jq_path}) as \$v |
            if   \$v == null               then false
            elif \$v | type == \"string\"  then \$v == \$want
            elif \$v | type == \"array\"   then (\$v | map(tostring) | index(\$want) != null)
            else (\$v | tostring) == \$want
            end" \
        "${tmpdir}/body" >/dev/null 2>&1
}

assert_json_missing() {
    local path="$1"
    local jq_path="${path/#\$/}"
    [[ "${jq_path}" = "" ]] && jq_path="."
    local got
    got=$(jq -r "${jq_path}" "${tmpdir}/body" 2>/dev/null || printf 'null')
    [[ "${got}" == "null" || -z "${got}" ]]
}

# -----------------------------------------------------------------------------
# Iterate the fixture
# -----------------------------------------------------------------------------
printf '==> parity: gateway=%s profile=%s target=%s\n' "${GATEWAY}" "${PROFILE}" "${TARGET}" >&2
printf '    fixture: %s\n' "${fixture_file#"${REPO_ROOT}"/}" >&2

while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    run_probe "${line}"
done < "${fixture_file}"

# -----------------------------------------------------------------------------
# Verdict
# -----------------------------------------------------------------------------
if   (( FAILED > 0 ));  then STATUS="FAIL"
elif (( PASSED == 0 && SKIPPED > 0 )); then STATUS="SKIPPED"
else STATUS="PASS"
fi

result=$(jq -cn \
    --arg    gateway "${GATEWAY}" \
    --arg    profile "${PROFILE}" \
    --arg    target  "${TARGET}" \
    --arg    fixture "${fixture_file#"${REPO_ROOT}"/}" \
    --arg    status  "${STATUS}" \
    --argjson probes ${TOTAL} \
    --argjson passed ${PASSED} \
    --argjson failed ${FAILED} \
    --argjson skipped ${SKIPPED} \
    --argjson results "${RESULTS_JSON}" \
    '{gateway:$gateway, profile:$profile, target:$target, fixture:$fixture,
      status:$status, probes:$probes, passed:$passed, failed:$failed, skipped:$skipped,
      results:$results, deviations:[]}')

if [[ -n "${OUTPUT}" ]]; then
    mkdir -p "$(dirname "${OUTPUT}")"
    printf '%s\n' "${result}" > "${OUTPUT}"
fi
printf '%s\n' "${result}"

printf '==> %s / %s: %s  (passed %d/%d, skipped %d)\n' \
    "${GATEWAY}" "${PROFILE}" "${STATUS}" "${PASSED}" "${TOTAL}" "${SKIPPED}" >&2

# Exit with a non-zero code only on hard failure. FEATURE-MISSING / SKIPPED are
# not failures — the orchestrator interprets them via the JSON.
if [[ "${STATUS}" == "FAIL" ]]; then exit 1; fi
exit 0
