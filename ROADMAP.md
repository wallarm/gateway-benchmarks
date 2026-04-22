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
- [x] `gateways/wallarm/p02-jwt/` — **FEATURE-MISSING** on the pinned
  public `0.2.0` image, but **6/6 PASS** with
  `WALLARM_IMAGE=wallarm/api-gateway:main-5f1ab30`. The setup script now
  detects `jwt_validation` at runtime via `/policies`: the public image
  still short-circuits to `FEATURE-MISSING`, while the local main
  override binds the native JWT policy and runs parity for real. See
  [`gateways/wallarm/p02-jwt/NOTES.md`](./gateways/wallarm/p02-jwt/NOTES.md)
- [x] `gateways/wallarm/p03-rl-static/` — real wallarm `0.2.0` image,
  parity **2/2 PASS** with a documented
  `window_type: sliding` deviation against the naive
  `window_type: fixed` reading of POLICIES.md (both semantics agree on
  "rolling 1 s window"; see
  [`gateways/wallarm/p03-rl-static/NOTES.md`](./gateways/wallarm/p03-rl-static/NOTES.md))
- [x] `gateways/wallarm/p06-req-headers/` — real wallarm `0.2.0` image,
  parity **3/3 PASS**. `lua_runner` bound on service-level
  `request_flow` (`+X-Bench-In`, `-X-Forwarded-For`). Deviations:
  the base-path strip forces a `target.endpoint.url=…/anything/headers`
  backend trick (otherwise a trailing-slash 404); qemu-amd64-on-arm
  segfaults on `lua_runner` activation, so Apple Silicon users must
  let the multi-arch manifest resolve to native arm64. See
  [`gateways/wallarm/p06-req-headers/NOTES.md`](./gateways/wallarm/p06-req-headers/NOTES.md).
- [x] `gateways/wallarm/p07-resp-headers/` — real wallarm `0.2.0`
  image, parity **2/2 PASS**. `lua_runner` bound on `response_flow`
  (`+X-Bench-Out`, `-Server`). Same base-path trick as p06; the
  `Server`-drop side is structural on this backend (go-httpbin's
  `/anything/*` doesn't emit `Server:`) — every other gateway in the
  bench will exercise the drop for real. See
  [`gateways/wallarm/p07-resp-headers/NOTES.md`](./gateways/wallarm/p07-resp-headers/NOTES.md).
- [x] `gateways/wallarm/p08-req-body/` — real wallarm `0.2.0` image,
  parity **3/3 PASS**. `lua_runner` + `cjson.safe` on `request_flow`
  (`+$.bench.injected`, `-$.secret`). `Content-Length` is recomputed
  explicitly; empty / non-JSON bodies are coerced to `{}` so the
  inject invariant always holds. See
  [`gateways/wallarm/p08-req-body/NOTES.md`](./gateways/wallarm/p08-req-body/NOTES.md).
- [x] `gateways/wallarm/p09-resp-body/` — real wallarm `0.2.0` image,
  parity **3/3 PASS**. `lua_runner` + `cjson.safe` on `response_flow`
  (`+$.bench.injected`, `-$.origin`). Robust to non-JSON upstreams
  (pass-through). `Content-Length` is recomputed — stale value
  otherwise truncates the payload. See
  [`gateways/wallarm/p09-resp-body/NOTES.md`](./gateways/wallarm/p09-resp-body/NOTES.md).
- [x] `scripts/parity-attestation.sh` helpers —
  `assert_json_has_string` (for `backend_saw_header`) and
  `assert_json_contains_value` (for `response_body_json_contains`)
  both accept scalar / array-of-one representations so fixtures stay
  backend-agnostic (go-httpbin echoes headers and query args as
  arrays).
- [x] `gateways/wallarm/p04-rl-dynamic-low/` — real wallarm `0.2.0`
  image, parity **2/2 PASS**. `ratelimit` policy keyed on
  `${request.headers.x-real-ip}`, rate 10/s, sliding window,
  scope=service. Burst of 10 IPs × 45 reqs ASAP lands at
  `2xx=99, 429=351` vs. the math's `100/350` (one-request
  sliding-counter drift). See
  [`gateways/wallarm/p04-rl-dynamic-low/NOTES.md`](./gateways/wallarm/p04-rl-dynamic-low/NOTES.md).
- [x] `gateways/wallarm/p05-rl-dynamic-high/` — real wallarm `0.2.0`
  image, parity **3/3 PASS**. Same policy shape as p04, rate=100/s.
  10 distinct IPs × 20 rps → `2xx=200, 429=0` (all under limit);
  single-IP saturation of 500 reqs → `2xx=100, 429=400` exact. See
  [`gateways/wallarm/p05-rl-dynamic-high/NOTES.md`](./gateways/wallarm/p05-rl-dynamic-high/NOTES.md).
- [x] `gateways/wallarm/p10-full-pipeline/` — **FEATURE-MISSING** on
  the pinned public `0.2.0` image (cascade from `p02-jwt`), but
  **4/4 PASS** with
  `WALLARM_IMAGE=wallarm/api-gateway:main-5f1ab30`. The runtime
  `setup.sh` keeps the public image honest while enabling a real local
  main-branch validation path for `jwt_validation + ratelimit + 4×lua_runner`.
  Wallarm roster on `0.2.0`: **8 PASS, 2 FEATURE-MISSING (p02, p10),
  0 FAIL** across all 10 canonical profiles; local override roster on
  `main-5f1ab30`: **10 PASS, 0 FAIL, 0 other**.
- [~] `gateways/nginx/` configs for p01..p10:
  - [x] `gateways/nginx/p01-vanilla/` — **4/4 PASS** on
    `nginx:1.27.3-alpine`
    (`sha256:814a8e88df978ade80e584cc5b333144b9372a8e3c98872d07137dbf3b44d0e4`).
    Catch-all `proxy_pass http://backend_pool;` with every row from
    [`docs/GATEWAYS.md § Uniform settings`](./docs/GATEWAYS.md#uniform-settings)
    explicitly expressed in the config; no deviations. See
    [`gateways/nginx/p01-vanilla/NOTES.md`](./gateways/nginx/p01-vanilla/NOTES.md).
  - [x] `gateways/nginx/p03-rl-static/` — **2/2 PASS** on the same
    image. `limit_req_zone $server_name zone=bench_p03:1m rate=1000r/s`
    + `limit_req zone=bench_p03 burst=200 nodelay` +
    `error_page 429 @retry_after` (to stamp `Retry-After: 1` on the
    429). Observed `2xx=262, 429=938, 5xx=0` under the fixture's
    1200-req 1-second ASAP burst — well above the `150 − 50 = 100`
    minimum threshold. See
    [`gateways/nginx/p03-rl-static/NOTES.md`](./gateways/nginx/p03-rl-static/NOTES.md).
  - [x] `gateways/nginx/p04-rl-dynamic-low/` — **2/2 PASS** on the
    same image. `limit_req_zone $http_x_real_ip zone=bench_p04:1m
    rate=10r/s` + `burst=10 nodelay`. Observed `2xx=109, 429=341,
    5xx=0` under the 10-IP / 450-req / 3-s fixture — inside one
    request of wallarm/p04 (`99/351`). See
    [`gateways/nginx/p04-rl-dynamic-low/NOTES.md`](./gateways/nginx/p04-rl-dynamic-low/NOTES.md).
  - [x] `gateways/nginx/p05-rl-dynamic-high/` — **3/3 PASS** on the
    same image. Same mechanism as p04 with `zone=10m rate=100r/s` +
    `burst=20 nodelay`. Zone size sized for POLICIES.md's 50 000-IP
    pool (≈ 6.4 MB at 128 B/key, rounded up to 10 MB for LRU slack).
    Observed: burst #1 (10 IPs × 20 rps, under limit) = `200/0`,
    burst #2 (1 IP × 500 rps) = `2xx=24, 429=476` (fixture threshold
    260; 1.8× headroom). See
    [`gateways/nginx/p05-rl-dynamic-high/NOTES.md`](./gateways/nginx/p05-rl-dynamic-high/NOTES.md).
  - [x] `gateways/nginx/p06-req-headers/` — **3/3 PASS** on mainline
    `nginx:1.27.3-alpine`. Pure `proxy_set_header` — inject via
    literal value (`X-Bench-In: 1`), drop via empty-string idiom
    (`proxy_set_header X-Forwarded-For "";` which omits the header
    from the upstream request rather than forwarding an empty
    value). No Lua, no extra module. See
    [`gateways/nginx/p06-req-headers/NOTES.md`](./gateways/nginx/p06-req-headers/NOTES.md).
  - [x] `gateways/nginx/p07-resp-headers/` — **2/2 PASS**, first
    nginx cell that overrides the base image. Uses
    `openresty/openresty:1.27.1.2-alpine@sha256:761047d6…` because
    mainline nginx has no directive that removes the built-in
    `Server` response header. Config combines `add_header X-Bench-Out
    "1" always;` + `proxy_hide_header Server;` + `more_clear_headers
    "Server";` (the last from bundled `ngx_headers_more-0.37`).
    Override is declared in
    [`gateways/nginx/p07-resp-headers/.env`](./gateways/nginx/p07-resp-headers/.env);
    `scripts/parity-gateway.sh` now passes it via `docker compose
    --env-file` (per-invocation, no env leak to sibling profiles
    during a sweep). See
    [`gateways/nginx/p07-resp-headers/NOTES.md`](./gateways/nginx/p07-resp-headers/NOTES.md).
  - [x] `gateways/nginx/p02-jwt/` — **6/6 PASS**. OpenResty with
    a ~60-line pure-Lua HS256 verifier at
    [`gateways/nginx/_shared/lualib/jwt_hs256.lua`](./gateways/nginx/_shared/lualib/jwt_hs256.lua).
    No dependency on `lua-resty-jwt`; HMAC-SHA-256 is built on top
    of bundled `resty.sha256` via RFC 2104, plus constant-time
    compare and `exp` window check. First gateway in the matrix
    where p02 flips from FEATURE-MISSING (wallarm 0.2.0) to PASS.
    See [`gateways/nginx/p02-jwt/NOTES.md`](./gateways/nginx/p02-jwt/NOTES.md).
  - [x] `gateways/nginx/p08-req-body/` — **3/3 PASS** on OpenResty.
    `access_by_lua_block` → `ngx.req.read_body` →
    `body_rewrite.rewrite_request` (shared cjson helper) →
    `ngx.req.set_body_data` (which auto-patches Content-Length).
    See [`gateways/nginx/p08-req-body/NOTES.md`](./gateways/nginx/p08-req-body/NOTES.md).
  - [x] `gateways/nginx/p09-resp-body/` — **3/3 PASS** on OpenResty.
    Canonical two-phase Lua pattern: `header_filter_by_lua_block`
    clears Content-Length, `body_filter_by_lua_block` collects
    chunks and rewrites on EOF via `rewrite_response_if_json`.
    Non-JSON responses pass through untouched.
    See [`gateways/nginx/p09-resp-body/NOTES.md`](./gateways/nginx/p09-resp-body/NOTES.md).
  - [x] `gateways/nginx/p10-full-pipeline/` — **4/4 PASS** on
    OpenResty. Composes p02+p03+p06+p07+p08+p09, leaning on nginx
    phase ordering (PREACCESS→ACCESS→CONTENT→header/body_filter)
    to get the semantics right for free. Observed burst shape:
    1200 rps valid-JWT GET → 945×429 from limit_req (fires
    **before** Lua auth). **First gateway in the bench with a
    complete green p10** — wallarm's cell is still FEATURE-MISSING
    (`jwt_validation` not shipped on 0.2.0, cascading into p10).
    See [`gateways/nginx/p10-full-pipeline/NOTES.md`](./gateways/nginx/p10-full-pipeline/NOTES.md).
  - Full nginx column: **10 PASS / 0 FAIL / 32 probes** on
    `nginx:1.27.3-alpine` (mainline) + `openresty:1.27.1.2-alpine`
    (Lua profiles). Sweep wall-clock: ~15 s warm.
- [~] `gateways/envoy/` configs for p01..p10 (Lua filter for p02/p08/p09)
  - [x] `gateways/envoy/p01-vanilla/` — real
    `envoyproxy/envoy:distroless-v1.32.6`, parity **4/4 PASS**.
    Static bootstrap: HTTP/1.1 listener on :9080, HCM with terminal
    `envoy.filters.http.router`, `STRICT_DNS` cluster →
    `backend:8080`. All uniform settings from
    `docs/GATEWAYS.md §Uniform settings` wired explicitly
    (`codec_type: HTTP1`, `reuse_port`, `common_http_protocol_options.idle_timeout: 60s`,
    `request_timeout: 10s`, `connect_timeout: 10s`,
    `normalize_path: false`, HTTP/1.1 upstream with keepalive).
    Admin API published read-only on :9901. See
    [`gateways/envoy/p01-vanilla/NOTES.md`](./gateways/envoy/p01-vanilla/NOTES.md).
  - [ ] p02-jwt — planned via HCM `lua` filter +
    shared `gateways/envoy/_shared/lualib/jwt_hs256.lua`;
    `envoy.filters.http.jwt_authn` only supports asymmetric
    algorithms (RS/ES/PS), so the canonical HS256 secret goes
    through Lua (same helper the nginx column uses).
  - [x] `gateways/envoy/p03-rl-static/` — parity **2/2 PASS**
    on the pinned distroless image.
    `envoy.filters.http.local_ratelimit` at HCM level,
    `token_bucket: { max_tokens: 100, tokens_per_fill: 100,
    fill_interval: 1s }` per worker × `--concurrency 2` ⇒ ≈200
    rps effective. **Rate deviation** (canonical 1000 rps lowered
    to ≈200 rps on Docker Desktop / Apple Silicon because envoy
    saturates at 500–800 rps of HTTP/1.1 accept under the
    128-parallel burst probe). Canonical rate restored in Phase 4
    on a real Linux host. Config ingestion moved from bind-mount
    to Docker `configs:` to work around VirtioFS cache staleness.
    See
    [`gateways/envoy/p03-rl-static/NOTES.md`](./gateways/envoy/p03-rl-static/NOTES.md)
    and
    [`docs/GATEWAYS.md § Deviations`](./docs/GATEWAYS.md#gwenvoy-pp03-rl-static).
  - [ ] p04/p05 — planned via
    `envoy.filters.http.local_ratelimit` with `descriptors` keyed
    on `X-Real-IP`, token buckets `{5, 5} / {50, 50}` per worker
    × `--concurrency 2` (same deviation workaround as p03 on
    Docker Desktop).
  - [ ] p06/p07 — planned via native
    `request_headers_to_add` / `request_headers_to_remove` and
    `response_headers_to_add` / `response_headers_to_remove` on
    the route config, with `server_header_transformation`
    appropriate for the drop side of p07.
  - [ ] p08/p09 — planned via HCM `lua` filter reading / rewriting
    `request_body` / `response_body` and recomputing
    `Content-Length`.
  - [ ] p10 — planned as the canonical chain
    (`jwt_authn` Lua → `local_ratelimit` → header/body filters →
    `router`) in the HCM `http_filters` array.
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
   - `wallarm/p06-req-headers` **3/3 PASS** and
     `wallarm/p07-resp-headers` **2/2 PASS** — both through
     `lua_runner` (service-level request/response flows). Base-path
     strip trick landed (target URLs route through go-httpbin's
     `/anything/<slug>` catch-all); qemu-amd64-on-arm segfault
     gotcha documented. The `assert_json_has_string` helper was added
     to `scripts/parity-attestation.sh` so header-echo assertions
     work against both array and scalar shapes.
   - `wallarm/p08-req-body` **3/3 PASS** and
     `wallarm/p09-resp-body` **3/3 PASS** — `lua_runner` +
     `cjson.safe` on the service's request/response flow. The policy
     decodes the body, mutates (`+$.bench.injected`,
     `-$.secret` / `-$.origin`), re-encodes and recomputes
     `Content-Length`. A generalised `assert_json_contains_value`
     helper landed in `scripts/parity-attestation.sh` so
     `response_body_json_contains` accepts scalar / array shapes too
     (go-httpbin echoes query args as possibly-multi-value arrays).
   - `wallarm/p04-rl-dynamic-low` **2/2 PASS** and
     `wallarm/p05-rl-dynamic-high` **3/3 PASS** — `ratelimit`
     policy with a `${request.headers.x-real-ip}` context
     expression (per-IP bucketing inside a service-scoped namespace),
     sliding window. Observed counts line up with the math to the
     request: p05's single-IP saturation gives exactly
     `2xx=100, 429=400` under a 500-req burst with a 100/s limit.
     Also documented the `duration_s` harness caveat (parity runner
     fires ASAP; Phase 4 k6 profiles do the paced arrivals).
   - `wallarm/p10-full-pipeline` → **FEATURE-MISSING** (cascade from
     `p02-jwt`). Fixture has two probes that expect `401` on missing
     / expired JWT; without `jwt_validation` in public `0.2.0`, the
     cell can't pass functionally. `FEATURE-MISSING` marker installed,
     forward-compatible `setup.sh` sketch landed in
     [`p10-full-pipeline/NOTES.md`](./gateways/wallarm/p10-full-pipeline/NOTES.md)
     so the cell flips to PASS the moment a public tag ships
     `jwt_validation`. **Wallarm roster is now complete**: `8 PASS,
     2 FEATURE-MISSING (p02, p10), 0 FAIL` across all 10 canonical
     profiles on `wallarm/api-gateway:0.2.0`.
   - `nginx/p01-vanilla` → **4/4 PASS** on
     `nginx:1.27.3-alpine` (digest resolved and pinned in
     `docs/GATEWAYS.md`). Catch-all `proxy_pass` with every uniform
     setting expressed explicitly in `nginx.conf` — no deviations.
     This seeds the nginx column for the rest of Phase 3b.
   - `nginx/p03-rl-static` → **2/2 PASS** on the same image.
     `limit_req_zone $server_name rate=1000r/s` + `burst=200 nodelay`
     + `error_page 429 @retry_after` (to stamp `Retry-After: 1`).
     Observed `2xx=262, 429=938, 5xx=0` at 1200 req / 1 s ASAP —
     well inside the fixture's `≥ 150 ± 50 × 429` tolerance.
   - `nginx/p04-rl-dynamic-low` → **2/2 PASS** on the same image.
     `limit_req_zone $http_x_real_ip rate=10r/s` + `burst=10 nodelay`.
     Observed `2xx=109, 429=341, 5xx=0` — symmetric to wallarm/p04
     (`99/351`) within one request.
   - `nginx/p05-rl-dynamic-high` → **3/3 PASS** on the same image.
     `zone=10m rate=100r/s` + `burst=20 nodelay` (zone sized for the
     50 000-IP pool per POLICIES.md). Burst #1 = `200/0`, burst #2 =
     `2xx=24, 429=476` — 1.8× the fixture's 260 × 429 floor.
   - `nginx/p06-req-headers` → **3/3 PASS** on mainline. Pure
     `proxy_set_header` — inject literal + empty-string drop idiom.
     No Lua, no extra module.
   - `nginx/p07-resp-headers` → **2/2 PASS** on
     `openresty/openresty:1.27.1.2-alpine` (the first nginx cell to
     override the base image). Mainline has no directive to remove
     the built-in `Server` response header; `ngx_headers_more`'s
     `more_clear_headers "Server";` does, and OpenResty bundles
     that module. The image override lives in
     `gateways/nginx/p07-resp-headers/.env` and is passed through
     `docker compose --env-file` (per-invocation scoping so no env
     leak during `make parity-gateway-all` sweeps). This generic
     `.env` mechanism will also carry the OpenResty pin for
     `p02/p08/p09/p10` in future iterations.
   - `nginx/p02-jwt` → **6/6 PASS** on OpenResty. A ~60-line
     pure-Lua HS256 verifier at
     `gateways/nginx/_shared/lualib/jwt_hs256.lua`, built on top
     of the bundled `resty.sha256` + `cjson.safe` + `bit` via
     classic RFC 2104 HMAC construction + constant-time compare +
     `exp` check. No dependency on `lua-resty-jwt` (keeps the
     image-digest pin story intact). First gateway where p02
     flips from wallarm's `FEATURE-MISSING` to PASS.
   - `nginx/p08-req-body` → **3/3 PASS** on OpenResty.
     `access_by_lua_block` + `ngx.req.set_body_data`
     (auto-patches Content-Length), shared cjson helper at
     `gateways/nginx/_shared/lualib/body_rewrite.lua` injects
     `$.bench.injected` and drops `$.secret`.
   - `nginx/p09-resp-body` → **3/3 PASS** on OpenResty.
     Canonical two-phase Lua pattern: `header_filter_by_lua_block`
     clears Content-Length, `body_filter_by_lua_block` buffers
     chunks and rewrites on EOF (injects `$.bench.injected`,
     drops `$.origin`). Non-JSON responses pass through untouched.
   - `nginx/p10-full-pipeline` → **4/4 PASS** on OpenResty.
     Composes p02+p03+p06+p07+p08+p09 in one request flow. nginx
     phase ordering encodes the semantics for free: PREACCESS
     (rate-limit) runs **before** ACCESS (Lua JWT), which is
     exactly the shape the burst probe asserts — 1200 rps of
     valid-JWT GETs observes `2xx=0, 429=945, 5xx=0`. **First
     green p10 in the bench**; wallarm's cell remains
     `FEATURE-MISSING` until a public image ships `jwt_validation`.
   - **nginx column snapshot**: `10 PASS, 0 FAIL, 32/32 probes` —
     **full column green**. Sweep runs in ~15 s warm. nginx is
     the first gateway to close every cell, including the
     previously-absent `p10-full-pipeline`.
   - **envoy column opened**: `envoyproxy/envoy:distroless-v1.32.6`
     pinned by digest, `gateways/envoy/` scaffolding landed
     (compose + `_shared/lualib/` + p01-vanilla). `p01-vanilla`
     parity **4/4 PASS** on the first run, static bootstrap
     (listener + HCM + router + STRICT_DNS cluster) with every
     uniform setting wired explicitly.
   - **envoy / p03-rl-static**: parity **2/2 PASS** via
     `envoy.filters.http.local_ratelimit` at HCM level with a
     per-worker `token_bucket`. Two adjustments were landed in
     the process: (a) `--concurrency 2` pinned on the compose
     command (envoy's bucket is per-worker, so `N_CPU` workers
     would multiply the rate unpredictably); (b) config ingestion
     migrated from a bind-mount to Docker `configs:` because
     Docker Desktop VirtioFS kept serving a pre-edit copy of
     `envoy.yaml` for ~30 s after `compose up`, which broke
     iteration. **Rate deviation** documented: canonical 1000 rps
     lowered to ≈200 rps on Docker Desktop / Apple Silicon
     because envoy saturates at 500–800 rps of HTTP/1.1 accept
     under the 128-parallel burst probe (observed 2xx≈122,
     429≈166, other≈912 — 166 × 429 above the 150 ± 50
     threshold). Canonical rate restored in Phase 4 on a real
     Linux host. Envoy column snapshot: **2 PASS / 0 FAIL /
     6 probes** (p01 + p03). Remaining 8 profiles planned:
     `local_ratelimit` with descriptors for p04/p05, native
     header transforms for p06/p07, Lua filter reusing the
     shared `jwt_hs256.lua` / `body_rewrite.lua` for p02/p08/p09,
     and composition in HCM filter order for p10.
   - next pass: `kong` → `apisix` → `traefik` → `tyk`, one
     profile column at a time (envoy p02..p10 fills in interleaved).
5. In parallel, begin Phase 4 (k6 load profiles) and the infrastructure
   sub-tasks in Phase 5.
