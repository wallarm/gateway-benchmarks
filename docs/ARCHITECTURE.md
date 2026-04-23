# Architecture

> Architectural decisions required by [TASK.md §§2, 9](../TASK.md). This file is the visual map and the network path.

## Logical topology

Three isolated **hosts** (AWS: EC2 in a cluster placement group; local: three network namespaces inside one Docker host):

```
┌─────────────────┐       ┌──────────────────┐       ┌────────────────────┐
│   loadgen-host  │       │  gateway-host    │       │   backend-host     │
│                 │       │                  │       │                    │
│   k6 (1.7.1)    │──────►│  gateway under   │──────►│  forked go-httpbin │
│                 │       │  test (1 of 7)   │       │  (pinned digest)   │
└─────────────────┘       └──────────────────┘       └────────────────────┘
        ▲                          ▲                          ▲
        │                          │                          │
        └────── orchestrator (Go, host) ─── docker stats ──────┘
                        │
                        └── reports/<run>/manifest.json
                            reports/<run>/report.html
```

Key properties:

1. **Loadgen does not share CPU with the gateway or backend.** In local mode `cpuset` pins to distinct physical cores; on AWS each EC2 is a dedicated instance.
2. **The backend lives off the gateway host.** That is a change from the legacy perf harness, where the backend ran in Docker alongside the gateway. Isolation matters because otherwise `go-httpbin` would steal CPU that should go to the gateway.
3. **Private networks only, no public IPs** (except SSH from `allowed_ssh_cidrs`).

## Data flows

### One cell run (gateway × policy × load profile × scenario)

```
orchestrator ──(1)──► gateway-host: docker compose up -d <gateway>
orchestrator ──(2)──► gateway-host: scripts/parity-attestation.sh
        │
        │ parity OK
        ▼
orchestrator ──(3)──► loadgen-host: k6 run --env TARGET=<gateway-host> --out json=stream.json
        │
        ▼
k6 ─────────────────► gateway ───► backend ───► gateway ───► k6
        │
        ▼
orchestrator ──(4)──► docker stats --no-stream --format json (peak + steady state)
orchestrator ──(5)──► collects k6-summary.json + stream.json.gz + docker-stats.json
                      into reports/<run>/raw/<gateway>/<profile>__<scenario>/
```

### Run finalisation

```
orchestrator ──(1)──► parse every raw/*.json
             ──(2)──► classify errors (5XX / 4XX-expected / client-side / excluded)
             ──(3)──► aggregate across (gateway × profile × scenario)
             ──(4)──► write summary.csv + summary.json
             ──(5)──► render report.html from the template (style driven by docs/REPORT.md)
             ──(6)──► write manifest.json (digests, seeds, git SHA, timestamps, host info)
```

## Network ports

| Host | Port | Protocol | Purpose |
|------|------|----------|---------|
| loadgen  | 22       | TCP      | SSH (orchestrator ↔ host) |
| gateway  | 22       | TCP      | SSH |
| gateway  | 8080     | HTTP/1.1 | primary proxy port (profiles p01-p03, p06-p10) |
| gateway  | 8443     | HTTPS    | TLS (profiles p02, p04-p06, p09, p11) |
| gateway  | 9901     | HTTP     | admin/metrics of the gateway (where available) |
| backend  | 22       | TCP      | SSH |
| backend  | 8080     | HTTP/1.1 | forked go-httpbin |

## Local-mode network namespaces

In `infra/local/docker-compose.yaml`:

```yaml
networks:
  bench-loadgen:   # loadgen ↔ gateway
  bench-upstream:  # gateway ↔ backend
```

Containers:

```
k6          → bench-loadgen                          (emulates loadgen-host)
gateway     → bench-loadgen + bench-upstream         (emulates gateway-host)
backend     → bench-upstream                         (emulates backend-host)
```

So k6 never talks to the backend directly; the packet path always goes through the gateway.

## AWS mode

`infra/aws/` contains a Terraform module:

- VPC with a single private subnet
- Cluster Placement Group (SR-IOV, same rack, minimal latency)
- 3 × `c6i.2xlarge` (8 vCPU, 16 GB RAM, 12.5 Gbps burst network)
- EBS gp3 300 GB, 3000 IOPS, 125 MB/s — identical across hosts
- Ubuntu 24.04 LTS (AMI pinned by ID)
- Security Group: SSH from `allowed_ssh_cidrs`, private traffic inside the VPC
- Cloud-init: Docker ≥ 24 from the official repo

Exported outputs:

```hcl
loadgen_host_public_ip
gateway_host_public_ip
backend_host_public_ip
loadgen_host_private_ip
gateway_host_private_ip
backend_host_private_ip
```

The orchestrator takes the private IPs and wires them into the k6 target URL and the gateway configs.

## Differences from the legacy perf harness (reviewer note)

| Aspect | Legacy harness | `gateway-benchmarks/` (this repo) |
|--------|----------------|-----------------------------------|
| Hosts  | 2 EC2 (loadgen + gateway+backend) | **3 EC2** (loadgen + gateway + backend) |
| Backend | `mccutchen/go-httpbin` public image | **Fork** under `backend/`, pinned by digest |
| Orchestrator | Taskfile + bash | **Go** binary |
| Parity | — | `scripts/parity-attestation.sh` |
| Policies | No matrix | **12 policy profiles** |
| Reports | `benchmark-report.html` | + CSV/JSON wide + manifest.json |
| Reproducibility | — | digests + git SHA + RNG seed + host info |

## Status

> Stub — filled in alongside Phases 5 and 6.
