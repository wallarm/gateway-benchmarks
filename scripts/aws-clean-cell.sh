#!/usr/bin/env bash
# Run one clean AWS cell from a loadgen host:
#   loadgen EC2 -> gateway EC2 -> backend EC2

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

GATEWAY=""
POLICY=""
SCENARIO=""
LOAD=""
OUTPUT=""
SEED="${BENCH_RUN_SEED:-42}"
STREAM=0

while (( $# > 0 )); do
	case "$1" in
		--gateway) GATEWAY="$2"; shift 2;;
		--policy) POLICY="$2"; shift 2;;
		--scenario) SCENARIO="$2"; shift 2;;
		--load) LOAD="$2"; shift 2;;
		--output) OUTPUT="$2"; shift 2;;
		--seed) SEED="$2"; shift 2;;
		--stream) STREAM=1; shift;;
		--keep-up) shift;;
		*) echo "unknown arg: $1" >&2; exit 2;;
	esac
done

[[ -n "${GATEWAY}" && -n "${POLICY}" && -n "${SCENARIO}" && -n "${LOAD}" ]] || {
	echo "--gateway/--policy/--scenario/--load are required" >&2
	exit 2
}

: "${AWS_GATEWAY_SSH:?AWS_GATEWAY_SSH is required}"
: "${AWS_GATEWAY_PRIVATE_IP:?AWS_GATEWAY_PRIVATE_IP is required}"
: "${AWS_BACKEND_PRIVATE_IP:?AWS_BACKEND_PRIVATE_IP is required}"

RUN_ID="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
if [[ -z "${OUTPUT}" ]]; then
	OUTPUT="reports/${RUN_ID}/raw/${GATEWAY}/${POLICY}__${LOAD}__${SCENARIO}"
fi
LOGS_DIR="${OUTPUT}/logs"
mkdir -p "${OUTPUT}" "${LOGS_DIR}"

K6_IMAGE="${K6_IMAGE:-grafana/k6:1.7.1@sha256:4fd3a694926b064d3491d9b02b01cde886583c4931f1223816e3d9a7bdfa7e0f}"
GATEWAY_TARGET="http://${AWS_GATEWAY_PRIVATE_IP}:9080"
GATEWAY_TARGET_HTTPS="https://${AWS_GATEWAY_PRIVATE_IP}:9443"
PROJECT="gwb-${RUN_ID}-${GATEWAY}"
PROJECT="${PROJECT//[^a-zA-Z0-9_-]/-}"
PROJECT="${PROJECT,,}"
PREFIX="${PROJECT}"
REMOTE_OUT="/tmp/${PROJECT}-${POLICY}-${LOAD}-${SCENARIO}"
REMOTE_OUT="${REMOTE_OUT//[^a-zA-Z0-9_\/.-]/-}"
OVERRIDE="/tmp/${PROJECT}-external-backend.yaml"
GATEWAY_DEPENDS_ON="[]"
case "${GATEWAY}" in
	tyk)
		GATEWAY_DEPENDS_ON="[tyk-redis, jwks-server]"
		;;
	apisix)
		GATEWAY_DEPENDS_ON="[oidc-server]"
		;;
esac

ssh_gateway() {
	local attempt rc
	rc=0
	for attempt in 1 2 3; do
		${AWS_GATEWAY_SSH} "$@" && return 0
		rc=$?
		printf '[%s] gateway ssh attempt %d failed rc=%d phase=%s\n' \
			"$(date -u +%H:%M:%SZ)" "${attempt}" "${rc}" "${PHASE}" >&2
		sleep 5
	done
	return "${rc}"
}

PHASE="init"
heartbeat() {
	while :; do
		printf '[%s] aws-clean-cell alive phase=%s cell=%s/%s/%s/%s\n' \
			"$(date -u +%H:%M:%SZ)" "${PHASE}" "${GATEWAY}" "${POLICY}" "${SCENARIO}" "${LOAD}" >&2
		sleep 20
	done
}
heartbeat &
HEARTBEAT_PID=$!

cleanup() {
	set +e
	kill "${HEARTBEAT_PID}" >/dev/null 2>&1 || true
	ssh_gateway "cd /opt/gateway-benchmarks; env_file='gateways/${GATEWAY}/${POLICY}/.env'; env_args=''; if [ -f \"\${env_file}\" ]; then env_args=\"--env-file \${env_file}\"; fi; GATEWAY_IMAGE='${GATEWAY_IMAGE:-}' WALLARM_IMAGE='${WALLARM_IMAGE:-}' BENCH_COMPOSE_PROJECT='${PROJECT}' BENCH_CONTAINER_PREFIX='${PREFIX}' docker compose -p '${PROJECT}' \${env_args} -f gateways/${GATEWAY}/docker-compose.yaml -f '${OVERRIDE}' logs --no-color > '${REMOTE_OUT}/compose.log' 2>&1 || true; GATEWAY_IMAGE='${GATEWAY_IMAGE:-}' WALLARM_IMAGE='${WALLARM_IMAGE:-}' BENCH_COMPOSE_PROJECT='${PROJECT}' BENCH_CONTAINER_PREFIX='${PREFIX}' docker compose -p '${PROJECT}' \${env_args} -f gateways/${GATEWAY}/docker-compose.yaml -f '${OVERRIDE}' down --remove-orphans -v >/dev/null 2>&1 || true"
	ssh_gateway "rm -f '${OVERRIDE}'" >/dev/null 2>&1 || true
}
trap cleanup EXIT

feature_missing="gateways/${GATEWAY}/${POLICY}/FEATURE-MISSING"
if [[ -f "${feature_missing}" ]]; then
	reason="$(sed -n '1p' "${feature_missing}" 2>/dev/null || true)"
	jq -cn --arg gateway "${GATEWAY}" --arg policy "${POLICY}" --arg scenario "${SCENARIO}" \
		--arg load "${LOAD}" --arg run_id "${RUN_ID}" --arg reason "${reason}" \
		'{gateway:$gateway,policy:$policy,scenario:$scenario,load:$load,run_id:$run_id,status:"EXCLUDED",reason:"FEATURE-MISSING",details:$reason}' \
		> "${OUTPUT}/excluded.json"
	exit 0
fi

PHASE="gateway-compose-up"
ssh_gateway "mkdir -p '${REMOTE_OUT}' && printf '%s\n' \
  'services:' \
  '  backend:' \
  '    profiles: [disabled-clean-backend]' \
  '  gateway:' \
  '    depends_on: !reset ${GATEWAY_DEPENDS_ON}' \
  '    extra_hosts:' \
  '      - \"backend:${AWS_BACKEND_PRIVATE_IP}\"' \
  > '${OVERRIDE}';
cd /opt/gateway-benchmarks;
env_file='gateways/${GATEWAY}/${POLICY}/.env';
env_args='';
if [ -f \"\${env_file}\" ]; then env_args=\"--env-file \${env_file}\"; fi;
BENCH_COMPOSE_PROJECT='${PROJECT}' BENCH_CONTAINER_PREFIX='${PREFIX}' GATEWAY_IMAGE='${GATEWAY_IMAGE:-}' WALLARM_IMAGE='${WALLARM_IMAGE:-}' GATEWAY_PROFILE='${POLICY}' GATEWAY_HTTP_PORT=9080 GATEWAY_HTTPS_PORT=9443 GATEWAY_ADMIN_PORT=9081 GATEWAY_ENVOY_ADMIN_PORT=9901 docker compose -p '${PROJECT}' \${env_args} -f gateways/${GATEWAY}/docker-compose.yaml -f '${OVERRIDE}' down --remove-orphans -v >/dev/null 2>&1 || true;
BENCH_COMPOSE_PROJECT='${PROJECT}' BENCH_CONTAINER_PREFIX='${PREFIX}' GATEWAY_IMAGE='${GATEWAY_IMAGE:-}' WALLARM_IMAGE='${WALLARM_IMAGE:-}' GATEWAY_PROFILE='${POLICY}' GATEWAY_HTTP_PORT=9080 GATEWAY_HTTPS_PORT=9443 GATEWAY_ADMIN_PORT=9081 GATEWAY_ENVOY_ADMIN_PORT=9901 docker compose -p '${PROJECT}' \${env_args} -f gateways/${GATEWAY}/docker-compose.yaml -f '${OVERRIDE}' up -d;
for i in \$(seq 1 90); do
  if curl -fsS -o /dev/null --max-time 2 http://localhost:9080/ 2>/dev/null; then exit 0; fi
  sleep 1
done;
exit 3" || up_rc=$?
up_rc="${up_rc:-0}"
if [[ "${up_rc}" != "0" ]]; then
	jq -cn --arg gateway "${GATEWAY}" --arg policy "${POLICY}" --arg scenario "${SCENARIO}" \
		--arg load "${LOAD}" --arg run_id "${RUN_ID}" --arg rc "${up_rc}" \
		'{gateway:$gateway,policy:$policy,scenario:$scenario,load:$load,run_id:$run_id,status:"FAIL",reason:"GATEWAY_TIMEOUT",details:("docker compose up or healthcheck failed with "+$rc)}' \
		> "${OUTPUT}/excluded.json"
	exit 0
fi

PHASE="gateway-setup"
ssh_gateway "cd /opt/gateway-benchmarks && BENCH_CONTAINER_PREFIX='${PREFIX}' DATA_URL='http://localhost:9080' ADMIN_URL='http://localhost:9081' BACKEND_URL='http://backend:8080' FEATURE_MISSING_REASON_FILE='${REMOTE_OUT}/setup-feature-missing.txt' bash gateways/${GATEWAY}/${POLICY}/setup.sh" \
	> "${LOGS_DIR}/setup.log" 2>&1 || setup_rc=$?
setup_rc="${setup_rc:-0}"
if [[ "${setup_rc}" == "42" ]]; then
	reason="$(ssh_gateway "sed -n '1p' '${REMOTE_OUT}/setup-feature-missing.txt' 2>/dev/null || true")"
	jq -cn --arg gateway "${GATEWAY}" --arg policy "${POLICY}" --arg scenario "${SCENARIO}" \
		--arg load "${LOAD}" --arg run_id "${RUN_ID}" --arg reason "${reason}" \
		'{gateway:$gateway,policy:$policy,scenario:$scenario,load:$load,run_id:$run_id,status:"EXCLUDED",reason:"FEATURE-MISSING",details:$reason}' \
		> "${OUTPUT}/excluded.json"
	exit 0
elif [[ "${setup_rc}" != "0" ]]; then
	echo "setup failed on gateway host; see ${LOGS_DIR}/setup.log" >&2
	jq -cn --arg gateway "${GATEWAY}" --arg policy "${POLICY}" --arg scenario "${SCENARIO}" \
		--arg load "${LOAD}" --arg run_id "${RUN_ID}" --arg rc "${setup_rc}" \
		'{gateway:$gateway,policy:$policy,scenario:$scenario,load:$load,run_id:$run_id,status:"FAIL",reason:"SETUP_FAILED",details:("setup.sh exited with "+$rc)}' \
		> "${OUTPUT}/excluded.json"
	exit 0
fi

PHASE="parity"
bash scripts/parity-attestation.sh \
	--gateway "${GATEWAY}" \
	--profile "${POLICY}" \
	--target "${GATEWAY_TARGET}" \
	--output "${OUTPUT}/parity.json" >/dev/null 2>&1 || true
parity_status="$(jq -r '.status // "UNKNOWN"' "${OUTPUT}/parity.json" 2>/dev/null || echo UNKNOWN)"
if [[ "${parity_status}" != "PASS" ]]; then
	jq -cn --arg gateway "${GATEWAY}" --arg policy "${POLICY}" --arg scenario "${SCENARIO}" \
		--arg load "${LOAD}" --arg run_id "${RUN_ID}" --arg pstatus "${parity_status}" \
		'{gateway:$gateway,policy:$policy,scenario:$scenario,load:$load,run_id:$run_id,status:"EXCLUDED",reason:"PARITY_NOT_PASS",details:("parity status was "+$pstatus)}' \
		> "${OUTPUT}/excluded.json"
	exit 0
fi

BENCH_JWT_VALID=""
BENCH_JWT_VALID_RS256=""
PHASE="jwt"
case "${SCENARIO}" in
	*jwks*) BENCH_JWT_VALID_RS256="$(bash scripts/gen-jwt-rs256.sh valid)" ;;
	*jwt*|*full-pipeline*) BENCH_JWT_VALID="$(bash scripts/gen-jwt.sh valid)" ;;
esac

PHASE="stats-start"
STATS_PID=""
if [[ "${AWS_SKIP_REMOTE_STATS:-0}" != "1" ]]; then
	printf '%s\n' 'ts_utc,cpu_ns_total,cpu_ns_system,cpu_online,mem_bytes,mem_limit,net_rx_bytes,net_tx_bytes,blkio_read_bytes,blkio_write_bytes' > "${OUTPUT}/docker-stats.csv"
	(
		${AWS_GATEWAY_SSH} "CONTAINER='${PREFIX}'; SOCKET=/var/run/docker.sock; while true; do ts=\$(date -u +%Y-%m-%dT%H:%M:%SZ); raw=\$(curl -sS --max-time 2 --unix-socket \"\${SOCKET}\" \"http://localhost/containers/\${CONTAINER}/stats?stream=false\" 2>/dev/null || true); if [ -n \"\${raw}\" ]; then printf '%s' \"\${raw}\" | jq -r --arg ts \"\${ts}\" '[\$ts, (.cpu_stats.cpu_usage.total_usage // 0), (.cpu_stats.system_cpu_usage // 0), (.cpu_stats.online_cpus // 0), (.memory_stats.usage // 0), (.memory_stats.limit // 0), ((.networks // {}) | to_entries | map(.value.rx_bytes // 0) | add // 0), ((.networks // {}) | to_entries | map(.value.tx_bytes // 0) | add // 0), (((.blkio_stats.io_service_bytes_recursive // []) | map(select((.op // \"\") | ascii_downcase == \"read\")) | map(.value // 0) | add) // 0), (((.blkio_stats.io_service_bytes_recursive // []) | map(select((.op // \"\") | ascii_downcase == \"write\")) | map(.value // 0) | add) // 0)] | @csv' 2>/dev/null || true; fi; sleep 1; done" \
			>> "${OUTPUT}/docker-stats.csv" 2> "${LOGS_DIR}/docker-stats.log"
	) &
	STATS_PID=$!
	printf '%s\n' "${STATS_PID}" > "${LOGS_DIR}/stats.pid"
fi

abs_k6="$(cd k6 && pwd)"
abs_out="$(cd "${OUTPUT}" && pwd)"
k6_args=(run "/k6/scenarios/${SCENARIO}.js" --summary-export "/out/k6-summary.json" --quiet)
if [[ "${STREAM}" == "1" ]]; then
	k6_args+=(--out "json=/out/k6-stream.json")
fi

PHASE="k6-image"
docker pull "${K6_IMAGE}" >/dev/null 2>&1 || true

# -----------------------------------------------------------------------------
# Warmup phase: 20 seconds of traffic to prime JIT and connection pools.
# This prevents the 'UNSTABLE' flag caused by cold-start latency jitter
# in the first few seconds of a fresh container run.
# -----------------------------------------------------------------------------
PHASE="k6-warmup"
echo "Starting 20s warmup for ${GATEWAY}/${POLICY}..." >&2
docker run --rm -i \
	-e "BENCH_TARGET_URL=${GATEWAY_TARGET}" \
	-e "BENCH_TARGET_URL_HTTPS=${GATEWAY_TARGET_HTTPS}" \
	-e "BENCH_JWT_VALID=${BENCH_JWT_VALID}" \
	-e "BENCH_JWT_VALID_RS256=${BENCH_JWT_VALID_RS256}" \
	"${K6_IMAGE}" run - <<EOF >/dev/null 2>&1 || true
import http from 'k6/http';
export const options = { vus: 50, duration: '20s' };
export default function() {
    const headers = {};
    if (__ENV.BENCH_JWT_VALID) { 
        headers['Authorization'] = 'Bearer ' + __ENV.BENCH_JWT_VALID; 
    } else if (__ENV.BENCH_JWT_VALID_RS256) {
        headers['Authorization'] = 'Bearer ' + __ENV.BENCH_JWT_VALID_RS256;
    }
    http.get(__ENV.BENCH_TARGET_URL + '/anything', { headers });
}
EOF

PHASE="k6-run"
docker run --rm \
	--user "$(id -u):$(id -g)" \
	-v "${abs_k6}:/k6:ro" \
	-v "${abs_out}:/out" \
	-e "BENCH_TARGET_URL=${GATEWAY_TARGET}" \
	-e "BENCH_TARGET_URL_HTTPS=${GATEWAY_TARGET_HTTPS}" \
	-e "BENCH_LOAD_PROFILE=${LOAD}" \
	-e "BENCH_POLICY_PROFILE=${POLICY}" \
	-e "BENCH_SCENARIO=${SCENARIO}" \
	-e "BENCH_GATEWAY=${GATEWAY}" \
	-e "BENCH_RUN_ID=${RUN_ID}" \
	-e "BENCH_RUN_SEED=${SEED}" \
	-e "BENCH_JWT_VALID=${BENCH_JWT_VALID}" \
	-e "BENCH_JWT_VALID_RS256=${BENCH_JWT_VALID_RS256}" \
	-e "BENCH_STREAM_METRICS=${STREAM}" \
	"${K6_IMAGE}" "${k6_args[@]}" > "${LOGS_DIR}/k6.log" 2>&1 || k6_rc=$?
k6_rc="${k6_rc:-0}"

PHASE="collect-artifacts"
if [[ -n "${STATS_PID}" ]]; then
	kill -TERM "${STATS_PID}" >/dev/null 2>&1 || true
	wait "${STATS_PID}" >/dev/null 2>&1 || true
fi
ssh_gateway "cat '${REMOTE_OUT}/compose.log' 2>/dev/null || true" > "${LOGS_DIR}/compose.log"

if [[ "${k6_rc}" != "0" ]]; then
	jq -cn --arg gateway "${GATEWAY}" --arg policy "${POLICY}" --arg scenario "${SCENARIO}" \
		--arg load "${LOAD}" --arg run_id "${RUN_ID}" --arg rc "${k6_rc}" \
		'{gateway:$gateway,policy:$policy,scenario:$scenario,load:$load,run_id:$run_id,status:"FAIL",reason:"K6_FAILED",details:("k6 exited with "+$rc)}' \
		> "${OUTPUT}/excluded.json"
	exit 0
fi
[[ -s "${OUTPUT}/k6-summary.json" ]] || {
	jq -cn --arg gateway "${GATEWAY}" --arg policy "${POLICY}" --arg scenario "${SCENARIO}" \
		--arg load "${LOAD}" --arg run_id "${RUN_ID}" \
		'{gateway:$gateway,policy:$policy,scenario:$scenario,load:$load,run_id:$run_id,status:"FAIL",reason:"NO_SUMMARY",details:"k6-summary.json is missing or empty"}' \
		> "${OUTPUT}/excluded.json"
	exit 0
}
