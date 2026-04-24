# orchestrator — `bench` (Phases 6 + 7 + 8)

`bench` is the Go-native orchestrator that drives the
**(gateway × policy × scenario × load)** matrix end-to-end,
renders the canonical HTML report, and ships the Phase-8
reproducibility gate:

1. **Builds a manifest** stamped with the source revision, image
   digests, k6 image, host info and seed.
2. For every cell —
   - runs `scripts/parity-attestation.sh` first (cells that don't pass
     parity are marked `EXCLUDED` for `FEATURE_MISSING` or `FAIL` for
     genuine deviations and are NOT loaded);
   - then `scripts/load-gateway.sh` which brings the gateway up,
     runs k6, captures `docker stats`, parity, and tears the gateway
     down;
   - records the verdict + duration into an append-only checkpoint
     so an interrupted sweep can resume.
3. **Aggregates** every per-cell `k6-summary.json` + `docker-stats.csv`
   + `parity.json` into the canonical 27-column wide table:
   - `reports/<run-id>/matrix.csv`
   - `reports/<run-id>/cells.jsonl` (superset with derived
     `health` / `timing_broken` columns)
   - `reports/<run-id>/matrix.md` (short rollup)
4. **Renders a self-contained HTML report** straight from
   `cells.jsonl` + `manifest.json` via `bench report` — embedded
   CSS/JS and a Chart.js CDN bundle, no Python toolchain required.
   `bench run` calls it automatically (toggle with `--report=false`).
5. **Proves two runs are reproducible** via `bench compare-runs` —
   identity checks (git SHA, seed, k6 digest, matrix shape,
   per-gateway digests), per-cell metric tolerance (TASK §8), and
   top-3 rank stability per (policy, load, scenario) column. Exit
   codes: `0 REPRODUCIBLE · 1 SOFT DIFF · 2 NOT REPRODUCIBLE`.

It deliberately wraps the proven shell drivers — Phase 4 already
proved them across 248 production runs — and focuses on the parts
the shell version couldn't do well: manifest pinning, atomic
checkpoint, watchdog timeouts, typed `cells.jsonl`, a single
`bench` binary that produces both the data and the publishable
report, and a one-command reproducibility gate.

## Build

```bash
make orchestrator-build         # → orchestrator/bin/bench
make orchestrator-vet           # go vet
make orchestrator-test          # go test -race -count=1 ./...
```

The Makefile injects build-time metadata via `-ldflags`:

```
-X .../version.Version=$(ORCH_VERSION)
-X .../version.GitSHA=$(git rev-parse HEAD)
-X .../version.GitDirty=true|false
-X .../version.BuildTime=$(date -u +%Y-%m-%dT%H:%M:%SZ)
```

`bench version` prints all of those at runtime so the binary in
`reports/<run-id>/` is always traceable to the exact source SHA
that produced it.

## Commands

```bash
bench run          # parity → load → aggregate → manifest → report (one or many cells)
bench validate     # parity-only sweep (no load) — useful for stack health
bench aggregate    # re-run the projection after a manual sweep
bench report       # render reports/<run-id>/report.html from cells.jsonl + manifest.json
bench compare-runs # Phase 8 — diff two runs against the canonical tolerance table
bench manifest     # cat the manifest.json of the latest (or specified) run
bench version      # print build info
```

### `bench run`

```bash
bench --run-id 20260424T120000Z run \
  --gateways nginx,wallarm,kong \
  --policies all \
  --loads    p1-baseline,p2-sustained \
  --reps     1 \
  --target   http://localhost:9080 \
  --notes    "Phase 6 smoke run on local stack"
```

Aliases:

| flag value           | expands to                          |
| -------------------- | ----------------------------------- |
| `--gateways all`     | nginx, wallarm, envoy, traefik, kong, apisix, tyk |
| `--policies all`     | p01-vanilla … p12-full-pipeline (12 cells) |
| `--policies core`    | same as `all` (forward-compat alias) |
| `--loads http`       | p1-baseline, p2-sustained, p3-ramp, p4-stress |
| `--loads paced`      | p1c-paced, p2c-paced, p3c-paced, p4c-paced |
| `--loads all`        | both — closed-loop + paced-arrivals |

Other useful flags:

| flag                       | default | purpose |
| -------------------------- | ------- | ------- |
| `--seed <int>`             | 42      | RNG seed forwarded to k6 (BENCH_RUN_SEED) |
| `--reps <n>`               | 1       | repetitions per cell |
| `--mode local|aws`         | local   | annotation only — written into manifest |
| `--watchdog-mins <n>`      | 30      | per-cell timeout in minutes (0 = disable) |
| `--stop-on-fail`           | off     | halt sweep on first FAIL/CRASHED/TIMEOUT |
| `--resume`                 | off     | skip cells already recorded in checkpoint.jsonl |
| `--skip-parity`            | off     | DEBUG only — bypass parity gate |
| `--target <url>`           | empty   | override gateway URL forwarded to parity |
| `--backend-peek <url>`     | empty   | optional probe of the upstream backend |
| `--dry-run`                | off     | print the planned cells and exit |

### `bench validate`

Parity-only — useful for verifying a freshly brought-up stack without
spending a load budget on it:

```bash
bench validate --gateways nginx --policies all --target http://localhost:9080
```

Outputs `parity.json` per `(gateway, policy)` under
`reports/<run-id>/raw/<gateway>/<policy>__validate__<scenario>/`.

### `bench aggregate`

Replays the wide-table projection from any directory of raw cells.
Same column schema as the legacy `scripts/aggregate-csv.sh`, plus
the JSONL output the Phase 7 report generator will consume:

```bash
bench aggregate --run-id 20260424T120000Z
# wrote 84 cells
#   csv:   reports/20260424T120000Z/matrix.csv
#   jsonl: reports/20260424T120000Z/cells.jsonl
#   md:    reports/20260424T120000Z/matrix.md
```

### `bench report`

Renders the canonical HTML report — Executive Summary, Memory
Footprint grid, radar chart, and one tab per policy with RPS /
latency / memory charts plus an end-to-end results table — directly
from `cells.jsonl` (and, when present, `manifest.json`).

```bash
# Single run (most common — `bench run` calls this automatically):
bench report --run-id 20260424T120000Z

# Latest run in reports/:
bench report --latest

# Combine several smaller sweeps into one report
# (handy for "one column per gateway" runs you stitched together):
bench report \
  --combined pathA-p1-nginx-...,pathA-p1-wallarm-...,pathA-p1-envoy-... \
  --output reports/combined-pathA-p1-baseline/report.html \
  --title "API Gateway Benchmark — Path A baseline"
```

Useful flags:

| flag                              | default | purpose |
| --------------------------------- | ------- | ------- |
| `--run-id <id>`                   | ø       | render `reports/<id>/report.html` |
| `--latest`                        | off     | pick the newest `reports/*/cells.jsonl` |
| `--combined <id1,id2,...>`        | ø       | merge multiple `cells.jsonl` files |
| `--input <path>`                  | ø       | explicit `cells.jsonl` to read |
| `--output <path>`                 | auto    | override the destination HTML file |
| `--title "<text>"`                | auto    | hero / `<title>` text |
| `--env "<text>"`                  | ø       | single-line environment annotation |
| `--how-to-read "<text>"`          | default | replace the methodology blurb |
| `--unstable-threshold <fraction>` | 0.01    | cells above this 4xx_unexpected ratio get the dashed "unstable" outline |

The output is a single self-contained `report.html` (~50 KB for a
12-cell sweep): inline CSS/JS, all chart payloads serialised next
to the markup, only the Chart.js bundle is fetched from a CDN.

### `bench compare-runs`

The Phase-8 reproducibility gate. Consumes the `cells.jsonl` +
`manifest.json` of two runs and answers three questions:

1. **Identity** — do the manifests agree on `git_sha`, `seed`,
   `k6_digest`, `selected_rows` (matrix shape), and per-gateway
   image digests?
2. **Numeric tolerance** — for every matched cell, does each
   metric stay within the canonical tolerance
   (RPS ±3 %, latency p50/p95/p99 ±10 %, mem peak/steady ±5 %,
   CPU ±10 %; 5xx and 4xx_expected counts must match exactly)?
3. **Rank stability** — for every (policy, load, scenario) column,
   does the top-3 gateway order agree?

```bash
# Two runs on the same SHA:
bench compare-runs run-a run-b

# Exit codes:
#   0 → REPRODUCIBLE
#   1 → SOFT DIFF (only-in-A / only-in-B cells)
#   2 → NOT REPRODUCIBLE (identity, tolerance, or rank broke)

# JSON output for CI:
bench compare-runs run-a run-b --json

# Explicit cells.jsonl paths (historical / stitched runs):
bench compare-runs \
  --input-a reports/combined-pathA-p1-baseline/cells.jsonl \
  --input-b reports/pathA-20260423T090028Z/cells.jsonl

# Override a single tolerance (all fractions, not percentages):
bench compare-runs run-a run-b --rps 0.02 --latency 0.05
```

Flags:

| flag                  | default | purpose |
| --------------------- | ------- | ------- |
| `--input-a / --input-b` | ø     | explicit `cells.jsonl` path for each side |
| `--manifest-a / --manifest-b` | ø | explicit `manifest.json` paths |
| `--label-a / --label-b` | run ids | label printed in the report header |
| `--json`              | off     | emit the Summary struct as JSON |
| `--rps`               | 0.03    | fractional tolerance for RPS (±3 %) |
| `--latency`           | 0.10    | fractional tolerance for p50/p95/p99 (±10 %) |
| `--mem`               | 0.05    | fractional tolerance for peak + steady RSS (±5 %) |
| `--cpu`               | 0.10    | fractional tolerance for CPU % (±10 %) |
| `--errors-strict`     | true    | 5xx + 4xx_expected counts must match exactly |

See [`docs/REPRODUCIBILITY.md`](../docs/REPRODUCIBILITY.md) for the
canonical tolerance table, AWS canonical-run playbook, and the
v0.1.0 gate.

### `bench manifest`

Pretty-prints the manifest.json of the latest (or `--run-id`-pinned)
run:

```bash
bench manifest                    # latest reports/* directory
bench manifest --run-id 20260424T120000Z
```

## Output layout

For every `bench run` invocation:

```
reports/<run-id>/
├── manifest.json          # pinned source SHA, image digests, k6, host info, seed
├── matrix.csv             # 27-column wide table (canonical)
├── cells.jsonl            # JSONL superset, one Cell per line, health field added
├── matrix.md              # short markdown rollup (gateway × policy × verdict)
├── checkpoint.jsonl       # append-only record (resumable; use --resume)
├── report.html            # canonical HTML report (Phase 7) — self-contained
└── raw/
    └── <gateway>/
        └── <policy>__<load>__<scenario>/
            ├── k6-summary.json
            ├── docker-stats.csv
            ├── parity.json
            └── logs/
```

## Manifest schema (v1)

```jsonc
{
  "schema_version": "1",
  "run_id": "20260424T062930Z",
  "mode": "local",
  "started_at": "...", "finished_at": "...", "duration_sec": 69.93,
  "bench":   { "version": "dev", "git_sha": "...", "git_dirty": true,
               "build_time": "...", "go_version": "go1.26.2" },
  "git":     { "sha": "...", "dirty": true, "branch": "main",
               "remote": "git@github.com:wallarm/gateway-benchmarks.git", "has_git": true },
  "host":    { "os": "darwin", "arch": "arm64", "num_cpu": 14,
               "hostname": "...", "kernel": "Darwin 25.4.0 arm64" },
  "k6":      { "image": "grafana/k6:1.7.1@sha256:4fd3...",
               "digest": "sha256:4fd3..." },
  "gateways":[
    { "name": "nginx",
      "image": "nginx:1.27.3-alpine@sha256:...",
      "digest": "sha256:...",
      "source": "registry",
      "compose_path": ".../gateways/nginx/docker-compose.yaml" }
  ],
  "seed": 42,
  "repetitions": 1,
  "stop_on_fail": false,
  "selected_rows": [
    "nginx/p01-vanilla/p1-baseline/s01-vanilla-http"
  ],
  "notes": "Phase 6 MVP smoke"
}
```

## Architecture

```
                ┌────────────────────────────────────┐
   bench run -->│ matrix.Selection.Expand()          │
                └────────────────────────────────────┘
                           │ list of Cell{gw, policy, scenario, load, rep}
                           ▼
        ┌─────────────────────────────────────────┐
        │ for each cell:                           │
        │   parity.Checker.Check(...)              │  ← scripts/parity-attestation.sh
        │     ├ PASS  → run load                   │
        │     ├ FM    → mark EXCLUDED, skip load   │
        │     └ FAIL  → mark FAIL, skip load       │
        │   runner.Runner.Run(...)                 │  ← scripts/load-gateway.sh
        │   checkpoint.File.Append(result)         │  ← reports/<run>/checkpoint.jsonl
        └─────────────────────────────────────────┘
                           │
                           ▼
              aggregate.Aggregator.Collect()
                           │
                           ▼
              cells.jsonl  +  matrix.csv  +  matrix.md
                           │
                           ▼
                   manifest.Builder.Write()
                           │
                           ▼
                  reports/<run-id>/manifest.json
                           │
                           ▼               (Phase 7)
                  report.Render(loaded, …)
                           │
                           ▼
                  reports/<run-id>/report.html

                           +

                   run-a.cells.jsonl          (Phase 8)
                           │
                           │    run-b.cells.jsonl
                           ▼           │
                  compare.Compare(A, B, tol)
                           │
                           ▼
                  exit 0 | 1 | 2   (text or JSON)
```

## Status

✅ **Phase 6 — DONE.** Native Go orchestrator wraps the Phase 4
shell drivers, adds manifest pinning, atomic checkpoint, watchdog
timeouts, typed `cells.jsonl`, parity-gating, and a re-runnable
aggregator.

✅ **Phase 7 — DONE.** `bench report` renders the canonical
self-contained HTML report from `cells.jsonl` + `manifest.json`,
including the radar chart, per-policy RPS / latency / memory
panels, the timing-broken / unstable annotations, and the
unified executive summary. The Python prototype at
`scripts/render-html-report.py` is **deprecated** — kept in-tree
for one cycle so historical reports remain re-renderable, but no
new fixes will land there.

✅ **Phase 8 — DONE.** `bench compare-runs` diffs two runs
against the canonical tolerance table (identity ↔ per-cell
metric tolerance ↔ top-3 rank stability) and propagates a
three-way exit code so CI and `make bench-compare-runs` can
gate on reproducibility directly. The canonical tolerance table,
manifest schema, CLI reference, and AWS canonical-run playbook
for v0.1.0 live in
[`docs/REPRODUCIBILITY.md`](../docs/REPRODUCIBILITY.md); the
one-row-per-cell deviations rollup lives in
[`docs/GATEWAYS.md`](../docs/GATEWAYS.md#summary-table).

📌 Outstanding (post-Phase-8 polish, all tracked in `ROADMAP.md`):

- Native memory + bandwidth collectors that don't rely on the
  `docker stats` sidecar (so AWS runs can drop the sidecar on the
  gateway host).
- Watchdog → restart on gateway crash and tag the cell `CRASHED`
  (currently a crash terminates the cell as `FAIL`).
- Phase 9: execute the AWS canonical-run playbook, attach the
  resulting `report.html` + `compare-runs` verdict to a GitHub
  Release, tag `v0.1.0`.
