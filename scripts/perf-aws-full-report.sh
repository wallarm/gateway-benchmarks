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
		printf '%s✗ %s failed%s after %s; log: %s\n' "${RED}" "${label}" "${NC}" "$(duration "${end}")" "${log}" >&2
		printf '%sLast log lines:%s\n' "${YELLOW}" "${NC}" >&2
		tail -80 "${log}" >&2 || true
		return "${rc}"
	fi
}

ssh_opts() {
	sed 's/^ssh /ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=120 /'
}

wait_remote_ready() {
	local ssh_cmd="$1"
	local label="$2"
	local log="$3"
	local deadline=$(( $(date +%s) + 900 ))
	local attempt=0
	local check='docker info >/dev/null 2>&1'
	if [[ "${label}" == *" backend" ]]; then
		check='docker info >/dev/null 2>&1 && curl -fsS -o /dev/null --max-time 2 http://127.0.0.1:8080/status/200'
	fi
	while (( $(date +%s) < deadline )); do
		attempt=$((attempt + 1))
		echo "[$(ts)] ${label}: readiness attempt ${attempt}" >>"${log}"
		if ${ssh_cmd} "${check}" >>"${log}" 2>&1; then
			echo "[$(ts)] ${label}: ready" >>"${log}"
			return 0
		fi
		sleep 10
	done
	echo "${label}: SSH/service readiness did not complete within 15m" >>"${log}"
	return 1
}

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
printf '  run-id: %s\n  clean clusters: %s x 3 EC2 (%s)\n  parallel/loadgen: %s\n  logs: %s\n\n' \
	"${RUN_ID}" "${FLEET_SIZE}" "${INSTANCE_TYPE}" "${PARALLEL}" "${LOG_DIR}"

if [[ ! -f "${AWS_TOFU_DIR}/terraform.tfvars" ]]; then
	printf '%s✗ infra/aws/terraform.tfvars is missing.%s\n' "${RED}" "${NC}" >&2
	printf '  Copy infra/aws/terraform.tfvars.example, edit ssh_key_name + allowed_ssh_cidrs, then re-run.\n' >&2
	exit 2
fi

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
for i in $(seq 0 $((runner_count - 1))); do
	loadgen_ssh="$(printf '%s' "${clusters_json}" | jq -r ".[$i].ssh_loadgen" | ssh_opts)"
	gateway_ssh="$(printf '%s' "${clusters_json}" | jq -r ".[$i].ssh_gateway" | ssh_opts)"
	backend_ssh="$(printf '%s' "${clusters_json}" | jq -r ".[$i].ssh_backend" | ssh_opts)"
	log="${LOG_DIR}/ready-$(printf '%02d' "${i}").log"
	printf '  cluster %d/%d readiness log: %s\n' "$((i + 1))" "${runner_count}" "${log}"
	for role_cmd in "loadgen:${loadgen_ssh}" "gateway:${gateway_ssh}" "backend:${backend_ssh}"; do
		role="${role_cmd%%:*}"
		ssh_cmd="${role_cmd#*:}"
		role_start="$(date +%s)"
		printf '    waiting for %-7s ... ' "${role}"
		if ! wait_remote_ready "${ssh_cmd}" "cluster $((i + 1)) ${role}" "${log}"; then
			printf 'failed\n'
			printf '\n%s✗ readiness check failed for cluster %d%s log: %s\n' "${RED}" "$((i + 1))" "${NC}" "${log}" >&2
			tail -80 "${log}" >&2 || true
			exit 1
		fi
		printf '%sready%s (%s)\n' "${GREEN}" "${NC}" "$(duration "$(( $(date +%s) - role_start ))")"
	done
done
printf '%s✓ AWS hosts ready%s (%s)\n' "${GREEN}" "${NC}" "$(duration "$(( $(date +%s) - ready_start ))")"

printf '%s▶ Sync checkout to %s clean clusters%s %s\n' "${CYAN}" "${runner_count}" "${NC}" "$(ts)"
sync_start="$(date +%s)"
for i in $(seq 0 $((runner_count - 1))); do
	loadgen_ssh="$(printf '%s' "${clusters_json}" | jq -r ".[$i].ssh_loadgen" | ssh_opts)"
	gateway_ssh="$(printf '%s' "${clusters_json}" | jq -r ".[$i].ssh_gateway" | ssh_opts)"
	log="${LOG_DIR}/sync-$(printf '%02d' "${i}").log"
	printf '  cluster %d/%d sync log: %s\n' "$((i + 1))" "${runner_count}" "${log}"
	step_start="$(date +%s)"
	printf '    sync loadgen ... '
	if ! (COPYFILE_DISABLE=1 tar --no-xattrs --exclude='.git' --exclude='reports' -czf - . \
		| ${loadgen_ssh} 'sudo rm -rf /opt/gateway-benchmarks && sudo mkdir -p /opt/gateway-benchmarks && sudo tar --warning=no-unknown-keyword -xzf - -C /opt/gateway-benchmarks && sudo chown -R ubuntu:ubuntu /opt/gateway-benchmarks') >"${log}" 2>&1; then
		printf 'failed\n%s✗ sync loadgen %d failed%s log: %s\n' "${RED}" "$((i + 1))" "${NC}" "${log}" >&2
		tail -80 "${log}" >&2 || true
		exit 1
	fi
	printf '%sdone%s (%s)\n' "${GREEN}" "${NC}" "$(duration "$(( $(date +%s) - step_start ))")"
	step_start="$(date +%s)"
	printf '    sync gateway ... '
	if ! (COPYFILE_DISABLE=1 tar --no-xattrs --exclude='.git' --exclude='reports' -czf - . \
		| ${gateway_ssh} 'sudo rm -rf /opt/gateway-benchmarks && sudo mkdir -p /opt/gateway-benchmarks && sudo tar --warning=no-unknown-keyword -xzf - -C /opt/gateway-benchmarks && sudo chown -R ubuntu:ubuntu /opt/gateway-benchmarks') >>"${log}" 2>&1; then
		printf 'failed\n%s✗ sync gateway %d failed%s log: %s\n' "${RED}" "$((i + 1))" "${NC}" "${log}" >&2
		tail -80 "${log}" >&2 || true
		exit 1
	fi
	printf '%sdone%s (%s)\n' "${GREEN}" "${NC}" "$(duration "$(( $(date +%s) - step_start ))")"
	step_start="$(date +%s)"
	printf '    install gateway SSH key on loadgen ... '
	${loadgen_ssh} "mkdir -p ~/.ssh && cat > ~/.ssh/gwb_cluster_key && chmod 600 ~/.ssh/gwb_cluster_key" < "${local_key}" >>"${log}" 2>&1
	printf '%sdone%s (%s)\n' "${GREEN}" "${NC}" "$(duration "$(( $(date +%s) - step_start ))")"
	step_start="$(date +%s)"
	gateway_private_ip="$(printf '%s' "${clusters_json}" | jq -r ".[$i].gateway_private_ip")"
	printf '    preflight loadgen -> gateway SSH ... '
	if ! ${loadgen_ssh} "ssh -i ~/.ssh/gwb_cluster_key -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=10 ubuntu@${gateway_private_ip} true" >>"${log}" 2>&1; then
		printf 'failed\n%s✗ preflight loadgen -> gateway SSH failed for cluster %d%s log: %s\n' "${RED}" "$((i + 1))" "${NC}" "${log}" >&2
		tail -80 "${log}" >&2 || true
		exit 1
	fi
	printf '%sdone%s (%s)\n' "${GREEN}" "${NC}" "$(duration "$(( $(date +%s) - step_start ))")"
done
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
	
	remote_cmd="cd /opt/gateway-benchmarks && chmod +x ${REMOTE_BIN} scripts/aws-clean-cell.sh && ${remote_env}BENCH_CELL_RUNNER=scripts/aws-clean-cell.sh AWS_GATEWAY_SSH='ssh -i ~/.ssh/gwb_cluster_key -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=120 ubuntu@${gateway_private_ip}' AWS_GATEWAY_PRIVATE_IP='${gateway_private_ip}' AWS_BACKEND_PRIVATE_IP='${backend_private_ip}' ./${REMOTE_BIN} --repo-root /opt/gateway-benchmarks --run-id ${shard_run_id} run --matrix canonical --gateways '${GATEWAYS}' --loads '${LOADS}' --seed '${SEED}' --reps '${REPS}' --mode aws --shard-index ${i} --shard-count ${runner_count} --parallel '${PARALLEL}' --skip-parity --disable-native-stats --progress --progress-interval '${PROGRESS_INTERVAL}' --allow-failed-cells --notes \"${NOTES} shard $((i + 1))/${runner_count}\""
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
combined=""
for i in $(seq 0 $((runner_count - 1))); do
	ssh_cmd="$(printf '%s' "${clusters_json}" | jq -r ".[$i].ssh_loadgen" | ssh_opts)"
	shard_id="$(printf '%02d' "${i}")"
	shard_run_id="${RUN_ID}-shard-${shard_id}"
	log="${LOG_DIR}/fetch-${shard_id}.log"
	printf '  %s %d/%d\r' "$(bar "$((i + 1))" "${runner_count}")" "$((i + 1))" "${runner_count}"
	rm -rf "reports/${shard_run_id}"
	mkdir -p reports
	if ! (${ssh_cmd} "cd /opt/gateway-benchmarks/reports && tar -czf - ${shard_run_id}" | tar -C reports -xzf -) >"${log}" 2>&1; then
		printf '\n%s✗ fetch shard %s failed%s log: %s\n' "${RED}" "${shard_id}" "${NC}" "${log}" >&2
		tail -80 "${log}" >&2 || true
		exit 1
	fi
	if [[ -z "${combined}" ]]; then combined="${shard_run_id}"; else combined="${combined},${shard_run_id}"; fi
done
printf '\n%s✓ Fetch shard reports%s (%s)\n' "${GREEN}" "${NC}" "$(duration "$(( $(date +%s) - fetch_start ))")"

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
printf '%sNext:%s destroying AWS infrastructure (report is already local)\n' "${YELLOW}" "${NC}"
if [[ "${OPEN_REPORT}" == "1" || "${OPEN_REPORT}" == "true" ]]; then
	open "${REPORT_PATH}"
fi
