#!/usr/bin/env bash
# Quiet, user-facing AWS fleet runner for the full benchmark report.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

RUN_ID="${BENCH_AWS_FULL_RUN_ID:-aws-$(date -u +%Y%m%dT%H%M%SZ)}"
AWS_TOFU_DIR="${AWS_TOFU_DIR:-infra/aws}"
TOFU_BIN="${TOFU_BIN:-tofu}"
ORCH_BIN="${ORCH_BIN:-orchestrator/bin/bench}"
REMOTE_BIN="${BENCH_AWS_REMOTE_BIN:-orchestrator/bin/bench-linux-amd64}"
COPY_DIR="${BENCH_AWS_REPORT_COPY_DIR:-${HOME}/Desktop/${RUN_ID}}"
REPORT_PATH="${COPY_DIR}/report.html"
LOG_DIR="reports/${RUN_ID}-logs"
REPORT_LOGO="${BENCH_AWS_REPORT_LOGO:-}"

# If the operator opted into S3 publishing (BENCH_AWS_REPORT_S3_BUCKET),
# compute the eventual public URL up front so it can be (a) shown in
# the startup banner — useful for scheduling a deferred Slack message
# while the run is still in progress — and (b) reused verbatim by the
# publish step at the end. Bucket/region/prefix conventions match the
# `aws s3 cp` block below; keep the two in sync.
S3_REPORT_URL=""
S3_REPORT_KEY=""
S3_REPORT_REGION=""
if [[ -n "${BENCH_AWS_REPORT_S3_BUCKET:-}" ]]; then
	S3_REPORT_REGION="${BENCH_AWS_REPORT_S3_REGION:-eu-central-1}"
	_s3_prefix="${BENCH_AWS_REPORT_S3_PREFIX:-reports}"
	_s3_prefix="${_s3_prefix%/}"
	S3_REPORT_KEY="${_s3_prefix}/${RUN_ID}/report.html"
	S3_REPORT_URL="https://${BENCH_AWS_REPORT_S3_BUCKET}.s3.${S3_REPORT_REGION}.amazonaws.com/${S3_REPORT_KEY}"
fi

FLEET_SIZE="${BENCH_AWS_FLEET_SIZE:-7}"
INSTANCE_TYPE="${BENCH_AWS_INSTANCE_TYPE:-c7i.4xlarge}"
PARALLEL="${BENCH_AWS_PARALLEL:-4}"
PARALLEL_SUFFIX=""
if [[ "${PARALLEL}" != "1" ]]; then
	PARALLEL_SUFFIX=" · parallel ${PARALLEL}"
fi
GATEWAYS="${BENCH_AWS_FULL_GATEWAYS:-all}"
LOADS="${BENCH_AWS_FULL_LOADS:-http}"
REPS="${BENCH_AWS_FULL_REPS:-1}"
SEED="${BENCH_SEED:-42}"
NOTES="${BENCH_AWS_FULL_NOTES:-AWS canonical report sweep}"
PROGRESS_INTERVAL="${BENCH_PROGRESS_INTERVAL:-30s}"
DESTROY_AFTER="${BENCH_AWS_DESTROY_AFTER:-1}"
OPEN_REPORT="${BENCH_AWS_OPEN_REPORT:-1}"

mkdir -p "${LOG_DIR}" reports
pids=()

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
CYAN=$'\033[0;36m'
NC=$'\033[0m'

ts() { date '+%H:%M:%S'; }

duration() {
	local s="$1"
	local h=$((s / 3600))
	local m=$(((s % 3600) / 60))
	local sec=$((s % 60))
	if (( h > 0 )); then
		printf '%dh%02dm%02ds' "${h}" "${m}" "${sec}"
	elif (( m > 0 )); then
		printf '%dm%02ds' "${m}" "${sec}"
	else
		printf '%ds' "${sec}"
	fi
}

bar() {
	local done="$1" total="$2" width="${3:-28}"
	if (( total <= 0 )); then
		printf '[%*s]' "${width}" '' | tr ' ' '-'
		return
	fi
	if (( done > total )); then done="${total}"; fi
	local filled=$((done * width / total))
	local empty=$((width - filled))
	printf '['
	printf '%*s' "${filled}" '' | tr ' ' '#'
	printf '%*s' "${empty}" '' | tr ' ' '-'
	printf ']'
}

# diagnose_aws_log scans a tofu log for known error patterns,
# deduplicates terraform's repeated `╷ │ Error: ... ╵` blocks (one
# per failed resource — typically 9-30 near-identical copies that
# bury the actionable signal) and prints a compact summary on
# stderr. Returns 0 always — best-effort hint, never fatal.
diagnose_aws_log() {
	local log="$1"
	# Pull every "│ Error: ..." line, strip the terraform prefix +
	# request-IDs (which differ per attempt and would defeat sort -u),
	# then count + classify. We extract the api-error name and any
	# instance type / AZ / resource hint into one digestible line per
	# unique cause.
	local errors
	errors="$(grep -E '│ Error: |api error ' "${log}" 2>/dev/null \
		| sed -E 's/RequestID: [a-f0-9-]+, //g; s/operation error [^,]+, [^,]+, //g; s/^[[:space:]]*│[[:space:]]*//')"
	[[ -z "${errors}" ]] && return 0

	# Group by api-error name (everything after "api error " up to
	# the first colon). Falls back to the verbatim line for messages
	# that don't follow the AWS SDK pattern.
	local summary
	summary="$(printf '%s\n' "${errors}" \
		| awk '
			/api error / {
				match($0, /api error [^:]+/); name=substr($0,RSTART+10,RLENGTH-10);
				count[name]++; sample[name]=$0; next
			}
			/Error: / { count["other"]++; sample["other"]=$0 }
			END { for (k in count) printf "%dx %s\n%s\n---\n", count[k], k, sample[k] }
		' \
		| head -200)"

	[[ -z "${summary}" ]] && return 0

	# Extract distinct hint values (AZ, instance type, resource refs)
	# straight from the raw log so the recommendation is concrete.
	local az_hint type_hint resource_hint
	az_hint="$(grep -oE '(eu|us|ap|sa|ca|af|me)-[a-z]+-[0-9][a-z]?' "${log}" | sort -u | tr '\n' ',' | sed 's/,$//')"
	type_hint="$(grep -oE '\b[cmrtipx][0-9]+[a-z]*\.[0-9a-z]+xlarge\b' "${log}" | sort -u | tr '\n' ',' | sed 's/,$//')"
	resource_hint="$(grep -oE 'with aws_instance\.[a-z_]+\[[0-9]+\]' "${log}" \
		| sed 's/with aws_instance\.//' | sort -u | tr '\n' ',' | sed 's/,$//')"

	printf '%sDIAGNOSIS:%s\n' "${YELLOW}" "${NC}" >&2
	printf '%s\n' "${summary}" \
		| awk '/^[0-9]+x / { print "  • " $0 }' >&2
	printf '\n%sCONTEXT:%s' "${YELLOW}" "${NC}" >&2
	[[ -n "${type_hint}"     ]] && printf '\n  instance type(s): %s' "${type_hint}" >&2
	[[ -n "${az_hint}"       ]] && printf '\n  AZ(s) mentioned:  %s' "${az_hint}" >&2
	[[ -n "${resource_hint}" ]] && printf '\n  failed resources: %s' "${resource_hint}" >&2
	printf '\n\n%sNEXT:%s\n' "${YELLOW}" "${NC}" >&2

	# Pattern-specific remediation. We pick whichever applies first
	# so the most-likely fix is at the top of the list.
	if grep -q 'InsufficientInstanceCapacity' "${log}" 2>/dev/null; then
		printf '  • Capacity often returns within 5-15 min — simply rerun.\n' >&2
		printf '  • If recurrent: BENCH_AWS_INSTANCE_TYPE=c7i.4xlarge (or c6i.2xlarge) — different family/size usually has free capacity.\n' >&2
		printf '  • Or edit infra/aws/terraform.tfvars to a different AZ (eu-central-1b / 1c).\n' >&2
	fi
	if grep -q 'RequestLimitExceeded' "${log}" 2>/dev/null; then
		printf '  • Account-wide ec2:RunInstances throttle — wait 1-2 min and rerun. Lowering BENCH_AWS_FLEET_SIZE reduces the burst.\n' >&2
	fi
	if grep -qE 'VcpuLimitExceeded|InstanceLimitExceeded' "${log}" 2>/dev/null; then
		printf '  • EC2 vCPU / instance quota hit — file an AWS Support ticket; rerun alone will not help.\n' >&2
	fi
	if grep -qE 'UnauthorizedOperation|AccessDenied|InvalidClientTokenId|ExpiredToken' "${log}" 2>/dev/null; then
		printf '  • AWS auth failed — `aws sts get-caller-identity` to verify, then refresh credentials / SSO.\n' >&2
	fi
}

# pretty_log_tail filters noise out of a captured log and prints
# meaningful CONTEXT lines on stderr. Drops:
#   • `Still creating... [Nm…s]` / `Still destroying... [Nm…s]`
#     polling chatter
#   • All terraform error decoration (`╷ │ ... ╵` boxes) and Error
#     blocks themselves — diagnose_aws_log already summarised those
#     with counts and remediation, so the tail is for *context*
#     (which resources DID succeed before the wall) only.
#   • ANSI colour codes that confuse `head/tail` line counting.
#
# Falls back to plain `tail -15` if filtering left nothing.
pretty_log_tail() {
	local log="$1"
	local filtered
	filtered="$(sed -E 's/\x1b\[[0-9;]*[a-zA-Z]//g' "${log}" 2>/dev/null \
		| grep -Ev 'Still creating\.\.\.|Still destroying\.\.\.|^[[:space:]]*$|^╷|^╵|^│ ?$|^│ +Error:|^│ +operation error|^│ +api error|^│ +with aws_|^│ +on .*\.tf|^│ +[0-9]+: resource ' 2>/dev/null \
		| tail -15)"
	if [[ -n "${filtered}" ]]; then
		printf '%s\n' "${filtered}" >&2
	else
		# Final fallback: the log was 100% errors; show nothing
		# extra. The diagnosis already covered it.
		printf '  (log contained only error blocks — see DIAGNOSIS above)\n' >&2
	fi
}

run_logged() {
	local label="$1"
	local log="$2"
	shift 2
	local start
	start="$(date +%s)"
	printf '%s▶ %s%s %s\n' "${CYAN}" "${label}" "${NC}" "$(ts)"
	if "$@" >"${log}" 2>&1; then
		local end=$(( $(date +%s) - start ))
		printf '%s✓ %s%s (%s) log: %s\n' "${GREEN}" "${label}" "${NC}" "$(duration "${end}")" "${log}"
	else
		local rc=$?
		local end=$(( $(date +%s) - start ))
		printf '%s✗ %s failed%s after %s; log: %s\n\n' "${RED}" "${label}" "${NC}" "$(duration "${end}")" "${log}" >&2
		# Surface a structured diagnosis (counts + remediation) above
		# the raw log tail so the operator sees the actionable hint
		# first. Filter the polling spam and dedupe the repeated
		# Error blocks so the tail stays compact.
		diagnose_aws_log "${log}"
		printf '\n%sFiltered tail (last meaningful lines, polling + duplicate Error blocks suppressed):%s\n' "${YELLOW}" "${NC}" >&2
		pretty_log_tail "${log}"
		return "${rc}"
	fi
}

ssh_opts() {
	# Use `|` as the sed delimiter — the option list contains
	# `/dev/null` (UserKnownHostsFile), so the default `/` delimiter
	# would terminate the substitution mid-arg.
	# StrictHostKeyChecking=no + UserKnownHostsFile=/dev/null is the
	# correct posture for ephemeral EC2: AWS recycles public IPs
	# between runs, so the same address legitimately serves a new host
	# key every fleet — accept-new (the previous setting) only worked
	# for first-time IPs and started rejecting connections once an
	# operator's known_hosts had built up entries from earlier runs.
	sed 's|^ssh |ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=10 |'
}

# Single-source-of-truth for SSH options spliced into every readiness
# probe. Kept in sync with `ssh_opts()` above (sed inserts the same
# list between "ssh " and the rest of the command line for every
# remote invocation outside the readiness wait).
SSH_HARDENING_OPTS='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=10'

cleanup() {
	local rc=$?
	if (( ${#pids[@]} > 0 )); then
		for pid in "${pids[@]}"; do
			kill "${pid}" >/dev/null 2>&1 || true
		done
	fi
	if [[ -s "${REPORT_PATH}" ]]; then
		printf '%s✓ Report saved:%s %s\n' "${GREEN}" "${NC}" "${REPORT_PATH}"
	fi
	if [[ "${DESTROY_AFTER}" == "1" || "${DESTROY_AFTER}" == "true" ]]; then
		run_logged "Destroy AWS infrastructure" "${LOG_DIR}/tofu-destroy.log" \
			bash -lc "cd '${REPO_ROOT}/${AWS_TOFU_DIR}' && ${TOFU_BIN} destroy -auto-approve" || {
				local destroy_rc=$?
				if (( rc == 0 )); then rc="${destroy_rc}"; fi
			}
	else
		printf '%s! cleanup skipped%s BENCH_AWS_DESTROY_AFTER=%s\n' "${YELLOW}" "${NC}" "${DESTROY_AFTER}"
	fi
	exit "${rc}"
}
trap cleanup EXIT

printf '%sGateway Benchmarks AWS clean cluster fleet%s\n' "${CYAN}" "${NC}"
printf '  run-id: %s\n  clean clusters: %s x 3 EC2 (%s)\n  parallel/loadgen: %s\n  logs: %s\n' \
	"${RUN_ID}" "${FLEET_SIZE}" "${INSTANCE_TYPE}" "${PARALLEL}" "${LOG_DIR}"
if [[ -n "${S3_REPORT_URL}" ]]; then
	printf '  %sreport URL (after success):%s %s\n' "${CYAN}" "${NC}" "${S3_REPORT_URL}"
	printf '    (safe to schedule a Slack message now — same URL is printed again at the end)\n'
fi
printf '\n'

if [[ ! -f "${AWS_TOFU_DIR}/terraform.tfvars" ]]; then
	printf '%s✗ infra/aws/terraform.tfvars is missing.%s\n' "${RED}" "${NC}" >&2
	printf '  Copy infra/aws/terraform.tfvars.example, edit ssh_key_name + allowed_ssh_cidrs, then re-run.\n' >&2
	exit 2
fi

# Preflight: wallarm gateway requires WALLARM_IMAGE to be exported. The
# compose file uses ${WALLARM_IMAGE:?...} so an empty value silently
# fails docker compose up on the remote host with the stderr lost
# through the ssh pipeline. Catch this locally instead of burning a
# whole AWS run on it.
case ",${GATEWAYS}," in
	*,wallarm,*|*,all,*)
		if [[ -z "${WALLARM_IMAGE:-}" ]]; then
			printf '%s✗ WALLARM_IMAGE is required when gateways include "wallarm" or "all".%s\n' "${RED}" "${NC}" >&2
			printf '  Build the Wallarm API Gateway and export the tag, e.g.:\n' >&2
			printf "    export WALLARM_IMAGE='wallarm/api-gateway:main-<sha>'\n" >&2
			printf '  Or exclude wallarm from this run: BENCH_AWS_FULL_GATEWAYS=nginx,kong,apisix,traefik,tyk,envoy\n' >&2
			exit 2
		fi
		printf '%s✓ WALLARM_IMAGE=%s%s\n' "${GREEN}" "${WALLARM_IMAGE}" "${NC}"
		;;
esac

run_logged "Init AWS terraform" "${LOG_DIR}/tofu-init.log" \
	bash -lc "cd '${REPO_ROOT}/${AWS_TOFU_DIR}' && ${TOFU_BIN} init"

run_logged "Build Linux/amd64 bench binary" "${LOG_DIR}/build-linux-amd64.log" \
	bash -lc "mkdir -p orchestrator/bin && cd orchestrator && GOOS=linux GOARCH=amd64 go build -trimpath -ldflags='-s -w' -o '../${REMOTE_BIN}' ."

run_logged "Create AWS clean cluster fleet" "${LOG_DIR}/tofu-apply.log" \
	bash -lc "cd '${REPO_ROOT}/${AWS_TOFU_DIR}' && ${TOFU_BIN} apply -auto-approve -var 'instance_type=${INSTANCE_TYPE}' -var 'cluster_count=${FLEET_SIZE}' -var 'runner_count=0'"

clusters_json="$(cd "${AWS_TOFU_DIR}" && "${TOFU_BIN}" output -json cluster_shards)"
runner_count="$(printf '%s' "${clusters_json}" | jq 'length')"
if [[ "${runner_count}" -eq 0 ]]; then
	printf '%s✗ no clean clusters created%s\n' "${RED}" "${NC}" >&2
	exit 2
fi
local_key="$(printf '%s' "${clusters_json}" | jq -r '.[0].ssh_loadgen' | awk '{for (i=1;i<=NF;i++) if ($i=="-i") {print $(i+1); exit}}')"
if [[ ! -f "${local_key/#\~/${HOME}}" ]]; then
	printf '%s✗ SSH private key not found:%s %s\n' "${RED}" "${NC}" "${local_key}" >&2
	exit 2
fi
local_key="${local_key/#\~/${HOME}}"

total_cells="$("${ORCH_BIN}" --repo-root "${REPO_ROOT}" --run-id "${RUN_ID}" run \
	--matrix canonical --gateways "${GATEWAYS}" --loads "${LOADS}" --reps "${REPS}" --dry-run \
	| awk '/total cells:/ {print $3}')"
total_cells="${total_cells:-364}"

printf '%s▶ Wait for cloud-init and Docker on %s clean clusters%s %s\n' "${CYAN}" "${runner_count}" "${NC}" "$(ts)"
ready_start="$(date +%s)"
ready_log="${LOG_DIR}/aws-readiness.log"

# Drive the fleet readiness wait through the Go orchestrator's
# `bench aws-readiness` subcommand (orchestrator/cmd/aws_readiness.go).
# All hosts are probed concurrently via goroutines, so the wall-clock
# wait collapses from O(N_clusters × per_host_time) to O(slowest_host).
# JSON input is constructed inline from `tofu output -json
# cluster_shards` plus the shared SSH-hardening options so the Go
# helper sees exactly the same command lines the bash code used to
# build via the `ssh_opts()` sed-rewrite.
readiness_input="$(jq -n \
	--argjson clusters "${clusters_json}" \
	--arg     opts     "${SSH_HARDENING_OPTS}" \
	'{
		ssh_options: $opts,
		clusters: [
			range(0; ($clusters | length)) as $i
			| $clusters[$i]
			| {
				index:       $i,
				loadgen_ssh: .ssh_loadgen,
				gateway_ssh: .ssh_gateway,
				backend_ssh: .ssh_backend
			}
		]
	}')"
if ! printf '%s' "${readiness_input}" \
	| "${ORCH_BIN}" aws-readiness --log "${ready_log}" --timeout 15m --poll-interval 10s; then
	printf '\n%s✗ AWS readiness failed%s (see %s for per-attempt SSH output)\n' \
		"${RED}" "${NC}" "${ready_log}" >&2
	exit 1
fi
printf '%s✓ AWS hosts ready%s (%s)\n' "${GREEN}" "${NC}" "$(duration "$(( $(date +%s) - ready_start ))")"

printf '%s▶ Sync checkout to %s clean clusters%s %s\n' "${CYAN}" "${runner_count}" "${NC}" "$(ts)"
sync_start="$(date +%s)"

# Drive the per-cluster sync through the Go orchestrator's
# `bench aws-sync` subcommand (orchestrator/cmd/aws_sync.go). The
# helper fans out clusters via goroutines (capped by --concurrency to
# keep the operator's uplink from saturating) and uses MaxAttempts=2
# to absorb a single network blip on the tar/ssh pipe without burning
# the whole timeout budget on a permanently-broken cluster. Per-
# cluster output still lands in ${LOG_DIR}/sync-NN.log — same shape
# as the previous bash implementation, easier diff during postmortem.
sync_input="$(jq -n \
	--argjson clusters  "${clusters_json}" \
	--arg     opts      "${SSH_HARDENING_OPTS}" \
	--arg     repo_root "${REPO_ROOT}" \
	--arg     key_path  "${local_key}" \
	'{
		ssh_options:  $opts,
		repo_root:    $repo_root,
		key_path:     $key_path,
		remote_path:  "/opt/gateway-benchmarks",
		tar_excludes: [".git", "reports"],
		clusters: [
			range(0; ($clusters | length)) as $i
			| $clusters[$i]
			| {
				index:              $i,
				loadgen_ssh:        .ssh_loadgen,
				gateway_ssh:        .ssh_gateway,
				gateway_private_ip: .gateway_private_ip
			}
		]
	}')"
if ! printf '%s' "${sync_input}" \
	| "${ORCH_BIN}" aws-sync --log-dir "${LOG_DIR}" \
		--concurrency 6 --max-attempts 2 --timeout 10m --retry-interval 5s; then
	printf '\n%s✗ Sync checkout failed%s (per-cluster logs in %s/sync-NN.log)\n' \
		"${RED}" "${NC}" "${LOG_DIR}" >&2
	exit 1
fi
printf '%s✓ Sync checkout%s (%s)\n' "${GREEN}" "${NC}" "$(duration "$(( $(date +%s) - sync_start ))")"

printf '%s▶ Run load tests across %d physical runners%s %s\n' "${CYAN}" "${runner_count}" "${NC}" "$(ts)"
printf '  matrix: %s cells · gateways=%s · loads=%s · reps=%s\n' "${total_cells}" "${GATEWAYS}" "${LOADS}" "${REPS}"
printf '  shard logs: %s/%s-shard-*.remote.log\n' "${LOG_DIR}" "${RUN_ID}"
load_start="$(date +%s)"
for i in $(seq 0 $((runner_count - 1))); do
	ssh_cmd="$(printf '%s' "${clusters_json}" | jq -r ".[$i].ssh_loadgen" | ssh_opts)"
	gateway_private_ip="$(printf '%s' "${clusters_json}" | jq -r ".[$i].gateway_private_ip")"
	backend_private_ip="$(printf '%s' "${clusters_json}" | jq -r ".[$i].backend_private_ip")"
	shard_id="$(printf '%02d' "${i}")"
	shard_run_id="${RUN_ID}-shard-${shard_id}"
	remote_env=""
	if [[ -n "${WALLARM_IMAGE:-}" ]]; then remote_env+="WALLARM_IMAGE='${WALLARM_IMAGE}' "; fi
	if [[ -n "${GATEWAY_IMAGE:-}" ]]; then remote_env+="GATEWAY_IMAGE='${GATEWAY_IMAGE}' "; fi
	
	remote_cmd="cd /opt/gateway-benchmarks && chmod +x ${REMOTE_BIN} scripts/aws-clean-cell.sh && ${remote_env}BENCH_CELL_RUNNER=scripts/aws-clean-cell.sh AWS_GATEWAY_SSH='ssh -i ~/.ssh/gwb_cluster_key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=10 ubuntu@${gateway_private_ip}' AWS_GATEWAY_PRIVATE_IP='${gateway_private_ip}' AWS_BACKEND_PRIVATE_IP='${backend_private_ip}' ./${REMOTE_BIN} --repo-root /opt/gateway-benchmarks --run-id ${shard_run_id} run --matrix canonical --gateways '${GATEWAYS}' --loads '${LOADS}' --seed '${SEED}' --reps '${REPS}' --mode aws --shard-index ${i} --shard-count ${runner_count} --parallel '${PARALLEL}' --skip-parity --disable-native-stats --progress --progress-interval '${PROGRESS_INTERVAL}' --allow-failed-cells --notes \"${NOTES} shard $((i + 1))/${runner_count}\""
	(
		rc=0
		for attempt in 1 2; do
			${ssh_cmd} "${remote_cmd}" && exit 0
			rc=$?
			echo "ssh/remote attempt ${attempt} failed with rc=${rc}"
			if [[ "${attempt}" == "1" ]]; then sleep 30; fi
		done
		exit "${rc}"
	) >"${LOG_DIR}/${shard_run_id}.remote.log" 2>&1 &
	pids+=("$!")
done
printf '%s✓ Load test workers started%s (%d shards)\n' "${GREEN}" "${NC}" "${runner_count}"

while :; do
	alive=0
	for pid in "${pids[@]}"; do
		if kill -0 "${pid}" 2>/dev/null; then alive=1; fi
	done
	done_cells="$( (grep -h ' done |' "${LOG_DIR}"/"${RUN_ID}"-shard-*.remote.log 2>/dev/null || true) | wc -l | tr -d ' ')"
	elapsed=$(( $(date +%s) - load_start ))
	eta="estimating"
	if [[ "${done_cells}" =~ ^[0-9]+$ ]] && (( done_cells > 0 )); then
		remaining=$((total_cells - done_cells))
		if (( remaining < 0 )); then remaining=0; fi
		eta="$(duration "$((elapsed * remaining / done_cells))")"
	fi
	printf '\r\033[2K  %s %s/%s cells | elapsed %s | eta %s' \
		"$(bar "${done_cells:-0}" "${total_cells}")" "${done_cells:-0}" "${total_cells}" "$(duration "${elapsed}")" "${eta}"
	if (( alive == 0 )); then break; fi
	sleep 30
done
printf '\n'

load_failed=0
for pid in "${pids[@]}"; do
	if ! wait "${pid}"; then load_failed=1; fi
done
pids=()
if (( load_failed != 0 )); then
	printf '%s✗ one or more shards failed%s logs: %s/%s-shard-*.remote.log\n' "${RED}" "${NC}" "${LOG_DIR}" "${RUN_ID}" >&2
	exit 1
fi
printf '%s✓ Load tests complete%s (%s)\n' "${GREEN}" "${NC}" "$(duration "$(( $(date +%s) - load_start ))")"

printf '%s▶ Fetch shard reports%s %s\n' "${CYAN}" "${NC}" "$(ts)"
fetch_start="$(date +%s)"

# Drive the per-shard fetch through the Go orchestrator's
# `bench aws-fetch` subcommand (orchestrator/cmd/aws_fetch.go). Each
# shard runs `ssh loadgen 'tar -czf - <shard>' | tar -xzf -` in its
# own goroutine; concurrency is capped so the operator's downstream
# bandwidth and local disk I/O don't saturate on a 22-cluster sweep.
fetch_input="$(jq -n \
	--argjson clusters "${clusters_json}" \
	--arg     opts     "${SSH_HARDENING_OPTS}" \
	--arg     run_id   "${RUN_ID}" \
	'{
		ssh_options: $opts,
		remote_dir:  "/opt/gateway-benchmarks/reports",
		local_dir:   "reports",
		clusters: [
			range(0; ($clusters | length)) as $i
			| $clusters[$i]
			| {
				index:       $i,
				loadgen_ssh: .ssh_loadgen,
				shard_id:    ($run_id + "-shard-" + (if $i < 10 then "0" + ($i|tostring) else ($i|tostring) end))
			}
		]
	}')"
if ! printf '%s' "${fetch_input}" \
	| "${ORCH_BIN}" aws-fetch --log-dir "${LOG_DIR}" \
		--concurrency 6 --max-attempts 2 --timeout 10m --retry-interval 5s; then
	printf '\n%s✗ Fetch shard reports failed%s (per-shard logs in %s/fetch-NN.log)\n' \
		"${RED}" "${NC}" "${LOG_DIR}" >&2
	exit 1
fi
printf '%s✓ Fetch shard reports%s (%s)\n' "${GREEN}" "${NC}" "$(duration "$(( $(date +%s) - fetch_start ))")"

# Build the combined comma-separated run-id list the report renderer
# consumes (`bench report --combined a,b,c`). Doing this in bash
# keeps the contract with downstream steps unchanged — aws-fetch only
# owns the network transfer.
combined=""
for i in $(seq 0 $((runner_count - 1))); do
	shard_run_id="${RUN_ID}-shard-$(printf '%02d' "${i}")"
	if [[ -z "${combined}" ]]; then combined="${shard_run_id}"; else combined="${combined},${shard_run_id}"; fi
done

missing_jsonl=0
for run in ${combined//,/ }; do
	if [[ ! -s "reports/${run}/cells.jsonl" ]]; then
		missing_jsonl=1
		printf '%s✗ shard report is incomplete:%s reports/%s/cells.jsonl is missing\n' "${RED}" "${NC}" "${run}" >&2
		shard_log="${LOG_DIR}/${run}.remote.log"
		if [[ -f "${shard_log}" ]]; then
			printf '%sShard summary:%s\n' "${YELLOW}" "${NC}" >&2
			tail -80 "${shard_log}" >&2 || true
		fi
	fi
done
if (( missing_jsonl != 0 )); then
	printf '%s✗ cannot render HTML: one or more shards produced no aggregate data%s\n' "${RED}" "${NC}" >&2
	exit 1
fi

mkdir -p "${COPY_DIR}"
report_cmd=("${ORCH_BIN}" --repo-root "${REPO_ROOT}" report --combined "${combined}" \
	--unstable-threshold "0.10" \
	--output "${REPORT_PATH}" --title "API Gateway Benchmark" \
	--env "AWS · ${runner_count} cluster(s) · ${INSTANCE_TYPE}${PARALLEL_SUFFIX}")
if [[ -n "${REPORT_LOGO}" ]]; then
	report_cmd+=(--logo "${REPORT_LOGO}")
fi
run_logged "Render combined HTML report" "${LOG_DIR}/render-report.log" "${report_cmd[@]}"

printf '%s✓ Report ready:%s %s\n' "${GREEN}" "${NC}" "${REPORT_PATH}"

# Optional: publish the rendered HTML report to S3 with public-read
# ACL so a shareable link can be sent to colleagues without giving
# them console access to the bucket. Opt-in via
# BENCH_AWS_REPORT_S3_BUCKET; pass region + key prefix overrides if
# the bucket lives outside eu-central-1 or you want a non-default
# layout. Failure here is non-fatal — the local report is already
# saved.
if [[ -n "${S3_REPORT_URL}" ]] && [[ -s "${REPORT_PATH}" ]]; then
	printf '%s▶ Publish report to s3://%s/%s%s %s\n' "${CYAN}" "${BENCH_AWS_REPORT_S3_BUCKET}" "${S3_REPORT_KEY}" "${NC}" "$(ts)"
	if aws s3 cp "${REPORT_PATH}" "s3://${BENCH_AWS_REPORT_S3_BUCKET}/${S3_REPORT_KEY}" \
		--acl public-read \
		--content-type 'text/html; charset=utf-8' \
		--cache-control 'public, max-age=3600' \
		--region "${S3_REPORT_REGION}" \
		>"${LOG_DIR}/s3-publish.log" 2>&1; then
		printf '%s✓ Public report URL:%s %s\n' "${GREEN}" "${NC}" "${S3_REPORT_URL}"
	else
		s3_rc=$?
		printf '%s! S3 publish failed (rc=%d) — local report is still at %s%s\n' \
			"${YELLOW}" "${s3_rc}" "${REPORT_PATH}" "${NC}" >&2
		printf '  log: %s\n' "${LOG_DIR}/s3-publish.log" >&2
		tail -20 "${LOG_DIR}/s3-publish.log" >&2 || true
	fi
fi

printf '%sNext:%s destroying AWS infrastructure (report is already local)\n' "${YELLOW}" "${NC}"
if [[ "${OPEN_REPORT}" == "1" || "${OPEN_REPORT}" == "true" ]]; then
	open "${REPORT_PATH}"
fi
