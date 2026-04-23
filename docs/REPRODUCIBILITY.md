# Reproducibility

> What it takes for two independent runs to produce **the same ranking** within tolerance.

## What we pin (TASK §7)

### 1. Manifest per run

File `reports/<run>/manifest.json`:

```json
{
  "run_id": "20260422T090000Z_abc12345",
  "started_at": "2026-04-22T09:00:00Z",
  "finished_at": "2026-04-22T10:15:23Z",
  "git_sha": "abc12345...",
  "mode": "aws | local",
  "seed": 4242424242,
  "orchestrator_version": "0.1.0",
  "k6_version": "1.7.1",
  "k6_digest": "sha256:...",
  "hosts": {
    "loadgen": { "ip": "10.0.1.10", "instance_type": "c6i.2xlarge", "kernel": "6.8.0-45-generic", "docker": "27.3.1" },
    "gateway": { ... },
    "backend": { ... }
  },
  "gateways": {
    "wallarm":  { "image": "wallarm/api-gateway:v0.2.x",        "digest": "sha256:..." },
    "nginx":    { "image": "nginx:1.27.3-alpine",               "digest": "sha256:..." },
    "...":       "..."
  },
  "backend": { "image": "ghcr.io/wallarm/gb-backend:abc12345",   "digest": "sha256:..." },
  "matrix": {
    "policy_profiles": ["p01", "p02", "...", "p12"],
    "load_profiles":   ["p1-baseline", "p2-sustained", "p3-ramp", "p4-stress"],
    "scenarios":       ["s01-bypass-http", "s02-bypass-https", "..."],
    "repetitions": 1
  },
  "deviations": [ ]
}
```

### 2. Deterministic inputs

- **RNG seed** — one seed per run, stored in the manifest. The orchestrator passes it to k6 via `--env SEED=<n>`, and `lib.js` uses it for every `Math.random()` call.
- **Body payloads** — pre-generated bodies in `fixtures/`, addressed as `index = (__VU * 1000 + __ITER + SEED) % N`.
- **JWTs, API keys, rate-limit keys** — hardcoded in `scripts/parity-attestation.sh`.
- **TLS certificates** — pre-generated and pinned under `gateways/_reference/tls/`.

### 3. Image digests, not tags

Before every run:

```bash
docker pull $IMAGE
docker inspect --format='{{index .RepoDigests 0}}' $IMAGE
```

The digest is recorded in the manifest. Two runs with different digests for the same gateway are treated as **different experiments** even if the tag is identical.

### 4. Host info

- Instance type
- Kernel version (`uname -r`)
- Docker version
- CPU model (`lscpu | grep "Model name"`)
- Total RAM
- Uptime (to detect warm/cold hosts)

## Verifying reproducibility

```bash
# Run #1
make perf-local-run RUN_ID=run-1
# Run #2 (10 minutes later or on a different host)
make perf-local-run RUN_ID=run-2

# Diff
scripts/compare-runs.sh reports/run-1 reports/run-2
```

The script checks:

1. **Identity**: git SHA, seed, matrix, and every digest must match.
2. **Numeric similarity**: for every cell —
   - RPS: tolerance ±3%
   - p95 latency: tolerance ±10%
   - memory peak: tolerance ±5%
   - error counts: must match within 10 per million
3. **Ranking stability**: the top-3 gateways by RPS in each cell must match across both runs.

If any check fails → the run is tagged `not reproducible` and becomes a release blocker.

## Tolerances (TASK §8)

| Metric | Tolerance |
|--------|-----------|
| RPS (throughput)         | ±3% |
| Latency p50, p95, p99    | ±10% |
| Memory peak              | ±5% |
| Memory steady-state      | ±5% |
| CPU %                    | ±10% |
| Bandwidth (bytes/s)      | ±3% |
| Errors 5XX absolute      | 0 (must match) |
| Errors 4XX-expected      | 0 (must match) |

## Factors we cannot eliminate

- **EC2 noisy neighbour**: even inside a cluster placement group a small jitter from rack neighbours is possible. Mitigation — 2 repetitions and take the median.
- **Thermal throttling in local mode**: Docker Desktop on macOS does not guarantee pinning. Mitigation — local mode is explicitly tagged `less-reliable`; the local ranking is distinct from AWS (though the top-3 typically agree).
- **Upstream availability** (Kong pulls especially): if hub.docker.com is unreachable, the run aborts and is reported as `prereq_failed`.

## Status

> Stub. Implementation — Phases 6 (manifest + seed) and 8 (compare-runs.sh + quality gates).
