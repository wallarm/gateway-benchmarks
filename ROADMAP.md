# Gateway Benchmarks — Implementation Roadmap

> Implementation plan for the PRD in [TASK.md](./TASK.md).
> Visual reference for the report: described in [docs/REPORT.md](./docs/REPORT.md) — the actual reference HTML will be generated in Phase 7.
> Repository: https://github.com/wallarm/gateway-benchmarks (public).

---

## Key differences from the legacy perf harness

| Aspect | Legacy harness | Required by PRD |
|--------|----------------|-----------------|
| Topology     | 2 EC2 (loadgen + gateway), backend in Docker | 3 EC2 (loadgen + gateway + backend) in a cluster placement group |
| Scenarios    | 8 scenario tabs (different load shapes)      | 12 scenario tabs (policy × protocol) × 4 load profiles = **48 cells × 7 gateways** |
| Policies     | No parity, no attestation                    | 10 policy profiles, parity attestation per cell |
| Backend      | `mccutchen/go-httpbin` (public image)        | **Forked `go-httpbin`** — code vendored into the repo, optional extra endpoints |
| Errors       | Single combined %                            | **4 columns**: 5XX · 4XX-expected · client-side · excluded |
| Memory       | CPU%/RAM live from `docker stats`            | Peak + steady-state memory, bandwidth, bytes/s |
| Provenance   | —                                            | Manifest: digests (not tags), git SHA, seeds, timestamps |
| Data         | `.summary.json` + HTML                       | + **CSV/JSON wide table**, per-cell values + repetitions |
| Repro        | —                                            | 2 runs on the same SHA → numerically stable (tolerance) |
| Local mode   | Absent                                       | Full local mode with pinned resources, same ranking as AWS |
| Repo         | Inside `wallarm-api-gateway`                 | Separate public `wallarm/gateway-benchmarks` |

---

## Phases

### Phase 1. Repository & infrastructure skeleton (1–2 days)

**Goal**: a clean, well-organised working area that is not embarrassing to show to an external reviewer.

- [x] Create the public repo `wallarm/gateway-benchmarks`
- [x] License (Apache 2.0 — maximum neutrality)
- [x] `README.md`: goal, neutrality disclaimer, Quick Start for local and AWS
- [x] Directory structure:
  ```
  gateway-benchmarks/
  ├── README.md
  ├── LICENSE
  ├── TASK.md                  # PRD (present)
  ├── ROADMAP.md               # this file
  ├── Makefile                 # perf-local-* / perf-aws-* / help
  ├── docs/
  │   ├── ARCHITECTURE.md
  │   ├── POLICIES.md          # description of 10 policy profiles + parity req
  │   ├── LOAD-PROFILES.md     # 4 load profiles
  │   ├── GATEWAYS.md          # versions, digests, deviations
  │   ├── REPORT.md            # how to read the HTML
  │   └── REPRODUCIBILITY.md   # manifest, seeds, tolerance
  ├── backend/                 # forked go-httpbin
  │   └── README.md
  ├── gateways/
  │   ├── wallarm/             # per-policy configs
  │   ├── nginx/
  │   ├── envoy/
  │   ├── kong/
  │   ├── apisix/
  │   ├── traefik/
  │   └── tyk/
  ├── k6/
  │   ├── lib.js
  │   ├── profiles/            # 4 load profiles
  │   └── scenarios/           # policy profiles-aware
  ├── orchestrator/            # Go: run loop, manifest
  ├── infra/
  │   ├── local/               # docker-compose.yml + resource pins
  │   └── aws/                 # Terraform: 3 EC2 cluster PG
  ├── reports/                 # output HTML + CSV + manifests
  └── scripts/
      ├── check-prereqs.sh
      ├── parity-attestation.sh
      └── generate-report.*
  ```
- [x] Makefile skeleton with commands (stubs for now)
- [x] CI: `.github/workflows/lint.yml` (shellcheck, markdown link check, go vet)

### Phase 2. Synthetic backend (0.5 day)

**Goal**: vendored `go-httpbin` with our additions (if needed).

- [x] Vendor `github.com/mccutchen/go-httpbin` **v2.22.1** into `backend/upstream/`, keep MIT license and add NOTICE attribution
- [x] Dockerfile: `golang:1.25-alpine` builder → `FROM scratch` final stage, static binary (`CGO_ENABLED=0`, `-trimpath`, `-ldflags "-s -w"`), non-root user, ~3 MB image
- [x] Exercised endpoints: `/status/200`, `/get`, `/post`, `/anything`, `/headers`, `/bytes/{n}`, `/status/{code}`, `/delay/{s}`, `/gzip`, `/deflate` — documented in `backend/README.md` and verified by `scripts/backend-smoke.sh`
- [ ] Optional extra endpoints (e.g. `/jwt/validate-echo` for JWT parity — deferred; httpbin is enough for now)
- [x] Healthcheck endpoint (`/status/200`)
- [x] `make backend-build` / `make backend-build-amd64` / `make backend-run` / `make backend-smoke` — real, idempotent targets (see `Makefile`)

### Phase 3. Parity framework (3–5 days — core work)

**Goal**: prove that every gateway does the same thing before we measure metrics.

**Phase 3a — foundation (done)**

- [x] Locked exact values for every profile in [`docs/POLICIES.md`](./docs/POLICIES.md):
  - JWT: HS256, shared secret `bench-jwt-hs256-secret-2026`, `kid = bench-hs256-2026`, `exp = iat + 3600`
  - Static RL: 1000 req/s per service, rolling 1 s window
  - Dynamic RL low cardinality: 10 req/s per IP, pool = 100
  - Dynamic RL high cardinality: 100 req/s per IP, pool = 50 000
  - Request headers: add `X-Bench-In: 1`, drop `X-Forwarded-For`
  - Response headers: add `X-Bench-Out: 1`, drop `Server`
  - Request body (JSON): add `$.bench.injected = true`, drop `$.secret`
  - Response body (JSON): add `$.bench.injected = true`, drop `$.origin`
    (`.origin` chosen because go-httpbin always returns it)
- [x] [`gateways/_reference/`](./gateways/_reference/) shared assets:
  `values.yaml`, JWT secret + payload template, JWKS, TLS cert/key,
  canonical request / response bodies for p08 / p09
- [x] [`fixtures/`](./fixtures/) per-profile probe sets (`p01..p10.jsonl`,
  32 probes total, schema documented in `fixtures/README.md`)
- [x] [`scripts/gen-jwt.sh`](./scripts/gen-jwt.sh) — mints valid / expired / wrong-secret HS256 tokens
  (bash + openssl + jq, no external deps)
- [x] [`scripts/parity-attestation.sh`](./scripts/parity-attestation.sh)
  runner: substitutes `${JWT_*}` placeholders, evaluates per-probe
  assertions (status, headers, JSON body, backend-echo), emits
  PASS / FAIL / FEATURE-MISSING JSON
- [x] `make parity-check` / `make parity-check-all` — real targets,
  smoke-verified against the raw backend
  (`p01` → PASS 4/4, `p02..p10` correctly FAIL because the backend is
  not a gateway)
- [x] Uniform settings and HTTP/1.1-enforcement knobs documented per
  gateway in [`docs/GATEWAYS.md`](./docs/GATEWAYS.md)

**Phase 3b — per-gateway configs (in progress)**

- [x] Bursts in the parity runner (p03 static-RL, p04/p05 dynamic-RL)
  — implemented in
  [`scripts/parity-attestation.sh`](./scripts/parity-attestation.sh);
  final version uses
  `curl --parallel --parallel-max N -K <config>` so the 1200-rps probe
  fits inside its 1 s window (validated end-to-end on
  `wallarm / p03-rl-static`: `2xx=998, 429=202, 5xx=0`)
- [x] [`scripts/parity-gateway.sh`](./scripts/parity-gateway.sh) +
  `make parity-gateway` / `parity-gateway-all` — full
  up→setup→parity→down lifecycle with trap-based cleanup and a
  `FEATURE-MISSING` short-circuit that skips the stack entirely when a
  profile is explicitly unsupported on the pinned image
- [x] `gateways/wallarm/p01-vanilla/` — real wallarm `0.2.0` image,
  parity **4/4 PASS**; deviations catalogued in
  [`gateways/wallarm/p01-vanilla/NOTES.md`](./gateways/wallarm/p01-vanilla/NOTES.md)
  and [`docs/GATEWAYS.md`](./docs/GATEWAYS.md)
- [x] `gateways/wallarm/p02-jwt/` — **FEATURE-MISSING** on the public
  `0.2.0` image (no `jwt_validation` policy shipped; `lua_runner`
  sandbox lacks crypto). Explainer +
  future-ready Admin API payloads in
  [`gateways/wallarm/p02-jwt/NOTES.md`](./gateways/wallarm/p02-jwt/NOTES.md)
- [x] `gateways/wallarm/p03-rl-static/` — real wallarm `0.2.0` image,
  parity **2/2 PASS** with a documented
  `window_type: sliding` deviation against the naive
  `window_type: fixed` reading of POLICIES.md (both semantics agree on
  "rolling 1 s window"; see
  [`gateways/wallarm/p03-rl-static/NOTES.md`](./gateways/wallarm/p03-rl-static/NOTES.md))
- [ ] `gateways/wallarm/` configs for p04..p10 (next Phase 3b pass)
- [ ] `gateways/nginx/` configs for p01..p10
- [ ] `gateways/envoy/` configs for p01..p10 (Lua filter for p08/p09)
- [ ] `gateways/kong/` configs for p01..p10
- [ ] `gateways/apisix/` configs for p01..p10
- [ ] `gateways/traefik/` configs for p01..p10 (community plugin for p02/p03)
- [ ] `gateways/tyk/` configs for p01..p07, p10 (p08/p09 = feature-missing)
- [ ] Green parity cell for every `(gateway, profile)` entry in
  [`docs/POLICIES.md` feature matrix](./docs/POLICIES.md) — either
  PASS or explicitly tagged FEATURE-MISSING / DEVIATION

### Phase 4. Load framework + k6 (2–3 days)

**Goal**: 4 load profiles × 10 policy-aware scenarios.

- [ ] Pin `k6 v1.7.1` (verify image digest)
- [ ] `k6/lib.js`: helpers (JWT generator, payload generator, IP pool, seeds)
- [ ] `k6/profiles/sustained.js` — constant rate, steady state
- [ ] `k6/profiles/spike.js` — ramp-hold-drop cycles
- [ ] `k6/profiles/high-concurrency.js` — N levels of concurrent connections
- [ ] `k6/profiles/heavy-payloads.js` — varying body sizes
- [ ] Each profile accepts a `POLICY_PROFILE` env var and adapts requests (JWT token, specific headers, payload shape)
- [ ] Seeds for anything pseudo-random (JWT pool, IP pool, payloads) — env `BENCH_SEED=42`

### Phase 5. Infrastructure (2 days)

**Goal**: 3 isolated hosts in both modes.

**Local**:
- [ ] `infra/local/docker-compose.yml`: 3 services (loadgen, gateway, backend) with pinned `cpus` + `mem_limit`
- [ ] 3 isolated bridge networks (loadgen↔gateway, gateway↔backend) — emulating separate hosts
- [ ] Smoke path: `make perf-local-up && make perf-local-parity && make perf-local-cycle-smoke`

**AWS**:
- [ ] `infra/aws/main.tf`: 3 EC2 `c6i.2xlarge` in a cluster placement group
- [ ] Internal-only traffic gateway↔backend and loadgen↔gateway
- [ ] Outputs: 3 IPs, SSH helpers
- [ ] `make perf-aws-up / perf-aws-destroy`

### Phase 6. Orchestrator (4–6 days — largest chunk)

**Goal**: one command → full cycle with manifest and report.

- [ ] Orchestrator in Go (single static binary — reproducibility)
- [ ] Inputs: mode (local/aws), profile filter (optional — for smoke), seed
- [ ] Loop:
  1. Assemble the manifest (digests, git SHA, k6 version, infra state, seeds)
  2. For each gateway × policy profile:
     - Start the gateway in the required configuration
     - Run parity attestation → on FAIL/FEATURE-MISSING, mark cells and skip load
     - For each load profile × N repetitions:
       - Run k6 with the right seed
       - Collect memory + bandwidth from the gateway host in parallel
       - Save per-cell JSON
     - Stop the gateway
  3. Aggregate per-cell data into wide CSV/JSON (medians, variance)
  4. Render the HTML report
  5. Store everything in `reports/<timestamp>/`:
     - `manifest.json`
     - `cells.csv` (wide)
     - `cells.json` (machine-readable)
     - `report.html`
     - `raw/` — original k6 summaries
- [ ] **Error classifier**: split 5XX, 4XX-expected, client-side by status code + k6 tags
- [ ] **Memory collector**: `cgroup.memory.current` on AWS (from the gateway host), `docker stats` locally
- [ ] **Bandwidth collector**: `/proc/net/dev` on the gateway host
- [ ] Watchdog: if the gateway crashes — restart it and mark the cell `crashed`; do not break the cycle
- [ ] Checkpoints — resume after an interruption

### Phase 7. Report generator (3–4 days)

**Goal**: HTML that matches the reference style with the new structure.

- [ ] Structure:
  - Hero
  - Executive summary: 7 rows, avg RPS, max error %, scenarios passed (e.g. 46/48), steady memory
  - Memory grid
  - Radar (relative RPS across all scenarios)
  - **12 scenario tabs** (instead of 8):
    - For each tab: description (what is tested, traffic profile, expected signal)
    - 4 sub-sections (one per load profile): RPS chart, latency chart, table
    - Table: 7 gateways + 1 baseline (backend), columns: RPS, p50, p95, max, avg, total reqs, 5XX, 4XX-expected, client-side, excluded, memory, bandwidth, overhead
    - Cells excluded / crashed / feature-missing — with a coloured badge and the reason
    - Cells with variance > tolerance — a dedicated "unstable" marker
- [ ] Per tab: parity status line: `All 7 PASS`, or `5 PASS · 2 EXCLUDED`
- [ ] Export: "Download CSV" / "Download manifest" buttons on each page

### Phase 8. Quality gates & documentation (2 days)

- [ ] Repro test: two runs on the same SHA → CSV diff → numerical stability within tolerance
- [ ] Rank test: local rank vs AWS rank → must agree
- [ ] `docs/REPRODUCIBILITY.md`: manifest, tolerance, reproduction steps
- [ ] `docs/GATEWAYS.md`: deviations table (what we could not implement and why)
- [ ] Final AWS run → first public report

### Phase 9. Publication (0.5 day)

- [ ] Final code review (no secrets, no hardcoded credentials)
- [ ] Push v0.1.0, attach the first report as a GitHub Release asset
- [ ] README announcement draft

---

## Working decisions / assumptions

### Where
- Work in `gateway-benchmarks/` (cloned from https://github.com/wallarm/gateway-benchmarks)
- The legacy perf harness is **ignored**; everything is rebuilt from scratch in this repo

### Incremental rollout
- First **vanilla policy × 1 load profile (sustained) × 7 gateways** = 7 cells — verify the skeleton
- Then **all 10 policies × sustained** = 70 cells — verify parity
- Then **all 4 load profiles** → 280 cells + 56 baseline
- Then **HTTPS** → 336 cells

### Stack
- Orchestrator: **Go** (static binary, single file, reproducibility)
- Manifest: JSON
- Report: static HTML (rendered from a Go template) + Chart.js via CDN
- k6: `grafana/k6:1.7.1@sha256:…` pinned by digest
- Gateways: all pinned by digest
- Build system: **Makefile** (style inherited from `wallarm-api-gateway/Makefile`)

### Scope decisions (locked)
- Repository: https://github.com/wallarm/gateway-benchmarks (already created, public)
- The legacy perf harness is ignored; everything is developed from scratch here
- AWS: **3 EC2** in a cluster placement group (loadgen + gateway + backend — see PRD §9)
- Orchestrator: **Go**, one binary

### Known hard parts
1. **Parity for rate limit** — every implementation behaves slightly differently (precision, trigger moment). We will allow "429 rate ≈ expected 429 rate ±10%".
2. **Body rewrite in Envoy** — only via a Lua filter; in Wallarm — via a Lua policy; in Kong — via `request-transformer` + a custom plugin; in APISIX — via `response-rewrite`; in NGINX — via `njs`; in Traefik — partially via middleware; in **Tyk** — may be feature-missing.
3. **High cardinality RL** — every gateway has its own storage (Lua shared dict, Redis for Kong/Tyk, in-memory for Traefik). Document honestly as a deviation.
4. **Memory steady-state** — needs to be separated from warm-up. Solution: sample memory 30s after reaching steady state and take the median over 60s.

---

## Estimation

| Phase | Effort | Dependencies |
|-------|--------|--------------|
| 1. Skeleton | 1–2 days | — |
| 2. Backend | 0.5 day | 1 |
| 3. Parity | 3–5 days | 1, 2 |
| 4. Load framework | 2–3 days | 1, 2 |
| 5. Infrastructure | 2 days | 1 |
| 6. Orchestrator | 4–6 days | 3, 4, 5 |
| 7. Report | 3–4 days | 6 |
| 8. QA + docs | 2 days | 6, 7 |
| 9. Publication | 0.5 day | 8 |
| **Total** | **~20 working days** (4 weeks) | |

---

## Next steps

1. Phase 1 scaffolding — done.
2. Phase 2 (vendored `go-httpbin` backend) — done.
3. Phase 3a foundation (docs, reference assets, fixtures, parity
   runner, Makefile targets) — done, smoke-verified.
4. **Phase 3b in progress**:
   - burst runner, parity-gateway lifecycle, `wallarm/p01-vanilla`
     green — **done**.
   - `wallarm/p02-jwt` tagged `FEATURE-MISSING` on `0.2.0`;
     `wallarm/p03-rl-static` **2/2 PASS** with `sliding` window —
     **done**. `FEATURE-MISSING` short-circuit landed in
     `scripts/parity-gateway.sh`; burst runner switched to
     `curl --parallel -K` to actually hit 1200 rps inside 1 s.
   - next passes (in this order):
     - `wallarm/p06-req-headers` + `p07-resp-headers` → shake out the
       header-transform plumbing.
     - `wallarm/p08-req-body` + `p09-resp-body` → exercise the Lua
       body-rewrite primitive.
     - `wallarm/p04-rl-dynamic-low` + `p05-rl-dynamic-high` →
       high-cardinality path with the burst fixtures.
     - `wallarm/p10-full-pipeline` → composition of the above.
   - then the other gateways (`nginx` → `envoy` → `kong` → `apisix`
     → `traefik` → `tyk`), one profile column at a time.
5. In parallel, begin Phase 4 (k6 load profiles) and the infrastructure
   sub-tasks in Phase 5.
