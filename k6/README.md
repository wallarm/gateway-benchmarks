# k6 — Load Framework

k6 scripts that drive **4 load profiles × 14 policy/protocol scenarios
× 7 gateways = 392 cells** per run, per [TASK.md §§4–7](../TASK.md)
and [docs/POLICIES.md](../docs/POLICIES.md). The scenarios mirror the
12-policy matrix one-for-one (so the load run exercises the
exact policy shapes parity attestation already verified) plus the
two HTTPS variants from `docs/POLICIES.md § p01-tls / p12-tls`.

## Status

> **Phase 4 — Iteration 32: path-A breadth + scale sweeps complete.**
> All 7 gateways swept on `p1-baseline` (80/84 PASS + 3 EXCLUDED +
> 1 FAIL), plus `nginx × 12 × p2-sustained` (12/12 PASS after a
> targeted repair). Paced-arrivals twin profiles and HTTPS scenarios
> landed as init-guarded shells (dead until Phase 5 TLS plumbing).
> Cross-run aggregator (`scripts/aggregate-multi-csv.sh` +
> `make load-combine`) rolls N runs into one wide CSV: see
> `reports/combined-pathA-p1-baseline/matrix.csv`
> (83 cells × 27 columns) and
> `reports/combined-pathA-nginx-p2/matrix.csv`
> (12 cells × 27 columns). Iteration 31 landed the 12 HTTP scenarios
> + matrix harness + hot-path access-log silence sweep.

| Component                                      | Status  | Notes                                                                          |
|------------------------------------------------|---------|--------------------------------------------------------------------------------|
| `k6/lib/{env,options,jwt,payloads,metrics}.js` | landed  | helpers + 4-bucket error classifier per `TASK.md §8`; RS256 twin for `jwks-*`  |
| `k6/profiles/{p1,p2,p3,p4}-*.js`               | landed  | all 4 closed-loop load profiles wired                                          |
| `k6/profiles/{p1c,p2c,p3c,p4c}-paced.js`       | landed  | paced-arrivals twins (constant/ramping-arrival-rate) — opt-in by `-paced` slug |
| `k6/scenarios/s01-vanilla-http.js`             | landed  | smoke: 1.4M reqs / 60s on nginx, p95 = 1.23 ms, 0 failures                     |
| `k6/scenarios/s02-jwt-http.js`                 | landed  | HS256 JWT + happy-path 200; smoke: 1.33M / 60s on nginx, p95 = 1.27 ms         |
| `k6/scenarios/s03-jwks-rs256-basic-http.js`    | landed  | RS256 / JWKS kid-lookup; runner mints via `gen-jwt-rs256.sh valid`             |
| `k6/scenarios/s04-rl-static-http.js`           | landed  | service-wide 1000 rps; expects mixed 200 + 429                                 |
| `k6/scenarios/s05-rl-endpoint-http.js`         | landed  | 100 rps scoped to `/anything/limited`; `/anything/free` must stay 200          |
| `k6/scenarios/s06-rl-dynamic-low-http.js`      | landed  | 10 rps × 100-IP pool (init-time deterministic)                                 |
| `k6/scenarios/s07-rl-dynamic-high-http.js`     | landed  | 100 rps × 50k-IP pool (on-the-fly)                                             |
| `k6/scenarios/s08-req-headers-http.js`         | landed  | header add+drop on request                                                     |
| `k6/scenarios/s09-resp-headers-http.js`        | landed  | header add+drop on response                                                    |
| `k6/scenarios/s10-req-body-http.js`            | landed  | JSON add+drop on request body                                                  |
| `k6/scenarios/s11-resp-body-http.js`           | landed  | JSON add+drop on response body                                                 |
| `k6/scenarios/s12-full-pipeline-http.js`       | landed  | composition of p02 + p03 + p07 + p09 + p08 + p10                               |
| `k6/scenarios/s13-vanilla-https.js`            | landed — dead until Phase 5 TLS plumbing | drives `p01-vanilla` over TLS; init-throws on empty / non-`https://` `BENCH_TARGET_URL_HTTPS` |
| `k6/scenarios/s14-full-pipeline-https.js`      | landed — dead until Phase 5 TLS plumbing | drives `p12-full-pipeline` over TLS; widens `http_req_duration` p95 to 240 ms (+20% of s12) |
| `scripts/load-gateway.sh`                      | landed  | mirrors `scripts/parity-gateway.sh` lifecycle; runs docker-stats sidecar       |
| `scripts/docker-stats-sidecar.sh`              | landed  | per-second Docker REST sampler → `docker-stats.csv` per cell                   |
| `scripts/load-orchestrator.sh`                 | landed  | matrix sweep: gateways × policies × scenarios × loads → `matrix.tsv`           |
| `scripts/aggregate-csv.sh`                     | landed  | walks `reports/<RUN_ID>/raw/**` → wide CSV (or TSV / Markdown)                 |
| `make load-gateway[-load-sweep]`               | landed  | single-cell runner                                                             |
| `make load-sweep / load-aggregate`             | landed  | full matrix sweep + aggregator                                                 |

## Layout

```
k6/
├── README.md                       (this file)
├── lib/                            shared helpers
│   ├── env.js                      single source of truth for env vars
│   ├── options.js                  load-profile dispatch (BENCH_LOAD_PROFILE → options)
│   ├── jwt.js                      reads pre-minted HS256 token from env
│   ├── payloads.js                 canonical request bodies (mirrors fixtures/)
│   └── metrics.js                  custom counters: 2xx / 4xx-expected / 4xx-other / 5xx
├── profiles/                       4 closed-loop + 4 paced-arrivals (TASK §5, docs/LOAD-PROFILES.md)
│   ├── p1-baseline.js              constant 10 VUs × 60s
│   ├── p1c-paced.js                constant 500 RPS × 60s                              [paced twin of p1]
│   ├── p2-sustained.js             constant 100 VUs × 5m
│   ├── p2c-paced.js                constant 2 000 RPS × 5m                             [paced twin of p2]
│   ├── p3-ramp.js                  10 → 100 → 300 → 500 (3×60s) → hold 180s → 0 (60s)
│   ├── p3c-paced.js                500 → 2k → 5k → 10k RPS (3×60s) → hold 180s → 0 (60s) [paced twin of p3]
│   ├── p4-stress.js                constant 1000 VUs × 120s
│   └── p4c-paced.js                constant 20 000 RPS × 120s                          [paced twin of p4]
└── scenarios/                      14 scenarios (one per policy + 2 HTTPS variants)
    ├── s01-vanilla-http.js              drives p01-vanilla              [LANDED]
    ├── s02-jwt-http.js                  drives p02-jwt                  [LANDED]
    ├── s03-jwks-rs256-basic-http.js     drives p03-jwks-rs256-basic     [LANDED]
    ├── s04-rl-static-http.js            drives p04-rl-static            [LANDED]
    ├── s05-rl-endpoint-http.js          drives p05-rl-endpoint          [LANDED]
    ├── s06-rl-dynamic-low-http.js       drives p06-rl-dynamic-low       [LANDED]
    ├── s07-rl-dynamic-high-http.js      drives p07-rl-dynamic-high      [LANDED]
    ├── s08-req-headers-http.js          drives p08-req-headers          [LANDED]
    ├── s09-resp-headers-http.js         drives p09-resp-headers         [LANDED]
    ├── s10-req-body-http.js             drives p10-req-body             [LANDED]
    ├── s11-resp-body-http.js            drives p11-resp-body            [LANDED]
    ├── s12-full-pipeline-http.js        drives p12-full-pipeline        [LANDED]
    ├── s13-vanilla-https.js             drives p01 over TLS             [LANDED — Phase 5]
    └── s14-full-pipeline-https.js       drives p12 over TLS             [LANDED — Phase 5]
```

Total when complete: **56 cells per gateway** (12 HTTP scenarios × 4
load profiles + 2 HTTPS scenarios × 4 load profiles), **× 7 gateways
= 392 cells per run** (per `TASK.md §7`).

## How a run is assembled

`scripts/load-gateway.sh` is the canonical entry point — the
orchestrator (Phase 6) will call it once per cell, the operator
calls it via `make load-gateway` for ad-hoc smoke runs.

Lifecycle (mirrors `scripts/parity-gateway.sh` byte-for-byte on
shape, so the two harnesses converge cleanly when the orchestrator
fans them out):

```
                      ┌─────────────────────────────────────────┐
                      │ 1. docker compose up gateway + backend │
                      ├─────────────────────────────────────────┤
                      │ 2. wait for data plane on host :9080    │
                      ├─────────────────────────────────────────┤
                      │ 3. gateways/<gw>/<policy>/setup.sh      │
                      ├─────────────────────────────────────────┤
                      │ 4. parity-attestation.sh (precondition):│
                      │      PASS  → continue                   │
                      │      else  → emit excluded.json, skip   │
                      ├─────────────────────────────────────────┤
                      │ 5. mint JWT(s) on host (gen-jwt.sh)     │
                      │      only when scenario needs them      │
                      ├─────────────────────────────────────────┤
                      │ 6. docker run grafana/k6 on bench-net   │
                      │      mounts k6/ ro and reports/ rw      │
                      │      env: BENCH_TARGET_URL=             │
                      │           http://gateway:9080           │
                      │           BENCH_LOAD_PROFILE=...        │
                      │           BENCH_POLICY_PROFILE=...      │
                      │           BENCH_SCENARIO=...            │
                      │           BENCH_GATEWAY=...             │
                      │           BENCH_RUN_ID=...              │
                      │           BENCH_RUN_SEED=42             │
                      │           BENCH_JWT_VALID=<token>       │
                      │      output: --summary-export +         │
                      │              optional --out json= stream│
                      ├─────────────────────────────────────────┤
                      │ 7. trap-based docker compose down       │
                      └─────────────────────────────────────────┘
```

## Output layout

Per cell, the runner writes one directory under
`reports/<RUN_ID>/raw/<gw>/<policy>__<load>__<scenario>/`:

```
k6-summary.json                 final summary export (k6 --summary-export)
k6-stream.json.gz               only when BENCH_STREAM_METRICS=1 (large)
parity.json                     the precondition result (PASS, with probes)
excluded.json                   only when the cell was skipped (FEATURE-MISSING
                                or parity-not-PASS); never co-exists with
                                k6-summary.json
logs/
├── compose.log                 docker compose logs, captured on teardown
├── k6.log                      full k6 stdout (progress bars + thresholds)
└── setup-feature-missing.txt   only when setup.sh reported FEATURE-MISSING
```

The orchestrator (Phase 6) walks `reports/<RUN_ID>/raw/**/*.json`,
groups by `(gateway, policy, load, scenario)` from the path, and
produces the executive ranking table per `docs/REPORT.md`.

## Environment surface

Every variable consumed by k6 — exhaustive list. The runner script
sets all of them; manual `k6 run` invocations must mirror the same
set or `k6/lib/env.js` will fail fast at init time.

| Variable                    | Required             | Default | Set by                                                                                |
|-----------------------------|----------------------|---------|---------------------------------------------------------------------------------------|
| `BENCH_TARGET_URL`          | yes                  | —       | runner: `http://gateway:9080`                                                         |
| `BENCH_LOAD_PROFILE`        | yes                  | —       | runner: `--load`                                                                      |
| `BENCH_POLICY_PROFILE`      | yes                  | —       | runner: `--policy`                                                                    |
| `BENCH_SCENARIO`            | yes                  | —       | runner: `--scenario`                                                                  |
| `BENCH_GATEWAY`             | yes                  | —       | runner: `--gateway`                                                                   |
| `BENCH_RUN_ID`              | yes                  | —       | runner: env `RUN_ID` or auto-timestamp                                                |
| `BENCH_RUN_SEED`            | no                   | `42`    | runner: `--seed`                                                                      |
| `BENCH_JWT_VALID`           | scenario-conditional | `""`    | runner: `gen-jwt.sh valid` when scenario name contains `jwt` / `full-pipeline`        |
| `BENCH_JWT_VALID_RS256`     | scenario-conditional | `""`    | runner: `gen-jwt-rs256.sh valid` when scenario name matches `*jwks*`                  |
| `BENCH_STREAM_METRICS`      | no                   | `0`     | runner: `--stream`                                                                    |

## k6 version

Pinned by digest: `grafana/k6:1.7.1@sha256:4fd3a694926b064d3491d9b02b01cde886583c4931f1223816e3d9a7bdfa7e0f`
(multi-arch index from Docker Hub, covering linux/amd64 + linux/arm64).

Refresh:

```bash
docker pull grafana/k6:1.7.1
docker buildx imagetools inspect grafana/k6:1.7.1 --format "{{.Manifest.Digest}}"
```

## Quick run (smoke)

```bash
make load-gateway \
    LOAD_GATEWAY=nginx \
    LOAD_POLICY=p01-vanilla \
    LOAD_SCENARIO=s01-vanilla-http \
    LOAD_PROFILE=p1-baseline
```

Sweep all 4 load profiles for one (gateway, policy, scenario):

```bash
make load-gateway-load-sweep \
    LOAD_GATEWAY=nginx \
    LOAD_POLICY=p01-vanilla \
    LOAD_SCENARIO=s01-vanilla-http
```

Reference smoke results (Iteration 32, p1-baseline closed-loop
10 VUs × 60 s, Apple Silicon Docker Desktop) — full cross-gateway
breadth for `p01-vanilla` and the composite `p12-full-pipeline`:

| gateway | p01 RPS | p01 p95 (ms) | p12 RPS | p12 p95 (ms) |
|---------|--------:|-------------:|--------:|-------------:|
| tyk     | 32 331  | sub-ms       | *excl.* | *excl.*      |
| nginx   | 21 946  | 1.16         | 49 380  | 0.33         |
| wallarm | 21 876  | 0.97         | 36 800  | 0.40         |
| apisix  | 19 875  | 1.31         | 34 532  | 0.47         |
| kong    | 18 788  | 1.38         | 28 935  | 0.72         |
| envoy   | 18 100  | 1.06         |  1 261  | 0.95         |
| traefik | 17 272  | 1.40         | 33 199  | 0.61         |

RPS on `p12-full-pipeline` sits above `p01-vanilla` for most
gateways because the composed pipeline includes rate-limit buckets
(p04 + p06) and 429 rejects are cheaper than full-proxy 200s.
Envoy's p12 collapse to 1.3k RPS is genuine — every composed
policy runs through a separate Lua filter with serial string
manipulation. See `reports/combined-pathA-p1-baseline/matrix.csv`
for the full 83-cell roll-up.

## Full matrix sweep

`scripts/load-orchestrator.sh` fans the runner out across a
gateways × policies × loads × scenarios matrix and writes one
`matrix.tsv` summary plus per-cell `reports/<RUN_ID>/raw/<gw>/<cell>/`.

```bash
make load-sweep \
    LOAD_GATEWAY=nginx \
    LOAD_POLICIES=p01-vanilla,p02-jwt \
    LOAD_LOADS=p1-baseline \
    LOAD_SEED=42

make load-aggregate LOAD_RUN_ID=<run-id> LOAD_FORMAT=csv
```

Omitting `LOAD_POLICIES` runs all 12 (`p01..p12`), and each policy
is paired with its canonical `sNN-<slug>-http` scenario from the
table above (e.g. `p04-rl-static → s04-rl-static-http`). Drop
`LOAD_STOP_ON_FAIL=1` to abort the sweep on the first non-PASS cell.

The aggregator walks `reports/<RUN_ID>/raw/**` and emits one wide
row per cell: all k6 latency quantiles (p50/p90/p95/p99/max), RPS,
the 4-bucket error split, check counts, plus peak + steady-state
memory (`mem_rss_peak` / `mem_rss_steady`) and CPU percentages
(`cpu_pct_peak` / `cpu_pct_steady`) sampled by the
`docker-stats-sidecar`.

## Cross-run roll-up

`make load-combine LOAD_RUN_IDS=a,b,c LOAD_OUTPUT=path LOAD_FORMAT=md`
(wrapper around `scripts/aggregate-multi-csv.sh`) concatenates N
per-run matrices into one wide file. It auto-regenerates any
per-run CSV that is stale or missing, so the typical flow is:

```bash
# 7 independent runs (one per gateway, same load profile)
for gw in nginx wallarm envoy traefik kong apisix tyk; do
  make load-sweep LOAD_GATEWAY=$gw LOAD_LOADS=p1-baseline \
      LOAD_RUN_ID=pathA-p1-$gw-$(date -u +%Y%m%dT%H%M%SZ)
done

# roll them into one wide report
make load-combine \
    LOAD_RUN_IDS=pathA-p1-nginx-…,pathA-p1-wallarm-…,… \
    LOAD_OUTPUT=reports/combined-pathA-p1-baseline/matrix.csv
```

## Known gaps (not blockers — recorded for cycle-to-cycle planning)

1. **Closed-loop vs paced arrivals** — the four canonical profiles
   (`p1-baseline`, `p2-sustained`, `p3-ramp`, `p4-stress`) use
   `constant-vus` / `ramping-vus`, which is closed-loop (a faster
   gateway gets more iterations because each VU cycles faster). That
   is how every public API-gateway benchmark we cross-referenced
   (`api7/apisix-benchmark`, `Kong/insomnia`,
   `jkaninda/goma-gateway-vs-traefik`) configures k6, so relative
   ranking is apples-to-apples with the prior art. For
   absolute-RPS-vs-target claims (e.g. "gateway X sustains 10k RPS"),
   four paced twins have landed alongside: `p{1,2,3,4}c-paced` use
   `constant-arrival-rate` / `ramping-arrival-rate` with a 50%-wider
   `http_req_duration` p(95) budget and a `dropped_iterations` threshold
   (see `docs/LOAD-PROFILES.md § Paced-arrivals variants`). The
   `-paced` suffix in the profile slug is the gate — no separate env
   var. `p1c-paced` and `p2c-paced` run on a developer laptop;
   `p3c-paced` and `p4c-paced` need a dedicated Linux bench host with
   raised `ulimit -n` (≥65 536) and `net.core.somaxconn`.
2. **HTTPS scenarios (s13, s14)** — `s13-vanilla-https.js` and
   `s14-full-pipeline-https.js` are landed but dormant: they
   `throw` at init unless `BENCH_TARGET_URL_HTTPS` is an `https://`
   URL, and the canonical policy → scenario mapping
   (`p01 → s01-vanilla-http`, `p12 → s12-full-pipeline-http`) keeps
   HTTP as the default. Phase 5 lands the TLS plumbing (cert chain
   under `gateways/_reference/tls/`, `listen 443 ssl;` in each
   gateway config, `:8443` exposed in `docker-compose.yaml`) and
   flips the switch.
3. **Orchestrator ≠ Phase 6** — `scripts/load-orchestrator.sh` is
   the minimal shell-only harness for Path-A local runs. Phase 6
   replaces it with a Go binary that also writes the
   `docs/REPRODUCIBILITY.md` manifest, handles multi-repetition
   runs + tolerance gating, and drives AWS topology.

See [docs/LOAD-PROFILES.md](../docs/LOAD-PROFILES.md) and
[docs/POLICIES.md](../docs/POLICIES.md) for the canonical specs.
