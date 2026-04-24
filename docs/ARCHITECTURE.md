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

Aligned across local + AWS modes so a single `BENCH_TARGET_URL` flip switches between them.

| Host | Port | Protocol | Purpose |
|------|------|----------|---------|
| loadgen  | 22       | TCP      | SSH (operator ↔ host) |
| gateway  | 22       | TCP      | SSH |
| gateway  | 9080     | HTTP/1.1 | data plane (parity + s01–s12) |
| gateway  | 9443     | HTTPS    | TLS data plane (s13 / s14, available on `p01-vanilla` + `p12-full-pipeline`) |
| gateway  | 9901     | HTTP     | admin / metrics — only where the gateway exposes one (envoy, kong, apisix, tyk) |
| backend  | 22       | TCP      | SSH |
| backend  | 8080     | HTTP/1.1 | go-httpbin (vendored, pinned digest) |

## Local-mode network namespaces

In `infra/local/docker-compose.yaml`:

```yaml
networks:
  bench-edge-net:      # loadgen ↔ gateway only (gateway answers :9080 + :9443)
  bench-upstream-net:  # gateway ↔ backend only (gateway resolves backend:8080)
```

Containers:

```
loadgen     → bench-edge-net                                  (emulates loadgen-host)
gateway     → bench-edge-net + bench-upstream-net             (emulates gateway-host)
backend     → bench-upstream-net                              (emulates backend-host)
```

DNS isolation is enforced by docker network namespacing — loadgen
literally cannot resolve `backend:8080` (`wget: bad address 'backend:8080'`).
Verified after every `make perf-local-up` by the smoke check in
`scripts/perf-local-cycle-smoke.sh`. So k6 never talks to the
backend directly; the packet path always goes through the gateway.

## AWS mode

`infra/aws/` ships an OpenTofu / Terraform module:

- VPC `10.50.0.0/16` with one public subnet `10.50.1.0/24` (single AZ — cluster placement groups are AZ-scoped)
- **Cluster placement group** packs all 3 instances on the same physical rack — drops intra-cluster RTT from ~250 µs (default) to ~10–30 µs
- 3 × `c6i.2xlarge` (8 vCPU, 16 GiB RAM, up to 12.5 Gbps network)
- EBS gp3 300 GB, 3000 IOPS, 125 MB/s, encrypted — identical across hosts
- Ubuntu 24.04 LTS (Canonical's `noble-amd64-server-*`, dynamically looked up — never pinned, so reviews stay on the current kernel; the ID is recorded in the Terraform state for repro)
- **Security groups enforce the same isolation as the local nets**:
  loadgen → gateway :9080/:9443 (allowed), gateway → backend :8080
  (allowed), loadgen → backend :8080 (denied — must transit the gateway)
- Cloud-init userdata per role installs Docker, tunes the kernel
  (`somaxconn=65535`, `nofile=65536`), clones the bench repo to
  `/opt/gateway-benchmarks`, pre-pulls the pinned images; backend
  runs go-httpbin under a `gwb-backend.service` systemd unit for
  crash-safety

Exported outputs (see `infra/aws/outputs.tf` for the full list):

```hcl
loadgen_public_ip   gateway_public_ip   backend_public_ip
loadgen_private_ip  gateway_private_ip  backend_private_ip
ssh_loadgen          ssh_gateway         ssh_backend          # ready-to-paste SSH commands
bench_target_url_http   = "http://10.50.1.20:9080"
bench_target_url_https  = "https://10.50.1.20:9443"
summary                 = "<multi-line topology + helper recap>"
```

The orchestrator (Phase 6) reads the private IPs and feeds them into
`scripts/load-gateway.sh` as `BENCH_TARGET_URL` / `BENCH_TARGET_URL_HTTPS`.

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

> **Phase 5 — done.** Local 3-host emulation (`infra/local/`) and AWS
> 3 EC2 cluster (`infra/aws/`) both ship with TLS plumbing, kernel
> tuning, and Makefile lifecycle targets. End-to-end smoke proven
> locally (parity 4/4 + s01 + s13, 4.4 M k6 checks, 0 failed).
> Phase 6 (Go orchestrator) is the next blocker for full-matrix runs
> on AWS — until it lands, single cells can be exercised on AWS with
> the same `scripts/load-gateway.sh` that drives Phase 4 locally,
> via the helpers dropped onto the loadgen host by cloud-init.
