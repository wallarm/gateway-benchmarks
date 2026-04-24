#!/usr/bin/env bash
# infra/aws/userdata/loadgen.sh
#
# Bootstrap the loadgen host. Roles:
#   1. Install Docker + the bench repo (via _common.sh).
#   2. Pre-pull the pinned k6 image so the first `k6 run` doesn't pay
#      a 5-second image-pull penalty mid-bench (which would skew the
#      ramp-up phase of p3-ramp / p4-stress).
#   3. Drop a `~ubuntu/bench-helpers.sh` with ready-to-source env
#      pointing at the gateway's private IP.

set -euo pipefail
exec > >(tee -a /var/log/userdata-loadgen.log) 2>&1

echo "==> userdata/loadgen: starting at $(date -u +%Y-%m-%dT%H:%M:%SZ)"

# -----------------------------------------------------------------------------
# Common bootstrap (Docker, kernel tuning, repo clone)
# -----------------------------------------------------------------------------
# cloud-init writes user_data to /var/lib/cloud/instance/user-data.txt;
# the role scripts source the common fragment from the cloned repo
# *after* git clone has happened. To avoid a chicken-and-egg, we
# inline the fragment via a base64-decoded fetch from S3 / GitHub
# raw — but that's overkill. Instead, we run the common flow inline
# below (duplicated across the 3 role scripts; the duplication is
# tolerable because there are only 3 of them).

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y --no-install-recommends \
    ca-certificates curl git gnupg jq openssl python3-minimal \
    docker.io docker-compose-v2

cat <<'EOF' >/etc/sysctl.d/99-bench.conf
net.core.somaxconn        = 65535
fs.file-max               = 1048576
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_tw_reuse     = 1
net.ipv4.ip_local_port_range = 1024 65535
EOF
sysctl --system >/dev/null

cat <<'EOF' >>/etc/security/limits.conf
*  soft  nofile  65536
*  hard  nofile  65536
root  soft  nofile  65536
root  hard  nofile  65536
EOF

systemctl enable --now docker
usermod -aG docker ubuntu

for _ in $(seq 1 30); do
    if docker info >/dev/null 2>&1; then break; fi
    sleep 1
done

REPO_URL="${REPO_URL:-https://github.com/wallarm/gateway-benchmarks.git}"
REPO_DIR="/opt/gateway-benchmarks"

if [[ ! -d "${REPO_DIR}/.git" ]]; then
    git clone "${REPO_URL}" "${REPO_DIR}"
fi
chown -R ubuntu:ubuntu "${REPO_DIR}"

# -----------------------------------------------------------------------------
# Pre-pull k6 (matches scripts/load-gateway.sh K6_IMAGE pin)
# -----------------------------------------------------------------------------
docker pull grafana/k6:1.7.1@sha256:4fd3a694926b064d3491d9b02b01cde886583c4931f1223816e3d9a7bdfa7e0f

# -----------------------------------------------------------------------------
# Helper script — sourced by the operator after SSH-ing in
# -----------------------------------------------------------------------------
# Hardcoding the gateway's private IP here means the operator
# doesn't have to remember it after `tofu apply`. The IP is
# pinned in variables.tf (gateway_private_ip default 10.50.1.20).
cat <<'EOF' >/home/ubuntu/bench-helpers.sh
# Source me: `source ~/bench-helpers.sh`
export BENCH_TARGET_URL="http://10.50.1.20:9080"
export BENCH_TARGET_URL_HTTPS="https://10.50.1.20:9443"
export REPO_DIR="/opt/gateway-benchmarks"

bench_smoke_http() {
    cd "${REPO_DIR}"
    bash scripts/load-gateway.sh \
        --gateway nginx --policy p01-vanilla \
        --scenario s01-vanilla-http --load p1-baseline
}

bench_smoke_https() {
    cd "${REPO_DIR}"
    bash scripts/load-gateway.sh \
        --gateway nginx --policy p01-vanilla \
        --scenario s13-vanilla-https --load p1-baseline
}

echo "Loaded bench helpers. Try: bench_smoke_http  or  bench_smoke_https"
EOF
chown ubuntu:ubuntu /home/ubuntu/bench-helpers.sh
chmod 0755 /home/ubuntu/bench-helpers.sh

# Auto-source the helpers on login so `ssh ubuntu@<loadgen>` greets
# the operator with the bench env already populated.
echo 'source ~/bench-helpers.sh 2>/dev/null || true' >>/home/ubuntu/.bashrc

echo "==> userdata/loadgen: done at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
