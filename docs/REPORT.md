# Report — How to Read It

> How to read `reports/<run>/report.html`. The structure of the sections follows TASK §6; an actual reference artefact will be produced in Phase 7.

## Sections

### 1. Hero

- **Rank** — top-7 by aggregate score (weighted RPS/p95 across every cell; formula in §4 below).
- **Run summary**: git SHA, seed, timestamp, total wall-clock time, number of cells.
- **Neutrality disclaimer** — linked to `README.md#neutrality-disclaimer`.

### 2. Executive Summary

A single table: 7 gateways × key metrics (aggregate RPS, aggregate p95, total errors, peak memory). Colour coding — green/yellow/red, threshold ±1σ around the median.

### 3. Run Parameters

Collapsed section with a "Show manifest" toggle. Inside: a link to manifest.json, git commit, and the matrix composition.

### 4. Matrix (the heart of the report)

A scrollable table with **7 rows × ≈52 columns** (11 policies × 4 load profiles × 2 protocols where applicable):

```
          │ p1-baseline ─┬─────────────┬─────────────┐ │ p2-sustained ─┬─ ...
          │ s01          │ s02         │ s03         │ │ s01           │
─────────┼──────────────┼─────────────┼─────────────┼─┼───────────────┼─
wallarm   │ RPS / p95    │ ...         │ ...         │ │ ...           │
nginx     │ ...          │ ...         │ ...         │ │ ...           │
envoy     │ ...          │ ...         │ ...         │ │ ...           │
...
```

Each cell shows a mini-sparkline across run seconds, and clicking expands a detail view.

### 5. Error Breakdown (TASK §6: 4 columns)

Per gateway:

| Metric | Description |
|--------|-------------|
| **5XX**               | Any 5XX — usually upstream unavailable or a crash |
| **4XX-expected**      | 401/403/429 under a policy (not counted as a gateway error) |
| **Client-side**       | k6 `connection refused`, `timeout`, `read: EOF` |
| **Excluded**          | TLS handshake failures, DNS failures (cell removed from the ranking) |

Visual: a stacked bar chart.

### 6. Memory & CPU

Two charts per gateway:
- **Memory peak + steady-state** (steady-state = median RSS over the last 30 s of the run)
- **CPU %** (mean and p95)

All 7 gateways on one axis — immediately shows who is the heaviest.

### 7. Tail Latency

Per-cell distribution chart: p50 / p90 / p95 / p99 / p99.9 / max. Emphasis on p99+ — that is where SLO violations live.

### 8. Parity Attestation Log

Table: per-cell `OK` / `DEVIATION` status. Deviations expand to the raw diff.

### 9. Deviations & Caveats

A copy of `docs/GATEWAYS.md#deviations`, plus run-specific notes (e.g. watchdog restarts).

---

## 4. Aggregate score formula

```
per_cell_score = RPS / p95_ms                        # higher is better
gateway_score  = median_cells(per_cell_score)        # robust to outliers
```

Additional penalties:

- `-50%` if the cell was CRASHed (gateway was restarted by the watchdog).
- `-20%` if `5XX > 1%` under a profile other than p4-stress (stress allows more).
- `-100%` (i.e. ranking `N/A`) if `parity_deviation=true` for the cell.

The formula is implemented in the orchestrator and can be recomputed independently of its author.

## 5. Where the raw data lives

Everything the aggregator ingested:

```
reports/<run>/raw/<gw>/<profile>__<scenario>/
├── k6-summary.json        # final summary
├── k6-stream.json.gz      # per-request time series (only when env STREAM=1)
├── docker-stats.json      # per-second resources
├── parity.json            # the parity attestation result for this cell
└── logs/
    ├── gateway-stdout.log
    ├── gateway-stderr.log
    └── watchdog-events.log  # if restarts happened
```

Anyone can open these files and recompute the metrics by hand.

## 6. Comparing two runs

`scripts/compare-runs.sh reports/A reports/B` → diff HTML in `reports/A_vs_B.html`.

See [REPRODUCIBILITY.md#verifying-reproducibility](./REPRODUCIBILITY.md#verifying-reproducibility).

## Status

> Stub. Implementation — Phase 7 (report generator) and Phase 8 (compare).
