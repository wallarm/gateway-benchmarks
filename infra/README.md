# infra — Local and AWS Infrastructure

Two ways to run the benchmark. Both must produce an **identical ranking** (TASK §8).

## `local/` — Local mode

`docker-compose.yaml` with **three isolated network namespaces** on a single host to mirror the 3-host topology:

```
loadgen (k6 container)  ──┐
                          ├─→ perf-net ─→  gateway  ─→  perf-upstream-net  ─→  backend
                          │
orchestrator (host)  ─────┘
```

Resource isolation:
- `cpuset` pinning on distinct physical cores
- `mem_limit` per service
- `ulimits.nofile: 65536`
- `sysctls.net.core.somaxconn: 4096`

Host requirements:
- ≥ 8 physical cores
- ≥ 16 GB RAM
- Docker Desktop / Engine ≥ 24

## `aws/` — AWS mode

Terraform/OpenTofu, 3 EC2 `c6i.2xlarge` in a single **cluster placement group**, SR-IOV:

```
loadgen-host (10.0.1.10)  ──→  gateway-host (10.0.1.20)  ──→  backend-host (10.0.1.30)
```

All hosts:
- Ubuntu 24.04 LTS (AMI pinned by ID)
- EBS gp3 300 GB, 3000 IOPS, 125 MB/s
- Security Group: SSH from `allowed_ssh_cidrs`, private traffic within the VPC
- Cloud-init: Docker ≥ 24 from the official repo

See [docs/ARCHITECTURE.md](../docs/ARCHITECTURE.md).

## Status

> Phase 5 in the roadmap — pending.
