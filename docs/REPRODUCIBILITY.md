# Reproducibility

> What it takes for two independent runs to produce **the same ranking** within tolerance.

## What we pin (TASK §7)

### 1. Manifest per run

The Phase 6 `bench` orchestrator writes `reports/<run-id>/manifest.json`
(schema v1) at the start of every sweep and finalises it (with
`finished_at` + `duration_sec`) at the end. Schema:

```jsonc
{
  "schema_version": "1",
  "run_id":         "20260424T062930Z",
  "mode":           "local",                 // or "aws"
  "started_at":     "2026-04-24T06:29:30Z",
  "finished_at":    "2026-04-24T06:30:43Z",
  "duration_sec":   69.93,

  "bench": {                                 // the orchestrator binary itself
    "version":    "dev",                     // -X .../version.Version
    "git_sha":    "142744e37ca4135d142cd0e58e337cc10568aa2b",
    "git_dirty":  true,
    "build_time": "2026-04-24T06:33:51Z",
    "go_version": "go1.26.2"
  },

  "git": {                                   // the source tree at run time
    "sha":     "142744e37ca4135d142cd0e58e337cc10568aa2b",
    "dirty":   true,
    "branch":  "main",
    "remote":  "git@github.com:wallarm/gateway-benchmarks.git",
    "has_git": true
  },

  "host": {                                  // loadgen host (operator's box / AWS loadgen EC2)
    "os":       "darwin", "arch": "arm64",
    "num_cpu":  14,
    "hostname": "...",
    "kernel":   "Darwin 25.4.0 arm64"
  },

  "k6": {                                    // pinned by digest in scripts/load-gateway.sh
    "image":  "grafana/k6:1.7.1@sha256:4fd3a694926b064d3491d9b02b01cde886583c4931f1223816e3d9a7bdfa7e0f",
    "digest": "sha256:4fd3a694926b064d3491d9b02b01cde886583c4931f1223816e3d9a7bdfa7e0f"
  },

  "gateways": [                              // one entry per gateway in the sweep
    {
      "name":         "nginx",
      "image":        "nginx:1.27.3-alpine@sha256:814a8e88df978ade80e584cc5b333144b9372a8e3c98872d07137dbf3b44d0e4",
      "digest":       "sha256:814a8e88df978ade80e584cc5b333144b9372a8e3c98872d07137dbf3b44d0e4",
      "source":       "registry",            // "registry" | "compose-resolved-or-built-from-src"
      "compose_path": ".../gateways/nginx/docker-compose.yaml"
    }
  ],

  "seed":         42,                        // forwarded to k6 as BENCH_RUN_SEED
  "repetitions":  1,
  "stop_on_fail": false,
  "selected_rows": [                         // one entry per (gateway, policy, load, scenario[, rep])
    "nginx/p01-vanilla/p1-baseline/s01-vanilla-http"
  ],

  "notes": "Phase 6 MVP smoke"               // from --notes flag (free-form)
}
```

Inspect any past run with:

```bash
make bench-manifest                         # latest run
make bench-manifest BENCH_RUN_ID=<id>       # specific run
# or directly:
orchestrator/bin/bench manifest --latest
orchestrator/bin/bench manifest --run-id <id>
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
