#!/usr/bin/env bash
# infra/aws/userdata/backend.sh
#
# Bootstrap the backend host. Single role: run go-httpbin on
# 0.0.0.0:8080. Started as a long-lived systemd unit so the host
# behaves identically across reboots without relying on docker
# compose lifecycle from the operator's laptop.

set -euo pipefail
exec > >(tee -a /var/log/userdata-backend.log) 2>&1

echo "==> userdata/backend: starting at $(date -u +%Y-%m-%dT%H:%M:%SZ)"

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y --no-install-recommends \
    ca-certificates curl git gnupg jq openssl python3-minimal \
    docker.io docker-compose-v2 docker-buildx

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
# Build the vendored backend image.
#
# Why not just `docker pull ghcr.io/mccutchen/go-httpbin:v2.22.1`?
# Because mccutchen/go-httpbin's GHCR registry only retains a sliding
# window of tags (verified empirically 2026-04-24: every numbered tag
# v2.x.y had been purged, leaving only :latest). Pinning to :latest
# would break the manifest-reproducibility contract since we cannot
# control its digest. Building from the vendored upstream/ source
# (which is byte-locked to v2.22.1 commit f26ca58 — see
# backend/Dockerfile ARGs) gives a deterministic image that we tag
# under the same upstream coordinate so every gateway compose file
# can reference `ghcr.io/mccutchen/go-httpbin:v2.22.1` unchanged.
DOCKER_BUILDKIT=1 docker build \
    --build-arg BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --tag ghcr.io/mccutchen/go-httpbin:v2.22.1 \
    --tag gateway-benchmarks/backend:v2.22.1 \
    "${REPO_DIR}/backend"

# -----------------------------------------------------------------------------
# systemd unit — backend stays up across reboots
# -----------------------------------------------------------------------------
# Listening on 0.0.0.0:8080 inside the container; the host SG only
# allows :8080 from the gateway SG, so the container's port binding
# is effectively private despite the wildcard listen address.
cat <<'EOF' >/etc/systemd/system/gwb-backend.service
[Unit]
Description=gateway-benchmarks backend (go-httpbin)
After=docker.service network-online.target
Requires=docker.service
Wants=network-online.target

[Service]
Restart=always
RestartSec=5s
ExecStartPre=-/usr/bin/docker rm -f gwb-backend
ExecStart=/usr/bin/docker run --rm --name gwb-backend \
    --ulimit nofile=65536:65536 \
    -p 8080:8080 \
    ghcr.io/mccutchen/go-httpbin:v2.22.1
ExecStop=/usr/bin/docker stop gwb-backend

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now gwb-backend.service

# Wait for the backend to actually answer on :8080 before declaring
# bootstrap done. The gateway host's parity smoke pings this
# endpoint as soon as it boots.
for i in $(seq 1 60); do
    if curl -fsS -o /dev/null --max-time 1 http://127.0.0.1:8080/status/200 2>/dev/null; then
        echo "==> backend ready after ${i} attempts"
        break
    fi
    sleep 1
done

echo "==> userdata/backend: done at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
