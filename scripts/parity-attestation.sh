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
# Coverage in the Phase 3 foundation commit:
#   - All "simple" probes (HTTP request + assertion set).
#   - "burst" probes: recorded, marked "skipped" for now; a follow-up
#     turns them into parallel hey/xargs bursts.
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

    if [[ "${kind}" != "simple" ]]; then
        SKIPPED=$(( SKIPPED + 1 ))
        (( VERBOSE == 1 )) && \
            printf '  ~ SKIP   [burst] %s\n' "$(jq -r '.name' <<< "${probe_json}")"
        RESULTS_JSON=$(jq -c \
            --argjson p "${probe_json}" \
            '. + [$p + {_runtime: {status: "skipped", reason: "burst runner not yet implemented"}}]' \
            <<< "${RESULTS_JSON}")
        return
    fi

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

    # response_body_json_contains (map path -> expected)
    while IFS=$'\t' read -r path expected; do
        [[ -z "${path}" ]] && continue
        assert_json_eq "${path}" "${expected}" \
            || fails+=("body at ${path}: expected ${expected}, got $(json_get "${path}")")
    done < <(jq -r '(.expect.response_body_json_contains // {}) | to_entries[] | "\(.key)\t\(.value|tostring)"' <<< "${probe_json}")

    # response_body_json_absent
    while IFS= read -r path; do
        [[ -z "${path}" ]] && continue
        assert_json_missing "${path}" || fails+=("body at ${path}: unexpectedly present")
    done < <(jq -r '.expect.response_body_json_absent // [] | .[]' <<< "${probe_json}")

    # backend_saw_header / backend_missed_header (via /anything echo)
    while IFS=$'\t' read -r hdr want; do
        [[ -z "${hdr}" ]] && continue
        local path=".headers.\"${hdr}\""
        assert_json_match_string "${path}" "${want}" \
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
