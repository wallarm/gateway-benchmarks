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

# -----------------------------------------------------------------------------
# Pre-pull every gateway base image (parallel where possible)
# -----------------------------------------------------------------------------
# The exact pins MUST stay in sync with each gateways/<gw>/docker-compose.yaml
# `image:` line. Mismatched digests would mean the AWS run measures
# a different binary than the local run — the canonical-numbers contract
# would silently break. Update both files together.
{
    docker pull nginx:1.27.3-alpine@sha256:814a8e88df978ade80e584cc5b333144b9372a8e3c98872d07137dbf3b44d0e4 &
    docker pull openresty/openresty:1.25.3.2-2-alpine                                                          &
    docker pull envoyproxy/envoy:v1.34.0                                                                       &
    docker pull traefik:3.5                                                                                    &
    docker pull kong:3.7                                                                                       &
    docker pull apache/apisix:3.13.0-debian                                                                    &
    docker pull tykio/tyk-gateway:v5.5.0                                                                       &
    docker pull bitnami/etcd:3.5.13                                                                            &
    wait
} || echo "WARN: at least one pre-pull failed — `docker pull` it manually before the sweep."

# Build the vendored backend image too, in case the operator runs a
# single-host smoke (gateway + backend on this host) for sanity-
# checking without the loadgen host. See infra/aws/userdata/backend.sh
# for why we build instead of pull.
DOCKER_BUILDKIT=1 docker build \
    --build-arg BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --tag ghcr.io/mccutchen/go-httpbin:v2.22.1 \
    --tag gateway-benchmarks/backend:v2.22.1 \
    "${REPO_DIR}/backend" || \
    echo "WARN: vendored backend build failed — single-host smoke won't work; sweep is unaffected."

echo "==> userdata/gateway: done at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
