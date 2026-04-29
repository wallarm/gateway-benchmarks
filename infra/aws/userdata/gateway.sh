#!/usr/bin/env bash
# infra/aws/userdata/gateway.sh
#
# Bootstrap the gateway host. Roles:
#   1. Install Docker + the bench repo (same flow as loadgen).
#   2. Pre-pull every gateway base image so a `make perf-aws-run`
#      sweep doesn't pay per-cell pull penalties (the largest image
#      — wallarm — is built on the host because it has no public
#      tag; pre-pulling the rest still saves ~5 min per cycle).
#   3. The actual `docker compose up` is driven by the operator
#      from the loadgen host or scripts/load-gateway.sh during a
#      sweep — we don't pin a single gateway here because every
#      cell of the matrix swaps it out anyway.

set -euo pipefail
exec > >(tee -a /var/log/userdata-gateway.log) 2>&1

echo "==> userdata/gateway: starting at $(date -u +%Y-%m-%dT%H:%M:%SZ)"

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y --no-install-recommends \
    ca-certificates curl git gnupg jq openssl python3-minimal \
    docker.io docker-compose-v2 docker-buildx \
    build-essential        # needed for the wallarm-image local build

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

# Gateway images are pulled on demand by docker compose for the current
# shard. Avoid pre-pulling every gateway here: it made smoke runs wait
# for unrelated images before readiness completed.

echo "==> userdata/gateway: done at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
