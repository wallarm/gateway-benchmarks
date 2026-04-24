# Reproducibility

> What it takes for two independent runs to produce **the same
> ranking** within tolerance. Phase 8 ships both the pinning
> (manifest / seed / digest) **and** the gate that proves two runs
> actually agree: `bench compare-runs`.

## TL;DR — the reproducibility gate

```bash
# Two runs on the same SHA, same hardware, same matrix:
make perf-local-run BENCH_RUN_ID=run-a
make perf-local-run BENCH_RUN_ID=run-b

# The Phase-8 quality gate:
make bench-compare-runs BENCH_COMPARE_A=run-a BENCH_COMPARE_B=run-b
#   exit 0 → REPRODUCIBLE
#   exit 1 → SOFT DIFF (matrix shape changed, one side has extra cells)
#   exit 2 → NOT REPRODUCIBLE (identity mismatch, metric outside tolerance,
#                              or top-3 rank unstable)
```

A run that fails `compare-runs` is a **release blocker** and must be
triaged before its HTML report is published.

---

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

---

## Verifying reproducibility — `bench compare-runs`

The Phase-8 gate diffs two bench runs against the canonical tolerance
table and answers three questions:

1. **Identity** — do the manifests agree on the invariants that *must*
   be byte-identical? `git_sha`, `seed`, `k6_digest`, `selected_rows`
   (matrix shape), and the per-gateway image digests.
2. **Numeric similarity** — for every matched cell, does each metric
   stay within its configured tolerance? The defaults live one level
   below (§Tolerances).
3. **Ranking stability** — for every (policy, load, scenario) column,
   does the **top-3** gateway order agree across runs?

Invocation:

```bash
# Via the orchestrator binary:
orchestrator/bin/bench compare-runs run-a run-b

# Via make (stops early with a clear error if either id is missing):
make bench-compare-runs BENCH_COMPARE_A=run-a BENCH_COMPARE_B=run-b

# JSON for CI pipelines (same data as the human report):
orchestrator/bin/bench compare-runs run-a run-b --json

# Override tolerances (fractions, not percentages):
orchestrator/bin/bench compare-runs run-a run-b \
    --rps 0.02 --latency 0.05 --mem 0.03

# Explicit cells.jsonl paths (useful for stitched / historical runs):
orchestrator/bin/bench compare-runs \
    --input-a reports/combined-pathA-p1-baseline/cells.jsonl \
    --input-b reports/pathA-20260423T090028Z/cells.jsonl
```

Exit codes:

| Code | Meaning            | When it fires |
|------|--------------------|---------------|
| `0`  | `REPRODUCIBLE`     | identity ✓, every metric within tolerance, top-3 stable |
| `1`  | `SOFT DIFF`        | shape mismatch (only-in-A / only-in-B cells) but identity + tolerance still hold where both sides are present |
| `2`  | `NOT REPRODUCIBLE` | identity mismatch, metric outside tolerance, or top-3 rank flipped |

The exit code is propagated by `make bench-compare-runs` so the gate
drops straight into CI without extra glue.

### Human-readable output

```
compare-runs: run-a  ↔  run-b
────────────────────────────────────────────────────────────────────
identity
  ✓ git_sha            142744e37ca4135d142cd0e58e337cc10568aa2b
  ✓ seed               42
  ✓ k6_digest          sha256:4fd3a69…
  ✓ selected_rows      48 rows
  ✓ gateway_digests    7 gateways

cells: matched=48  only-in-A=0  only-in-B=0  divergent=1
  ✗ nginx/p04-rl-static/p1-baseline/s04-rl-static-http  verdictA=PASS verdictB=PASS
      rps          A=50538.89rps  B=42958.05rps  rel=15.00% (tol=±3.00%)

rank stability: top-3 agrees on every column ✓

verdict: NOT REPRODUCIBLE — metric outside tolerance  (exit=2)
```

When both manifests are missing (historical / stitched runs from
before Phase 6) the identity block is skipped with a single
`SKIP — manifest.json missing on one or both runs` line and the
exit code is driven entirely by the numeric + rank comparison.

---

## Tolerances (TASK §8)

These are the defaults `bench compare-runs` applies when no flag is
passed. Fractions (not percentages) so the CLI and the docs stay in
lockstep.

| Metric                       | Tolerance | Flag         | Rationale |
|------------------------------|-----------|--------------|-----------|
| RPS (throughput)             | ±3 %      | `--rps`      | k6 closed-loop variance across clean runs stays under ~1 %; 3 % absorbs thermal noise on Apple Silicon and rack neighbour jitter in AWS. |
| Latency p50, p95, p99        | ±10 %     | `--latency`  | Tail latency is more variable than RPS; 10 % is the tightest band we can defend across both Docker Desktop and EC2. |
| Memory peak                  | ±5 %      | `--mem`      | Capturing genuine regressions (e.g. a new worker per CPU) while tolerating normal allocator drift. |
| Memory steady-state          | ±5 %      | `--mem`      | Same rationale; `bench compare-runs` averages the steady window. |
| CPU %                        | ±10 %     | `--cpu`      | Docker stats sampling jitter; peaks are especially noisy on macOS. |
| Errors 5XX absolute          | must match | `--errors-strict=false` lifts the strict gate | A 5xx is a policy break, not noise. |
| Errors 4XX-expected          | must match | same        | Expected 4xx lives on policy boundaries (p04/p06/p07 rate limits, p02/p03 auth) — it is *the* verifiable signal. |
| Rank top-3 (per column)      | must match | n/a         | Ranking is the product of the benchmark; if it flips, the benchmark is not reproducible. |

Internal defaults live in
[`orchestrator/internal/compare/compare.go · DefaultTolerances()`](../orchestrator/internal/compare/compare.go);
the table above is the single source of truth that both the code
and the CLI `--help` quote.

---

## Factors we cannot eliminate

- **EC2 noisy neighbour**: even inside a cluster placement group a
  small jitter from rack neighbours is possible. Mitigation — 2
  repetitions (`bench run --reps 2`) and take the median; keep the
  per-cell watchdog conservative so a slow neighbour cannot bleed
  into the next cell.
- **Thermal throttling in local mode**: Docker Desktop on macOS does
  not guarantee CPU pinning. Mitigation — local mode is explicitly
  tagged `less-reliable`; the local ranking is distinct from AWS
  (though the top-3 typically agree, see the AWS canonical playbook
  below).
- **Upstream availability** (Kong pulls especially): if hub.docker.com
  is unreachable, the run aborts and is reported as `prereq_failed`.
- **Wallarm built-from-source**: the benchmark runs the in-tree build
  addressed by the `WALLARM_IMAGE` tag. Two runs that differ only in
  `WALLARM_IMAGE` are apples-to-oranges and `compare-runs` correctly
  flags the `gateway_digests` identity check.

---

## AWS canonical-run playbook (Phase 9 preview)

The first public report in `v0.1.0` is produced by running the
following sequence on an AWS cluster provisioned by
`infra/aws/` (Phase 5). The playbook is reproducible by any
operator with the right IAM credentials and serves double duty as
the acceptance test for Phases 5 + 6 + 7 + 8 together.

```bash
# 1. Bring up the 3-EC2 cluster placement group (Phase 5):
make perf-aws-init
make perf-aws-deploy

# 2. Full HTTP matrix, 2 repetitions, seed pinned (Phase 6 orchestrator):
make perf-aws-run \
    BENCH_RUN_ID=v0.1.0-aws-a \
    BENCH_REPS=2 \
    BENCH_SEED=42 \
    BENCH_NOTES="v0.1.0 canonical run A — 3×c6i.2xlarge, cluster PG, seed=42"

# 3. Second independent run — different timestamp, same everything else:
make perf-aws-run \
    BENCH_RUN_ID=v0.1.0-aws-b \
    BENCH_REPS=2 \
    BENCH_SEED=42 \
    BENCH_NOTES="v0.1.0 canonical run B — reproducibility witness"

# 4. Gate: the two runs must be REPRODUCIBLE:
make bench-compare-runs \
    BENCH_COMPARE_A=v0.1.0-aws-a \
    BENCH_COMPARE_B=v0.1.0-aws-b

# 5. Render the canonical HTML from run A:
make perf-aws-report BENCH_RUN_ID=v0.1.0-aws-a

# 6. Tear down the cluster (Phase 5):
make perf-aws-destroy
```

Gate output for step 4 is archived into the release notes alongside
the HTML report. A run pair that fails step 4 must be triaged and
re-collected before `v0.1.0` is tagged.

---

## Status

- **Phase 6** — manifest + seed + digest pinning: `DONE` (see
  `orchestrator/internal/manifest`).
- **Phase 7** — HTML reproducible straight from `cells.jsonl`: `DONE`
  (see `orchestrator/internal/report`).
- **Phase 8** — `bench compare-runs` quality gate + canonical
  tolerance table + this playbook: **`DONE`**.
- **Phase 9** — first canonical AWS run + `v0.1.0` release: **NEXT**.
