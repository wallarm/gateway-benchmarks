#!/usr/bin/env bash
# infra/aws/userdata/_common.sh
#
# REFERENCE COPY — NOT EXECUTED by cloud-init. The 3 role scripts
# (loadgen.sh / gateway.sh / backend.sh) inline the same bootstrap
# inside their own bodies because cloud-init's user_data is a single
# script with no `source` resolution against other userdata files.
# Keeping this file alongside the role scripts:
#   - documents the canonical bootstrap shape in one readable place;
#   - serves as a baseline for reviewing the 3 inline copies for
#     drift (a CI lint could diff each role's inline copy against
#     this — open follow-up);
#   - lets the operator manually `bash _common.sh` on a freshly
#     spawned host if they're recreating the bootstrap by hand.
#
# Pinned versions:
#   Docker CE      : whatever Ubuntu noble's docker.io provides today
#                    (≥ 24, sufficient for everything else we need).
#                    Switch to Docker's own apt repo if you need 25+.
#   docker-compose : v2 plugin shipped by docker.io (≥ 2.21).
#
# The repo itself is cloned into /opt/gateway-benchmarks during
# the role userdata, after this fragment finishes.

set -euo pipefail
exec > >(tee -a /var/log/userdata-common.log) 2>&1

echo "==> userdata/_common: starting at $(date -u +%Y-%m-%dT%H:%M:%SZ)"

# -----------------------------------------------------------------------------
# OS housekeeping
# -----------------------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive

apt-get update -y
apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    git \
    gnupg \
    jq \
    openssl \
    python3-minimal \
    docker.io \
    docker-compose-v2

# Tune the kernel for k6-style workloads. Same numbers as
# infra/local/docker-compose.yaml's sysctls block (raised to system
# level here because every container on this host inherits them).
cat <<'EOF' >/etc/sysctl.d/99-bench.conf
# Raise the TCP accept backlog so listen() doesn't drop SYN-ACKs
# under burst arrival. infra/local mirrors this on the gateway service.
net.core.somaxconn        = 65535
# Raise the per-process file descriptor ceiling so k6 can open
# 4096 simultaneous sockets in p4-stress without ENFILE.
fs.file-max               = 1048576
# Allow more listening on a port without rebinding.
net.ipv4.tcp_max_syn_backlog = 65535
# Reuse TIME_WAIT sockets quickly — fine for closed networks like
# the bench, would be a bad idea behind a NAT.
net.ipv4.tcp_tw_reuse     = 1
# Wider ephemeral port range so a 20k RPS sustained-load run
# doesn't run out of source ports.
net.ipv4.ip_local_port_range = 1024 65535
EOF
sysctl --system >/dev/null

# Per-user nofile limits so anyone in `docker` group inherits the
# same socket budget that the per-container ulimits ask for.
cat <<'EOF' >>/etc/security/limits.conf
*  soft  nofile  65536
*  hard  nofile  65536
root  soft  nofile  65536
root  hard  nofile  65536
EOF

# -----------------------------------------------------------------------------
# Docker — ensure it's running and the ubuntu user can use it
# -----------------------------------------------------------------------------
systemctl enable --now docker
usermod -aG docker ubuntu

# Wait for the docker socket to actually accept connections
# (systemctl exits before dockerd's API is reachable).
for _ in $(seq 1 30); do
    if docker info >/dev/null 2>&1; then
        echo "==> docker ready: $(docker --version)"
        break
    fi
    sleep 1
done

# -----------------------------------------------------------------------------
# Repo clone — same path on every host so scripts/ are at a known location.
# Reviewers can override REPO_URL to point at a fork.
# -----------------------------------------------------------------------------
REPO_URL="${REPO_URL:-https://github.com/wallarm/gateway-benchmarks.git}"
REPO_DIR="/opt/gateway-benchmarks"

if [[ ! -d "${REPO_DIR}/.git" ]]; then
    git clone "${REPO_URL}" "${REPO_DIR}"
else
    git -C "${REPO_DIR}" fetch --all --quiet
    git -C "${REPO_DIR}" reset --hard origin/main
fi

# Make the entire repo readable by the `ubuntu` user so
# non-root SSH sessions can run scripts/* without sudo.
chown -R ubuntu:ubuntu "${REPO_DIR}"

echo "==> userdata/_common: done at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
