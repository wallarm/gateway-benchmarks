# k6 — Load Framework

k6 scripts that drive **4 load profiles × 14 policy/protocol scenarios
× 7 gateways = 392 cells** per run, per [TASK.md §§4–7](../TASK.md)
and [docs/POLICIES.md](../docs/POLICIES.md). The scenarios mirror the
12-policy matrix one-for-one (so the load run exercises the
exact policy shapes parity attestation already verified) plus the
two HTTPS variants from `docs/POLICIES.md § p01-tls / p12-tls`.

## Status

> **Phase 4 — Iteration 29: framework foundation landed**, 1
> scenario green end-to-end against `nginx`. Remaining 13 scenarios
> are next iteration; HTTPS variants land alongside Phase 5 (TLS
> infrastructure). See `ROADMAP.md` and `.notes/PROGRESS.md` for
> the running journal.

| Component                              | Status       | Notes                                                          |
|----------------------------------------|--------------|----------------------------------------------------------------|
| `k6/lib/{env,options,jwt,payloads,metrics}.js` | landed   | helpers + 4-bucket error classifier per `TASK.md §8`           |
| `k6/profiles/{p1,p2,p3,p4}-*.js`        | landed       | all 4 load profiles wired                                      |
| `k6/scenarios/s01-vanilla-http.js`     | landed       | smoke-tested: 1.4M reqs / 60s on nginx, p95=1.23ms, 0 failures |
| `k6/scenarios/s02..s12-*-http.js`      | TODO         | one scenario per `pNN` policy; next iteration                  |
| `k6/scenarios/s{01,12}-*-https.js`     | TODO         | TLS variants; lands alongside Phase 5 cert plumbing            |
| `scripts/load-gateway.sh`              | landed       | mirrors `scripts/parity-gateway.sh` lifecycle                  |
| `make load-gateway[-load-sweep]`       | landed       | wraps the runner above                                          |

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
├── profiles/                       4 load profiles (TASK §5, docs/LOAD-PROFILES.md)
│   ├── p1-baseline.js              constant 10 VUs × 60s
│   ├── p2-sustained.js             constant 100 VUs × 5m
│   ├── p3-ramp.js                  10 → 100 → 300 → 500 (3×60s) → hold 180s → 0 (60s)
│   └── p4-stress.js                constant 1000 VUs × 120s
└── scenarios/                      14 scenarios (one per policy + 2 HTTPS variants)
    ├── s01-vanilla-http.js              drives p01-vanilla              [LANDED]
    ├── s02-jwt-http.js                  drives p02-jwt                  [TODO]
    ├── s03-jwks-rs256-basic-http.js     drives p03-jwks-rs256-basic     [TODO]
    ├── s04-rl-static-http.js            drives p04-rl-static            [TODO]
    ├── s05-rl-endpoint-http.js          drives p05-rl-endpoint          [TODO]
    ├── s06-rl-dynamic-low-http.js       drives p06-rl-dynamic-low       [TODO]
    ├── s07-rl-dynamic-high-http.js      drives p07-rl-dynamic-high      [TODO]
    ├── s08-req-headers-http.js          drives p08-req-headers          [TODO]
    ├── s09-resp-headers-http.js         drives p09-resp-headers         [TODO]
    ├── s10-req-body-http.js             drives p10-req-body             [TODO]
    ├── s11-resp-body-http.js            drives p11-resp-body            [TODO]
    ├── s12-full-pipeline-http.js        drives p12-full-pipeline        [TODO]
    ├── s13-vanilla-https.js             drives p01 over TLS             [TODO — Phase 5]
    └── s14-full-pipeline-https.js       drives p12 over TLS             [TODO — Phase 5]
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

| Variable                | Required | Default          | Set by                                    |
|-------------------------|----------|------------------|-------------------------------------------|
| `BENCH_TARGET_URL`      | yes      | —                | runner: `http://gateway:9080`             |
| `BENCH_LOAD_PROFILE`    | yes      | —                | runner: `--load`                          |
| `BENCH_POLICY_PROFILE`  | yes      | —                | runner: `--policy`                        |
| `BENCH_SCENARIO`        | yes      | —                | runner: `--scenario`                      |
| `BENCH_GATEWAY`         | yes      | —                | runner: `--gateway`                       |
| `BENCH_RUN_ID`          | yes      | —                | runner: env `RUN_ID` or auto-timestamp    |
| `BENCH_RUN_SEED`        | no       | `42`             | runner: `--seed`                          |
| `BENCH_JWT_VALID`       | scenario-conditional | `""` | runner: `gen-jwt.sh valid` when scenario name contains `jwt` or `full-pipeline` |
| `BENCH_STREAM_METRICS`  | no       | `0`              | runner: `--stream`                        |

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

Reference smoke result (Iteration 29, nginx p01 + p1-baseline + s01,
Apple Silicon Docker Desktop):

```
verdict:    PASS
reqs:       1417860            (1m of constant 10 VUs)
p95 (ms):   1.23
failed:     0                  (out of 1.4M)
checks:     100% (2.8M passes / 0 fails across 2 checks)
parity:     PASS (4/4 probes)
```

## Known gaps (not blockers — recorded for cycle-to-cycle planning)

1. **Closed-loop vs paced arrivals** — every load profile uses
   `constant-vus` / `ramping-vus`, which is closed-loop (a faster
   gateway gets more iterations because each VU cycles faster). The
   `docs/LOAD-PROFILES.md` table mentions "target RPS" figures that
   imply paced arrivals (`constant-arrival-rate`). Phase 4
   intentionally lands closed-loop first — it's how every public
   API-gateway benchmark we cross-referenced (`api7/apisix-benchmark`,
   `Kong/insomnia`, `jkaninda/goma-gateway-vs-traefik`) configures
   k6, so apples-to-apples with the prior art holds. A follow-up
   iteration will land paced variants under `k6/profiles/p1c-paced.js`
   etc., gated behind `BENCH_ARRIVAL=paced`.
2. **No docker-stats sampling yet** — TASK §8 wants RSS peak +
   steady-state per cell. The runner captures a `compose.log` on
   teardown but doesn't sample memory/cpu. Phase 6 (orchestrator)
   adds the per-second `docker stats` sidecar; for now, single-cell
   memory readings are an explicit gap.
3. **Hot-path access logs ON** — every `gateways/<gw>/<policy>/`
   config still emits access logs (the parity attestation needed
   them). TASK §10 requires access logs OFF in the load phase. A
   sweep through the 84 profile configs will land alongside Phase 5
   infrastructure (it's coupled to the cpuset/memory pinning work).

See [docs/LOAD-PROFILES.md](../docs/LOAD-PROFILES.md) and
[docs/POLICIES.md](../docs/POLICIES.md) for the canonical specs.
