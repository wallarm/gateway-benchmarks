# infra — Local and AWS Infrastructure (Phase 5)

Two ways to run the benchmark, both producing an **identical
ranking** (TASK §8). Phase 5 ships:

* `local/` — Docker Compose 3-service / 2-network emulation of the
  3-host topology, ready for reviewer / CI smoke runs on any laptop
  with Docker.
* `aws/`   — OpenTofu / Terraform module for 3 EC2 `c6i.2xlarge` in a
  single cluster placement group, used for the canonical numbers
  in the published HTML report.

Both expose the **same port contract** to the loadgen:

| Path        | Local URL                  | AWS URL                                     |
|-------------|----------------------------|---------------------------------------------|
| HTTP/1.1    | `http://localhost:9080`    | `http://<gateway-private-ip>:9080`          |
| TLS         | `https://localhost:9443`   | `https://<gateway-private-ip>:9443`         |

so every `scripts/load-gateway.sh` / `scripts/parity-attestation.sh`
invocation is a `BENCH_TARGET_URL` flip away from running in either
mode.

## `local/` — Local mode

`docker-compose.yaml` defines **three services on two isolated bridge
networks** so loadgen has no direct route to backend:

```
loadgen ──── bench-edge-net ──→ gateway ──── bench-upstream-net ──→ backend
(k6, idle)   :9080 / :9443                   :8080
```

| Service | Network membership                          | Resources    | Notes                                       |
|---------|---------------------------------------------|--------------|---------------------------------------------|
| loadgen | `bench-edge-net` only                       | 2 CPU / 1G   | k6 image, idle until `docker compose exec`  |
| gateway | `bench-edge-net` + `bench-upstream-net`     | 4 CPU / 2G   | image+profile via env, default = nginx p01  |
| backend | `bench-upstream-net` only                   | 1 CPU / 512M | go-httpbin (distroless)                     |

Resource isolation:
- `cpus: <N>` + `mem_limit: <…>` per service (top-level legacy fields,
  effective in standalone mode without swarm)
- `ulimits.nofile.soft|hard = 65536`
- `sysctls.net.core.somaxconn = 4096` on the gateway

TLS scaffolding:
- Cert + key live under `../gateways/_reference/tls/` (canonical
  `bench.local` self-signed pair, valid until 2126; SAN covers
  `bench.local`, `localhost`, `gateway`, `127.0.0.1`).
- `p01-vanilla` and `p12-full-pipeline` ship a `listen 9443 ssl;`
  server block that backs the s13 / s14 k6 scenarios.
- Other profiles ignore the TLS mount; flipping
  `GATEWAY_PROFILE=p12-full-pipeline` switches the smoke target.

Host requirements:
- 8 cores / 8 GB RAM (default budget = 7 CPU + 3.5 GB)
- Docker Desktop / Engine ≥ 24 + Compose v2

Quickstart:

```bash
cp infra/local/.env.example infra/local/.env   # optional — defaults work
make perf-local-up          # bring up the stack (waits for gateway data plane)
make perf-local-parity      # 4-probe parity attestation against http://localhost:9080
make perf-local-cycle-smoke # k6 s01 (HTTP) + s13 (HTTPS) baseline smoke
make perf-local-down        # stop and remove containers + networks
```

The smoke run lands summary JSONs under `reports/local-smoke/` on the
host (bind-mounted from the loadgen container's `/out`).

## `aws/` — AWS mode

OpenTofu module bringing up **3 EC2 `c6i.2xlarge` in a single cluster
placement group** inside one AZ — the placement constraint that
delivers ~10 µs intra-cluster RTT (vs. ~250 µs default placement) so
the gateway's processing overhead, not the network, dominates the
measured p95.

```
loadgen-host (10.50.1.10) ──→ gateway-host (10.50.1.20) ──→ backend-host (10.50.1.30)
                              ▲  same cluster placement group, same AZ  ▼
```

All three hosts:
- **AMI**: Ubuntu 24.04 LTS (Canonical's `noble-amd64-server-*`,
  looked up dynamically per region)
- **EBS**: gp3 300 GB, 3000 IOPS, 125 MB/s, encrypted
- **Bootstrap**: cloud-init userdata installs Docker, tunes the
  kernel for k6 workloads (`somaxconn=65535`, `nofile=65536`), clones
  the bench repo to `/opt/gateway-benchmarks`, pre-pulls the pinned
  images, and (on the backend host) launches go-httpbin as a systemd
  unit for crash-safety.

Network-level isolation matches `local/`:

| From        | To              | Allowed? |
|-------------|-----------------|----------|
| loadgen     | gateway :9080   | yes (SG) |
| loadgen     | gateway :9443   | yes (SG) |
| loadgen     | backend :8080   | **no — must transit gateway** |
| gateway     | backend :8080   | yes (SG) |

Quickstart:

```bash
cp infra/aws/terraform.tfvars.example infra/aws/terraform.tfvars
$EDITOR infra/aws/terraform.tfvars        # set ssh_key_name + allowed_ssh_cidrs
make perf-aws-init                        # one-time per checkout
make perf-aws-up                          # tofu apply (~3 min including bootstrap)
make perf-aws-summary                     # print IPs + ready-to-paste SSH commands
make perf-aws-ssh-loadgen                 # SSH into loadgen
# … run the matrix …
make perf-aws-destroy                     # tear down everything
```

State is local (`infra/aws/terraform.tfstate`) — every operator runs
their own apply with their own AWS account. Override the backend in
`versions.tf` if you want shared S3+DynamoDB locking.

The AWS provider version is pinned in `.terraform.lock.hcl` (committed)
across `linux_amd64`, `linux_arm64`, `darwin_amd64`, `darwin_arm64` so
reviewers on any platform get bit-identical provider behaviour.

## See also

- [docs/ARCHITECTURE.md](../docs/ARCHITECTURE.md) — system overview
- [docs/POLICIES.md](../docs/POLICIES.md) § HTTPS scenarios — how
  s13 / s14 consume the TLS scaffolding
- [docs/REPORT.md](../docs/REPORT.md) — output directory layout
