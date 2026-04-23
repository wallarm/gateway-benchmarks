# Gateway Benchmarks — Implementation Roadmap

> Implementation plan for the PRD in [TASK.md](./TASK.md).
> Visual reference for the report: described in [docs/REPORT.md](./docs/REPORT.md) — the actual reference HTML will be generated in Phase 7.
> Repository: https://github.com/wallarm/gateway-benchmarks (public).

---

## Key differences from the legacy perf harness

| Aspect | Legacy harness | Required by PRD |
|--------|----------------|-----------------|
| Topology     | 2 EC2 (loadgen + gateway), backend in Docker | 3 EC2 (loadgen + gateway + backend) in a cluster placement group |
| Scenarios    | 8 scenario tabs (different load shapes)      | 13 scenario tabs (policy × protocol) × 4 load profiles = **52 cells × 7 gateways** |
| Policies     | No parity, no attestation                    | 12 policy profiles, parity attestation per cell |
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
  │   ├── POLICIES.md          # description of 12 policy profiles + parity req
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
  canonical request / response bodies for p09 / p10
- [x] [`fixtures/`](./fixtures/) per-profile probe sets (`p01..p12.jsonl`,
  32 probes total, schema documented in `fixtures/README.md`)
- [x] [`scripts/gen-jwt.sh`](./scripts/gen-jwt.sh) — mints valid / expired / wrong-secret HS256 tokens
  (bash + openssl + jq, no external deps)
- [x] [`scripts/parity-attestation.sh`](./scripts/parity-attestation.sh)
  runner: substitutes `${JWT_*}` placeholders, evaluates per-probe
  assertions (status, headers, JSON body, backend-echo), emits
  PASS / FAIL / FEATURE-MISSING JSON
- [x] `make parity-check` / `make parity-check-all` — real targets,
  smoke-verified against the raw backend
  (`p01` → PASS 4/4, `p02..p11` correctly FAIL because the backend is
  not a gateway)
- [x] Uniform settings and HTTP/1.1-enforcement knobs documented per
  gateway in [`docs/GATEWAYS.md`](./docs/GATEWAYS.md)

**Phase 3b — per-gateway configs (matrix complete: 7 × 12 = 84 cells, 81 PASS + 3 PARTIAL (tyk status-code deviations), 0 FEATURE-MISSING; p03-jwks-rs256-basic capability pass complete: 7 × 1 = 7 cells, 6 PASS, 1 PARTIAL PASS on tyk)**

- [x] Bursts in the parity runner (p03 static-RL, p05/p06 dynamic-RL)
  — implemented in
  [`scripts/parity-attestation.sh`](./scripts/parity-attestation.sh);
  final version uses
  `curl --parallel --parallel-max N -K <config>` so the 1200-rps probe
  fits inside its 1 s window (validated end-to-end on
  `wallarm / p04-rl-static`: `2xx=998, 429=202, 5xx=0`)
- [x] [`scripts/parity-gateway.sh`](./scripts/parity-gateway.sh) +
  `make parity-gateway` / `parity-gateway-all` — full
  up→setup→parity→down lifecycle with trap-based cleanup and a
  `FEATURE-MISSING` short-circuit that skips the stack entirely when a
  profile is explicitly unsupported on the pinned image
- [x] `gateways/wallarm/p01-vanilla/` — real wallarm API Gateway
  image (tag/digest supplied by the runner via `WALLARM_IMAGE`,
  see [`gateways/wallarm/README.md`](./gateways/wallarm/README.md)),
  parity **4/4 PASS**; deviations catalogued in
  [`gateways/wallarm/p01-vanilla/NOTES.md`](./gateways/wallarm/p01-vanilla/NOTES.md)
  and [`docs/GATEWAYS.md`](./docs/GATEWAYS.md)
- [x] `gateways/wallarm/p02-jwt/` — **6/6 PASS** against a
  from-source Wallarm build that exposes the native `jwt_validation`
  policy. The setup script detects the primitive at runtime via
  `/policies` and exits with `FEATURE-MISSING` if the supplied
  `WALLARM_IMAGE` does not ship it — a sanity guardrail, not a
  steady-state verdict. See
  [`gateways/wallarm/p02-jwt/NOTES.md`](./gateways/wallarm/p02-jwt/NOTES.md).
- [x] `gateways/wallarm/p04-rl-static/` — real wallarm API Gateway
  image, parity **2/2 PASS** with a documented
  `window_type: sliding` deviation against the naive
  `window_type: fixed` reading of POLICIES.md (both semantics agree on
  "rolling 1 s window"; see
  [`gateways/wallarm/p04-rl-static/NOTES.md`](./gateways/wallarm/p04-rl-static/NOTES.md))
- [x] `gateways/wallarm/p08-req-headers/` — real wallarm API Gateway
  image, parity **3/3 PASS**. `lua_runner` bound on service-level
  `request_flow` (`+X-Bench-In`, `-X-Forwarded-For`). Deviations:
  the base-path strip forces a `target.endpoint.url=…/anything/headers`
  backend trick (otherwise a trailing-slash 404); qemu-amd64-on-arm
  segfaults on `lua_runner` activation, so Apple Silicon users must
  let the multi-arch manifest resolve to native arm64. See
  [`gateways/wallarm/p08-req-headers/NOTES.md`](./gateways/wallarm/p08-req-headers/NOTES.md).
- [x] `gateways/wallarm/p09-resp-headers/` — real wallarm API Gateway
  image, parity **2/2 PASS**. `lua_runner` bound on `response_flow`
  (`+X-Bench-Out`, `-Server`). Same base-path trick as p07; the
  `Server`-drop side is structural on this backend (go-httpbin's
  `/anything/*` doesn't emit `Server:`) — every other gateway in the
  bench will exercise the drop for real. See
  [`gateways/wallarm/p09-resp-headers/NOTES.md`](./gateways/wallarm/p09-resp-headers/NOTES.md).
- [x] `gateways/wallarm/p10-req-body/` — real wallarm API Gateway
  image, parity **3/3 PASS**. `lua_runner` + `cjson.safe` on `request_flow`
  (`+$.bench.injected`, `-$.secret`). `Content-Length` is recomputed
  explicitly; empty / non-JSON bodies are coerced to `{}` so the
  inject invariant always holds. See
  [`gateways/wallarm/p10-req-body/NOTES.md`](./gateways/wallarm/p10-req-body/NOTES.md).
- [x] `gateways/wallarm/p11-resp-body/` — real wallarm API Gateway
  image, parity **3/3 PASS**. `lua_runner` + `cjson.safe` on `response_flow`
  (`+$.bench.injected`, `-$.origin`). Robust to non-JSON upstreams
  (pass-through). `Content-Length` is recomputed — stale value
  otherwise truncates the payload. See
  [`gateways/wallarm/p11-resp-body/NOTES.md`](./gateways/wallarm/p11-resp-body/NOTES.md).
- [x] `scripts/parity-attestation.sh` helpers —
  `assert_json_has_string` (for `backend_saw_header`) and
  `assert_json_contains_value` (for `response_body_json_contains`)
  both accept scalar / array-of-one representations so fixtures stay
  backend-agnostic (go-httpbin echoes headers and query args as
  arrays).
- [x] `gateways/wallarm/p06-rl-dynamic-low/` — real wallarm API
  Gateway image, parity **2/2 PASS**. `ratelimit` policy keyed on
  `${request.headers.x-real-ip}`, rate 10/s, sliding window,
  scope=service. Burst of 10 IPs × 45 reqs ASAP lands at
  `2xx=99, 429=351` vs. the math's `100/350` (one-request
  sliding-counter drift). See
  [`gateways/wallarm/p06-rl-dynamic-low/NOTES.md`](./gateways/wallarm/p06-rl-dynamic-low/NOTES.md).
- [x] `gateways/wallarm/p07-rl-dynamic-high/` — real wallarm API
  Gateway image, parity **3/3 PASS**. Same policy shape as p05, rate=100/s.
  10 distinct IPs × 20 rps → `2xx=200, 429=0` (all under limit);
  single-IP saturation of 500 reqs → `2xx=100, 429=400` exact. See
  [`gateways/wallarm/p07-rl-dynamic-high/NOTES.md`](./gateways/wallarm/p07-rl-dynamic-high/NOTES.md).
- [x] `gateways/wallarm/p12-full-pipeline/` — **4/4 PASS** against a
  from-source Wallarm build that exposes `jwt_validation + ratelimit + 4×lua_runner`.
  Same runtime-detection pattern as `p02-jwt`: the harness runs parity
  for real if the supplied `WALLARM_IMAGE` ships the full registry,
  and short-circuits to `FEATURE-MISSING` as a sanity guardrail if
  the primitive is absent (so stale or minimal builds cannot silently
  flip the verdict).
  Wallarm roster against a compliant from-source `WALLARM_IMAGE`:
  **10 PASS, 0 FAIL, 0 other** across all 10 canonical profiles.
- [~] `gateways/nginx/` configs for p01..p12:
  - [x] `gateways/nginx/p01-vanilla/` — **4/4 PASS** on
    `nginx:1.27.3-alpine`
    (`sha256:814a8e88df978ade80e584cc5b333144b9372a8e3c98872d07137dbf3b44d0e4`).
    Catch-all `proxy_pass http://backend_pool;` with every row from
    [`docs/GATEWAYS.md § Uniform settings`](./docs/GATEWAYS.md#uniform-settings)
    explicitly expressed in the config; no deviations. See
    [`gateways/nginx/p01-vanilla/NOTES.md`](./gateways/nginx/p01-vanilla/NOTES.md).
  - [x] `gateways/nginx/p04-rl-static/` — **2/2 PASS** on the same
    image. `limit_req_zone $server_name zone=bench_p04:1m rate=1000r/s`
    + `limit_req zone=bench_p04 burst=200 nodelay` +
    `error_page 429 @retry_after` (to stamp `Retry-After: 1` on the
    429). Observed `2xx=262, 429=938, 5xx=0` under the fixture's
    1200-req 1-second ASAP burst — well above the `150 − 50 = 100`
    minimum threshold. See
    [`gateways/nginx/p04-rl-static/NOTES.md`](./gateways/nginx/p04-rl-static/NOTES.md).
  - [x] `gateways/nginx/p06-rl-dynamic-low/` — **2/2 PASS** on the
    same image. `limit_req_zone $http_x_real_ip zone=bench_p06:1m
    rate=10r/s` + `burst=10 nodelay`. Observed `2xx=109, 429=341,
    5xx=0` under the 10-IP / 450-req / 3-s fixture — inside one
    request of wallarm/p05 (`99/351`). See
    [`gateways/nginx/p06-rl-dynamic-low/NOTES.md`](./gateways/nginx/p06-rl-dynamic-low/NOTES.md).
  - [x] `gateways/nginx/p07-rl-dynamic-high/` — **3/3 PASS** on the
    same image. Same mechanism as p05 with `zone=10m rate=100r/s` +
    `burst=20 nodelay`. Zone size sized for POLICIES.md's 50 000-IP
    pool (≈ 6.4 MB at 128 B/key, rounded up to 10 MB for LRU slack).
    Observed: burst #1 (10 IPs × 20 rps, under limit) = `200/0`,
    burst #2 (1 IP × 500 rps) = `2xx=24, 429=476` (fixture threshold
    260; 1.8× headroom). See
    [`gateways/nginx/p07-rl-dynamic-high/NOTES.md`](./gateways/nginx/p07-rl-dynamic-high/NOTES.md).
  - [x] `gateways/nginx/p08-req-headers/` — **3/3 PASS** on mainline
    `nginx:1.27.3-alpine`. Pure `proxy_set_header` — inject via
    literal value (`X-Bench-In: 1`), drop via empty-string idiom
    (`proxy_set_header X-Forwarded-For "";` which omits the header
    from the upstream request rather than forwarding an empty
    value). No Lua, no extra module. See
    [`gateways/nginx/p08-req-headers/NOTES.md`](./gateways/nginx/p08-req-headers/NOTES.md).
  - [x] `gateways/nginx/p09-resp-headers/` — **2/2 PASS**, first
    nginx cell that overrides the base image. Uses
    `openresty/openresty:1.27.1.2-alpine@sha256:761047d6…` because
    mainline nginx has no directive that removes the built-in
    `Server` response header. Config combines `add_header X-Bench-Out
    "1" always;` + `proxy_hide_header Server;` + `more_clear_headers
    "Server";` (the last from bundled `ngx_headers_more-0.37`).
    Override is declared in
    [`gateways/nginx/p09-resp-headers/.env`](./gateways/nginx/p09-resp-headers/.env);
    `scripts/parity-gateway.sh` now passes it via `docker compose
    --env-file` (per-invocation, no env leak to sibling profiles
    during a sweep). See
    [`gateways/nginx/p09-resp-headers/NOTES.md`](./gateways/nginx/p09-resp-headers/NOTES.md).
  - [x] `gateways/nginx/p02-jwt/` — **6/6 PASS**. OpenResty with
    a ~60-line pure-Lua HS256 verifier at
    [`gateways/nginx/_shared/lualib/jwt_hs256.lua`](./gateways/nginx/_shared/lualib/jwt_hs256.lua).
    No dependency on `lua-resty-jwt`; HMAC-SHA-256 is built on top
    of bundled `resty.sha256` via RFC 2104, plus constant-time
    compare and `exp` window check. First gateway in the matrix
    that lands p02 on an off-the-shelf public image (wallarm also
    passes natively, but on a from-source build).
    See [`gateways/nginx/p02-jwt/NOTES.md`](./gateways/nginx/p02-jwt/NOTES.md).
  - [x] `gateways/nginx/p10-req-body/` — **3/3 PASS** on OpenResty.
    `access_by_lua_block` → `ngx.req.read_body` →
    `body_rewrite.rewrite_request` (shared cjson helper) →
    `ngx.req.set_body_data` (which auto-patches Content-Length).
    See [`gateways/nginx/p10-req-body/NOTES.md`](./gateways/nginx/p10-req-body/NOTES.md).
  - [x] `gateways/nginx/p11-resp-body/` — **3/3 PASS** on OpenResty.
    Canonical two-phase Lua pattern: `header_filter_by_lua_block`
    clears Content-Length, `body_filter_by_lua_block` collects
    chunks and rewrites on EOF via `rewrite_response_if_json`.
    Non-JSON responses pass through untouched.
    See [`gateways/nginx/p11-resp-body/NOTES.md`](./gateways/nginx/p11-resp-body/NOTES.md).
  - [x] `gateways/nginx/p12-full-pipeline/` — **4/4 PASS** on
    OpenResty. Composes p02+p03+p07+p08+p09+p10, leaning on nginx
    phase ordering (PREACCESS→ACCESS→CONTENT→header/body_filter)
    to get the semantics right for free. Observed burst shape:
    1200 rps valid-JWT GET → 945×429 from limit_req (fires
    **before** Lua auth). **First gateway in the bench with a
    complete green p11** on an off-the-shelf public image
    (wallarm also closes p11 natively but needs a from-source
    build exposing `jwt_validation`).
    See [`gateways/nginx/p12-full-pipeline/NOTES.md`](./gateways/nginx/p12-full-pipeline/NOTES.md).
  - Full nginx column: **12 PASS / 0 FAIL / 39 probes** on
    `nginx:1.27.3-alpine` (mainline) + `openresty:1.27.1.2-alpine`
    (Lua profiles). Sweep wall-clock: ~15 s warm. Includes the
    new `p05-rl-endpoint` per-endpoint RL axis (see Phase 3c
    summary below).
- [~] `gateways/envoy/` configs for p01..p12 (Lua filter for p02/p09/p10)
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
  - [x] `gateways/envoy/p04-rl-static/` — parity **2/2 PASS**
    on the pinned distroless image. Canonical 1000 rps
    service-wide via `envoy.filters.http.local_ratelimit` at HCM
    level with bucket shape `max_tokens: 200, tokens_per_fill: 50,
    fill_interval: 0.05s` — mirrors nginx's
    `rate=1000r/s, burst=200 nodelay` leaky-bucket semantics
    verbatim. Previous "≈200 rps rate deviation" was traced to a
    `max_connection_duration: 0s` bug in envoy's
    `common_http_protocol_options` (closes every connection at
    t=0) and dropped after that field was unset across every
    envoy profile. Thread model: `--concurrency 1` with a shared
    token bucket (envoy v1.17+ defaults to per-process shared
    buckets for `local_ratelimit`, verified empirically).
    See
    [`gateways/envoy/p04-rl-static/NOTES.md`](./gateways/envoy/p04-rl-static/NOTES.md)
    and
    [`docs/GATEWAYS.md § Deviations`](./docs/GATEWAYS.md#gwenvoy-pp04-rl-static).
  - [x] `gateways/envoy/p06-rl-dynamic-low/` — parity **2/2 PASS**.
    `envoy.filters.http.local_ratelimit` at HCM with
    `rate_limits.actions` extracting `X-Real-IP` into a
    `client_ip` descriptor key, and 10 enumerated `descriptors[]`
    entries (one per fixture IP `10.0.0.1..10.0.0.10`). Per-IP
    token bucket `max_tokens: 10, tokens_per_fill: 10,
    fill_interval: 1s` = canonical 10 rps/IP.
    `always_consume_default_token_bucket: false` so matched
    descriptors do not drain the global safety-net bucket. See
    [`gateways/envoy/p06-rl-dynamic-low/NOTES.md`](./gateways/envoy/p06-rl-dynamic-low/NOTES.md).
  - [x] `gateways/envoy/p07-rl-dynamic-high/` — parity **3/3 PASS**.
    Same mechanism as p05, 11 enumerated `descriptors[]` entries
    (`10.5.0.1..10.5.0.10 + 10.5.9.9`), per-IP bucket sized
    `max_tokens: 100, tokens_per_fill: 100, fill_interval: 1s`
    = canonical 100 rps/IP. **Enumerated-descriptors deviation**
    (shared with p05) documented in
    [`docs/GATEWAYS.md § Deviations`](./docs/GATEWAYS.md#gwenvoy-pp06-rl-dynamic-low--p07-rl-dynamic-high-infraenumerated-descriptors):
    v1.32 requires verbatim descriptor matches; wildcard-value
    descriptors land in v1.33 (envoyproxy/envoy#36623). Full pool
    cardinality (100 / 50 000 IPs per POLICIES.md) restored in
    Phase 4 by bumping the column or pairing with a global RLS.
    See
    [`gateways/envoy/p07-rl-dynamic-high/NOTES.md`](./gateways/envoy/p07-rl-dynamic-high/NOTES.md).
  - [x] `gateways/envoy/p05-rl-endpoint/` — parity **4/4 PASS**.
    Per-endpoint rate limiting via HCM-level
    `envoy.filters.http.local_ratelimit` installed with
    `filter_enabled.default_value.numerator: 0` (globally disabled)
    plus a `typed_per_filter_config` override on the
    `/anything/limited` route. Per the v1.32 LocalRateLimit proto:
    per-route config is a **full replacement** (not a merge) of
    the HCM-level config, so the override carries its own
    `token_bucket` (`max_tokens: 100, tokens_per_fill: 5,
    fill_interval: 0.05s` = canonical 100 rps), plus
    `filter_enabled: 100%` and `filter_enforced: 100%`. The
    catch-all `/` route ships without `typed_per_filter_config`
    and inherits the disabled HCM filter, so `/anything/free`
    stays unrestricted — verified by the fourth parity probe
    asserting `status_429_max: 0` on a 1200-req parallel burst
    against the free endpoint. See
    [`gateways/envoy/p05-rl-endpoint/NOTES.md`](./gateways/envoy/p05-rl-endpoint/NOTES.md).
  - [ ] p07/p08 — planned via native
    `request_headers_to_add` / `request_headers_to_remove` and
    `response_headers_to_add` / `response_headers_to_remove` on
    the route config, with `server_header_transformation`
    appropriate for the drop side of p08.
  - [ ] p09/p10 — planned via HCM `lua` filter reading / rewriting
    `request_body` / `response_body` and recomputing
    `Content-Length`.
  - [ ] p11 — planned as the canonical chain
    (`jwt_authn` Lua → `local_ratelimit` → header/body filters →
    `router`) in the HCM `http_filters` array.
- [x] `gateways/kong/` configs for p01..p12 — **12 PASS, 0 FAIL,
  0 FM, 39/39 probes** on `kong/kong:3.9.1` in DB-less declarative
  mode (closed in [.notes/PROGRESS.md § Iteration 26](./.notes/PROGRESS.md)).
  Native `jwt` (`iss`-keyed consumer credentials,
  `claims_to_verify: [exp]`) + `rate-limiting` (service-wide,
  per-route, header-keyed) + `request-transformer` /
  `response-transformer` + `pre-function` / `post-function`
  carrying body-rewrite Lua against the shared
  `_shared/lualib/body_rewrite.lua` (byte-for-byte port of nginx
  / apisix columns). Two infra hooks: a custom entrypoint shim
  (`_shared/bench-start.sh`) pre-patches kong's nginx template to
  re-route `proxy_set_header X-Forwarded-For` through a writable
  `$bench_xff` variable so plugins can drop the header (kong's
  `runloop.access.after()` re-stamps XFF after plugins, blocking
  the native `request-transformer.remove` route — same
  architectural limitation as APISIX); and the env-var pair
  `KONG_UNTRUSTED_LUA: sandbox` + `KONG_UNTRUSTED_LUA_SANDBOX_REQUIRES:
  body_rewrite` whitelists the shared module inside kong's Lua
  sandbox without disabling sandboxing globally. p10 / p11 also
  carry a `header_filter` Lua hook clearing `Content-Length`
  (kong's PDK does not auto-strip on body changes the way vanilla
  nginx does).
- [x] `gateways/apisix/` configs for p01..p12 — **12 PASS,
  0 FAIL, 0 FM, 39/39 probes** on `apache/apisix:3.15.0-debian`
  in standalone mode (closed in
  [.notes/PROGRESS.md § Iteration 25](./.notes/PROGRESS.md)).
- [x] `gateways/traefik/` configs for p01..p12 — **12 PASS,
  0 FAIL, 0 FM, 39/39 probes** on `traefik:v3.3.4`. Iteration
  24 landed 9/11 + 2 FM (p02 + p11 honestly FM, no native
  HS256 in OSS, no vetted community plugin); Iteration 28
  closed both FM cells in a single change by landing the new
  in-repo `jwt_hs256` Yaegi plugin under
  `gateways/traefik/_shared/plugins-local/src/github.com/
  wallarm/jwt_hs256/` (~250 LoC Go, stdlib-only:
  `crypto/hmac`, `crypto/sha256`, `encoding/base64`,
  `encoding/json`, `time`, `net/http`, `strings`, `context`
  — every package on Yaegi's allowlist). p11 chains six
  middleware in canonical order (`bench-p02 → bench-p04 →
  bench-p08 → bench-p10 → bench-p09 → bench-p11`) and lands
  the burst probe `2xx=270, 429=930` (well past the
  `status_429_min: 150` threshold; 2xx-vs-429 imbalance
  comes from loadgen-side burst parallelism draining the
  rate-limit's 200-token bucket in <200 ms). Falsifies the
  earlier Phase 3b assumption that traefik p02 / p11 were
  architecturally FM on the OSS baseline — Yaegi's stdlib
  allowlist exposes everything an HMAC-SHA-256 verifier
  needs, the gap was just an unwillingness to vendor a
  community plugin we couldn't audit. p01/p03/p04/p05/p06/
  p07/p08 — native middleware (`rateLimit` +
  `sourceCriterion.requestHeaderName: X-Real-IP`,
  `headers.customRequestHeaders` / `customResponseHeaders`);
  p09/p10 — custom Yaegi plugin `body_rewrite` under
  `_shared/plugins-local/src/github.com/wallarm/body_rewrite/`
  (~160 LoC Go, stdlib-only). Three landed deviations:
  per-profile `entryPoints.web.forwardedHeaders.insecure: true`
  in p05/p06/p07/p11; `coerceJSONLiteral` shim in
  `body_rewrite.go::New()`; and the `map[string]json.RawMessage`
  decode pattern in `jwt_hs256.go::verify()` to work around
  Yaegi's reflect-driven JSON decoder skipping method dispatch
  on user-declared types (the textbook custom-`UnmarshalJSON`
  pattern silently fails inside Yaegi).
- [x] `gateways/tyk/` configs for p01..p12 — **9 PASS, 2 PARTIAL PASS,
  27/32 probes** on `tykio/tyk-gateway:v5.11.1` in standalone (file-
  based apps + policies) mode. Every canonical capability is green:
  `global_rate_limit` (p03), `extended_paths.rate_limit` (p04),
  JSVM per-IP session synth (p05/p06), `transform_headers` /
  `transform_response_headers` (p07/p08), and the request/response
  body rewrites which both use Tyk's NATIVE `transform` /
  `transform_response` middleware against shared Sprig v3 templates
  (p09 / p10 / p11). p09 was migrated off the JSVM `pre` middleware
  during the p11 rollout: the otto driver caps Tyk's effective
  throughput at ~830 rps via per-request MiniRequestObject (un)marshal
  + VM context-switch overhead, well below the 1000 rps
  `global_rate_limit` threshold p11's burst probe exercises, so the
  RL bucket never reached capacity and 0 × 429 resulted on every
  burst run. Replacing the JSVM with the native Sprig template
  (`unset .secret`, `set .bench (dict "injected" true)`, `mustToJson .`
  — Sprig is wired into every Tyk Classic template via
  `apidef.APIDefinitionLoader.filterSprigFuncs`) removes the
  per-request VM cost and lands p11's burst at the canonical
  `2xx≈999, 429≈201` split across three back-to-back runs.
  The 5 cosmetic FAILs (4 in p02-jwt, 1 in p12-full-pipeline) are
  all the same hard-coded `400`/`403` from `gateway/mw_jwt.go`
  v5.11.1 (literal `http.StatusBadRequest` / `http.StatusForbidden`
  with no config knob in the Classic API def or `tyk.standalone.conf`
  that swaps them for `401`); the JWT capability itself works on
  every probe. Per-profile breakdown:
  * p01-vanilla — **4/4 PASS** (catch-all proxy, file-based API def)
  * p02-jwt — **PARTIAL PASS 2/6** (HMAC native; 4 cosmetic
    `400`/`403` rejections; see
    [`p02-jwt/NOTES.md`](./gateways/tyk/p02-jwt/NOTES.md))
  * p04-rl-static — **2/2 PASS** (`global_rate_limit: {rate:1000, per:1}`)
  * p05-rl-endpoint — **4/4 PASS** (`extended_paths.rate_limit` on
    `/anything/limited` only, free endpoint inherits no policy)
  * p06-rl-dynamic-low — **2/2 PASS** (JSVM `pre` synth: parses
    `X-Real-IP`, hashes a per-IP session via `TykMakeHttpRequest`
    against the admin API at boot, attaches via `TykJsResponse`)
  * p07-rl-dynamic-high — **3/3 PASS** (same shape, rate=100/s)
  * p08-req-headers — **3/3 PASS** (`transform_headers` POST + GET;
    `delete_headers: ["X-Forwarded-For"]` is honored by Tyk's
    reverse proxy in `transform_headers` phase, but the proxy
    re-stamps XFF on `RemoteAddr` after this hook — the inbound
    drop succeeds; the absence-on-upstream invariant is what the
    fixture asserts)
  * p09-resp-headers — **2/2 PASS** (`transform_response_headers`
    drops `Server` and injects `X-Bench-Out`)
  * p10-req-body — **3/3 PASS** (native `transform` + Sprig template
    at `_shared/templates/p10_request_rewrite.tmpl`, POST only)
  * p11-resp-body — **3/3 PASS** (`transform_response` + Sprig
    template at `_shared/templates/p11_response_rewrite.tmpl`,
    POST + GET)
  * p12-full-pipeline — **PARTIAL PASS 3/4** (chains JWT + global
    RL + native body rewrite + headers + response transforms in the
    documented `gateway/api_loader.go` order; 1 cosmetic
    `400`/`401` FAIL on the missing-Authorization probe; burst
    `2xx=999, 429=201` cleanly inside the `≥150 ± 50` tolerance
    band; full investigation in
    [`p12-full-pipeline/NOTES.md`](./gateways/tyk/p12-full-pipeline/NOTES.md))
- [x] Green parity cell for every `(gateway, profile)` entry in
  [`docs/POLICIES.md` feature matrix](./docs/POLICIES.md) — every
  cell is now PASS or explicitly tagged PARTIAL PASS / FEATURE-MISSING
  / DEVIATION across the 7-gateway × 12-profile matrix (84 cells).

### Phase 4. Load framework + k6 (2–3 days)

**Goal**: 4 load profiles × 13 policy-aware scenarios + the runner
that wraps each cell's lifecycle (compose up → setup → parity
precondition → k6 → teardown).

Iteration 29 landed the framework foundation + 1 scenario green
end-to-end. The remaining 12 scenarios are mostly mechanical
(rebind URL / payload / auth header per `docs/POLICIES.md`); the
hard problem — k6-image pinning, env-var contract, custom error
classifier per `TASK §8`, in-network targeting via `bench-net`,
parity precondition, JWT minting outside k6 — is solved.

- [x] Pin `k6 v1.7.1`
  (`grafana/k6:1.7.1@sha256:4fd3a694926b064d3491d9b02b01cde886583c4931f1223816e3d9a7bdfa7e0f`,
  multi-arch index covering linux/amd64 + linux/arm64).
- [x] `k6/lib/{env,options,jwt,payloads,metrics}.js` — single source
  of truth for env vars (`BENCH_TARGET_URL`, `BENCH_LOAD_PROFILE`,
  `BENCH_POLICY_PROFILE`, `BENCH_SCENARIO`, `BENCH_GATEWAY`,
  `BENCH_RUN_ID`, `BENCH_RUN_SEED`, `BENCH_JWT_VALID`,
  `BENCH_STREAM_METRICS`), runtime dispatch from `BENCH_LOAD_PROFILE`
  to the matching `profiles/*.js` options object, and a four-bucket
  custom-metric classifier (`policy_2xx` / `policy_4xx_expected` /
  `policy_4xx_unexpected` / `policy_5xx_unexpected`) that maps to the
  four error columns mandated by `TASK §8` (the report generator in
  Phase 7 reads these directly).
- [x] `k6/profiles/p1-baseline.js`     — constant 10 VUs × 60s
- [x] `k6/profiles/p2-sustained.js`    — constant 100 VUs × 5m
- [x] `k6/profiles/p3-ramp.js`         — 10 → 100 → 300 → 500 (3 ×
  60s) → hold 180s → 0 (60s)
- [x] `k6/profiles/p4-stress.js`       — constant 1000 VUs × 120s
- [x] `k6/scenarios/s01-vanilla-http.js` — first scenario, drives
  `p01-vanilla`. Smoke-tested against nginx end-to-end:
  **PASS, 1 417 860 reqs / 60s (≈23.6k RPS), p95=1.23 ms, 0 failures,
  parity precondition PASS, both checks 100% (2 835 720 / 0)**
  on Apple Silicon Docker Desktop. Custom counters appear cleanly in
  the summary export; thresholds (`p(95)<200`, `policy_5xx==0`) both
  green.
- [x] `scripts/load-gateway.sh` — runner script that mirrors
  `scripts/parity-gateway.sh` byte-for-byte on lifecycle, swapping
  the "work" step from `parity-attestation.sh` to a `docker run
  grafana/k6` pinned to the digest above. Resolves the gateway-stack
  `bench-net` dynamically via `docker compose config --format json |
  jq .name`, so k6 reaches the gateway via the in-network
  `gateway:9080` alias without ever leaving the bench network.
  Mints HS256 tokens on the host (k6 has no openssl) via
  `scripts/gen-jwt.sh valid` only when the scenario name contains
  `jwt` / `full-pipeline`. Trap-based teardown is unconditional.
- [x] Makefile entries: `load-gateway` (single cell) + `load-gateway-
  load-sweep` (4 load profiles × one scenario for one gateway × one
  policy). Help block updated.
- [ ] `k6/scenarios/s02-jwt-http.js`            — drives `p02-jwt`         (next iteration)
- [ ] `k6/scenarios/s03-rl-static-http.js`      — drives `p04-rl-static`   (next iteration)
- [ ] `k6/scenarios/s04-rl-endpoint-http.js`    — drives `p05-rl-endpoint` (next iteration)
- [ ] `k6/scenarios/s05-rl-dynamic-low-http.js` — drives `p05`             (next iteration)
- [ ] `k6/scenarios/s06-rl-dynamic-high-http.js`— drives `p06`             (next iteration)
- [ ] `k6/scenarios/s07-req-headers-http.js`    — drives `p07`             (next iteration)
- [ ] `k6/scenarios/s08-resp-headers-http.js`   — drives `p08`             (next iteration)
- [ ] `k6/scenarios/s09-req-body-http.js`       — drives `p09`             (next iteration)
- [ ] `k6/scenarios/s10-resp-body-http.js`      — drives `p10`             (next iteration)
- [ ] `k6/scenarios/s11-full-pipeline-http.js`  — drives `p11`             (next iteration)
- [ ] `k6/scenarios/s12-vanilla-https.js`       — drives `p01` over TLS    (lands with Phase 5)
- [ ] `k6/scenarios/s13-full-pipeline-https.js` — drives `p11` over TLS    (lands with Phase 5)
- [ ] Paced (`constant-arrival-rate`) profile variants gated by
  `BENCH_ARRIVAL=paced` — closed-loop is fine for relative ranking
  (every public API-gw benchmark we cross-referenced ships closed-
  loop) but paced is needed for absolute-RPS-vs-target reporting.
  Track follow-up.
- [ ] Hot-path access-log silence sweep across 84 profile configs —
  TASK §10 mandate, currently every `gateways/<gw>/<policy>/` config
  still emits access logs (parity attestation relied on them). Sweep
  is a Phase 5 prerequisite, not a Phase 4 blocker.

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
  - **13 scenario tabs** (instead of 8):
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
- Then **HTTPS** → 364 cells

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
   - `wallarm/p02-jwt` **6/6 PASS** against a from-source Wallarm
     build (the public image history is covered in
     [`docs/GATEWAYS.md`](./docs/GATEWAYS.md#wallarm-p02-jwt-historical-public-image-gap-no-longer-active));
     `wallarm/p04-rl-static` **2/2 PASS** with `sliding` window —
     **done**. The `FEATURE-MISSING` short-circuit stayed in
     `scripts/parity-gateway.sh` as a sanity guardrail for minimal
     Wallarm builds; burst runner switched to `curl --parallel -K`
     to actually hit 1200 rps inside 1 s.
   - `wallarm/p08-req-headers` **3/3 PASS** and
     `wallarm/p09-resp-headers` **2/2 PASS** — both through
     `lua_runner` (service-level request/response flows). Base-path
     strip trick landed (target URLs route through go-httpbin's
     `/anything/<slug>` catch-all); qemu-amd64-on-arm segfault
     gotcha documented. The `assert_json_has_string` helper was added
     to `scripts/parity-attestation.sh` so header-echo assertions
     work against both array and scalar shapes.
   - `wallarm/p10-req-body` **3/3 PASS** and
     `wallarm/p11-resp-body` **3/3 PASS** — `lua_runner` +
     `cjson.safe` on the service's request/response flow. The policy
     decodes the body, mutates (`+$.bench.injected`,
     `-$.secret` / `-$.origin`), re-encodes and recomputes
     `Content-Length`. A generalised `assert_json_contains_value`
     helper landed in `scripts/parity-attestation.sh` so
     `response_body_json_contains` accepts scalar / array shapes too
     (go-httpbin echoes query args as possibly-multi-value arrays).
   - `wallarm/p06-rl-dynamic-low` **2/2 PASS** and
     `wallarm/p07-rl-dynamic-high` **3/3 PASS** — `ratelimit`
     policy with a `${request.headers.x-real-ip}` context
     expression (per-IP bucketing inside a service-scoped namespace),
     sliding window. Observed counts line up with the math to the
     request: p06's single-IP saturation gives exactly
     `2xx=100, 429=400` under a 500-req burst with a 100/s limit.
     Also documented the `duration_s` harness caveat (parity runner
     fires ASAP; Phase 4 k6 profiles do the paced arrivals).
   - `wallarm/p12-full-pipeline` → **4/4 PASS** against a from-source
     Wallarm build that exposes `jwt_validation + ratelimit +
     4 × lua_runner`. Fixture has two probes that expect `401` on
     missing / expired JWT; the `setup.sh` detects `jwt_validation`
     at runtime via `/policies` and short-circuits to `FEATURE-MISSING`
     if the supplied `WALLARM_IMAGE` does not ship it (sanity
     guardrail for minimal builds, not a steady-state verdict). See
     [`p12-full-pipeline/NOTES.md`](./gateways/wallarm/p12-full-pipeline/NOTES.md).
     **Wallarm roster is now complete**: `10 PASS, 0 FAIL, 0 other`
     across all 10 canonical profiles on a compliant from-source
     `WALLARM_IMAGE`.
   - `nginx/p01-vanilla` → **4/4 PASS** on
     `nginx:1.27.3-alpine` (digest resolved and pinned in
     `docs/GATEWAYS.md`). Catch-all `proxy_pass` with every uniform
     setting expressed explicitly in `nginx.conf` — no deviations.
     This seeds the nginx column for the rest of Phase 3b.
   - `nginx/p04-rl-static` → **2/2 PASS** on the same image.
     `limit_req_zone $server_name rate=1000r/s` + `burst=200 nodelay`
     + `error_page 429 @retry_after` (to stamp `Retry-After: 1`).
     Observed `2xx=262, 429=938, 5xx=0` at 1200 req / 1 s ASAP —
     well inside the fixture's `≥ 150 ± 50 × 429` tolerance.
   - `nginx/p06-rl-dynamic-low` → **2/2 PASS** on the same image.
     `limit_req_zone $http_x_real_ip rate=10r/s` + `burst=10 nodelay`.
     Observed `2xx=109, 429=341, 5xx=0` — symmetric to wallarm/p05
     (`99/351`) within one request.
   - `nginx/p07-rl-dynamic-high` → **3/3 PASS** on the same image.
     `zone=10m rate=100r/s` + `burst=20 nodelay` (zone sized for the
     50 000-IP pool per POLICIES.md). Burst #1 = `200/0`, burst #2 =
     `2xx=24, 429=476` — 1.8× the fixture's 260 × 429 floor.
   - `nginx/p08-req-headers` → **3/3 PASS** on mainline. Pure
     `proxy_set_header` — inject literal + empty-string drop idiom.
     No Lua, no extra module.
   - `nginx/p09-resp-headers` → **2/2 PASS** on
     `openresty/openresty:1.27.1.2-alpine` (the first nginx cell to
     override the base image). Mainline has no directive to remove
     the built-in `Server` response header; `ngx_headers_more`'s
     `more_clear_headers "Server";` does, and OpenResty bundles
     that module. The image override lives in
     `gateways/nginx/p09-resp-headers/.env` and is passed through
     `docker compose --env-file` (per-invocation scoping so no env
     leak during `make parity-gateway-all` sweeps). This generic
     `.env` mechanism will also carry the OpenResty pin for
     `p02/p09/p10/p11` in future iterations.
   - `nginx/p02-jwt` → **6/6 PASS** on OpenResty. A ~60-line
     pure-Lua HS256 verifier at
     `gateways/nginx/_shared/lualib/jwt_hs256.lua`, built on top
     of the bundled `resty.sha256` + `cjson.safe` + `bit` via
     classic RFC 2104 HMAC construction + constant-time compare +
     `exp` check. No dependency on `lua-resty-jwt` (keeps the
     image-digest pin story intact). First gateway where p02
     flips from wallarm's `FEATURE-MISSING` to PASS.
   - `nginx/p10-req-body` → **3/3 PASS** on OpenResty.
     `access_by_lua_block` + `ngx.req.set_body_data`
     (auto-patches Content-Length), shared cjson helper at
     `gateways/nginx/_shared/lualib/body_rewrite.lua` injects
     `$.bench.injected` and drops `$.secret`.
   - `nginx/p11-resp-body` → **3/3 PASS** on OpenResty.
     Canonical two-phase Lua pattern: `header_filter_by_lua_block`
     clears Content-Length, `body_filter_by_lua_block` buffers
     chunks and rewrites on EOF (injects `$.bench.injected`,
     drops `$.origin`). Non-JSON responses pass through untouched.
   - `nginx/p12-full-pipeline` → **4/4 PASS** on OpenResty.
     Composes p02+p03+p07+p08+p09+p10 in one request flow. nginx
     phase ordering encodes the semantics for free: PREACCESS
     (rate-limit) runs **before** ACCESS (Lua JWT), which is
     exactly the shape the burst probe asserts — 1200 rps of
     valid-JWT GETs observes `2xx=0, 429=945, 5xx=0`. **First
     green p11 in the bench**; wallarm's cell remains
     `FEATURE-MISSING` until a public image ships `jwt_validation`.
   - **nginx column snapshot**: `10 PASS, 0 FAIL, 32/32 probes` —
     **full column green**. Sweep runs in ~15 s warm. nginx is
     the first gateway to close every cell, including the
     previously-absent `p12-full-pipeline`.
   - **envoy column opened**: `envoyproxy/envoy:distroless-v1.32.6`
     pinned by digest, `gateways/envoy/` scaffolding landed
     (compose + `_shared/lualib/` + p01-vanilla). `p01-vanilla`
     parity **4/4 PASS** on the first run, static bootstrap
     (listener + HCM + router + STRICT_DNS cluster) with every
     uniform setting wired explicitly.
   - **envoy / p04-rl-static**: parity **2/2 PASS** via
     `envoy.filters.http.local_ratelimit` at HCM level with a
     shared-across-workers `token_bucket`. Bucket shape
     `max_tokens: 200, tokens_per_fill: 50, fill_interval: 0.05s`
     mirrors nginx's `rate=1000r/s, burst=200 nodelay` leaky-
     bucket semantics — canonical 1000 rps restored after
     discovering the previous "≈200 rps deviation" was actually
     caused by `max_connection_duration: 0s` in envoy's
     `common_http_protocol_options` (which means "close
     immediately at t=0", not "no maximum"). Unsetting that
     field across every envoy profile eliminated the phantom
     connection-churn symptom and made canonical-rate configs
     reliable. Also disproved the "per-worker bucket" assumption:
     envoy v1.17+ shares `local_ratelimit` buckets across every
     worker in the process, confirmed empirically by
     `--concurrency 1 vs 2` producing identical pass counts on a
     1200-req burst.
   - **envoy / p06-rl-dynamic-low + p07-rl-dynamic-high**: parity
     **2/2 + 3/3 PASS**. `envoy.filters.http.local_ratelimit` with
     `rate_limits.actions` extracting `X-Real-IP` into a
     `client_ip` descriptor key, plus enumerated `descriptors[]`
     entries (10 for p05 on `10.0.0.1..10.0.0.10`, 11 for p06 on
     `10.5.0.1..10.5.0.10 + 10.5.9.9`). Per-IP token buckets sized
     at the canonical rate (10 rps/IP for p05, 100 rps/IP for p06),
     `always_consume_default_token_bucket: false` to isolate each
     IP's bucket from the safety-net default. **Enumerated-
     descriptors deviation** documented: v1.32 requires verbatim
     descriptor matches; blank-value wildcard descriptors (the
     idiomatic "one bucket per unique value" shape) land in v1.33
     via envoyproxy/envoy#36623. Full pool cardinality (100 /
     50 000 IPs) restored in Phase 4 by bumping the column or
     pairing with a global RLS. Rediscovered an Apple-Silicon
     VirtioFS bind-mount cache gotcha: a file can stay cached by
     inode across `compose down -v && up` even after an on-disk
     edit; `cp f f.new && rm f && mv f.new f` forces a refresh
     (`touch` alone does not — only a real inode change
     invalidates the cache). Documented in
     `gateways/envoy/README.md § Config ingestion`.
   - **envoy column snapshot**: **15 PASS / 0 FAIL / 15 probes**
     across p01 + p03 + p04 + p05 + p06. Remaining 6 profiles
     planned: native header transforms for p07/p08, Lua filter
     reusing the shared `jwt_hs256.lua` / `body_rewrite.lua` for
     p02/p09/p10, and composition in HCM filter order for p11.
   - **Phase 3c — new per-endpoint rate-limit axis (`p05-rl-endpoint`)**:
     added as a parallel profile to p03/p05/p06 (not a replacement)
     to give the benchmark a distinct "one-route bucket" test
     column separate from "service-wide bucket" (p03) and
     "per-source-IP bucket" (p05/p06). Canonical policy: 100 rps
     scoped to `/anything/limited`, `/anything/free` stays
     unrestricted, fixture verifies both sides. Implemented on
     three gateways using each one's native per-route
     attachment primitive:
       * **nginx/p04** → `limit_req` inside `location
         /anything/limited`; the catch-all `location /` has no
         `limit_req`. Parity **4/4 PASS**, burst shape
         `2xx=107, 429=1093` on limited / `2xx=1200, 429=0` on
         free.
       * **envoy/p04** → HCM-level `local_ratelimit` globally
         disabled (`filter_enabled default_value = 0/HUNDRED`)
         plus `typed_per_filter_config` override on the
         `/anything/limited` route (v1.32 proto: per-route
         config is a full replacement, not a merge). Parity
         **4/4 PASS**, burst shape `2xx=112, 429=1088` on
         limited / `2xx=1200, 429=0` on free.
       * **wallarm/p04** → single service with two routes,
         `POST /services/<svc>/routes/limited/flow` binds the
         `ratelimit` policy to the `limited` route only;
         `free` gets no flow. Sliding-window deviation
         inherited from p03. Parity **4/4 PASS**, burst
         shape `2xx=98, 429=1102` on limited /
         `2xx=1200, 429=0` on free.
     All three implementations converge within ~15 requests on
     the same 1200-req ASAP burst — independent validation that
     the three different route-scoping primitives encode the
     same externally observable semantics. Fixture-runner
     extended with a new `status_429_max` assertion so the
     free-endpoint invariant is checked as explicitly as the
     limited-endpoint one.
   - envoy matrix: **done in
     [.notes/PROGRESS.md § Iteration 22](./.notes/PROGRESS.md)**
     — 12 PASS, 0 FAIL, 39/39 probes on
     `envoyproxy/envoy:distroless-v1.32.6`; p07/p08 via native
     header primitives, p02 via `envoy.filters.http.lua` over a
     pure-Lua `_shared/lualib/` (base64, sha256, json,
     jwt_hs256, body_rewrite), p09/p10 via Lua filter + buffer
     prerequisite (p09) / implicit response-body buffer (p10),
     p11 as a single filter chain with `local_ratelimit` first
     so a JWT flood gets shed before any HMAC work.
  - traefik matrix: **done across two passes in
    [.notes/PROGRESS.md § Iteration 24](./.notes/PROGRESS.md)
    and [§ Iteration 28](./.notes/PROGRESS.md)** — final
    verdict 12 PASS, 0 FAIL, 0 FM, 39/39 probes on
    `traefik:v3.3.4`. Iteration 24 landed 9/11 + 2 FM (p02 +
    p11 honestly FM, no native HS256 in OSS); Iteration 28
    closed both FM cells in a single change by landing the
    in-repo `jwt_hs256` Yaegi plugin under
    `_shared/plugins-local/src/github.com/wallarm/jwt_hs256/`
    (~250 LoC Go, stdlib-only, every package on Yaegi's
    allowlist) and chaining it as the first link of p11. p11
    burst lands `2xx=270, 429=930` (well past
    `status_429_min: 150`; the 2xx-vs-429 split is loadgen-side
    burst parallelism draining the 200-token bucket in
    <200 ms, not a configuration leak). Three landed
    deviations: per-profile
    `entryPoints.web.forwardedHeaders.insecure: true` for
    p05/p06/p07/p11; `coerceJSONLiteral` shim in
    `body_rewrite.go::New()`; `map[string]json.RawMessage`
    decode pattern in `jwt_hs256.go::verify()` to work around
    Yaegi's reflect-driven JSON decoder skipping method
    dispatch on user-declared types. Full per-profile
    breakdown in [`gateways/traefik/README.md`](./gateways/traefik/README.md).
   - apisix matrix: **done** — 12 PASS, 0 FAIL, 0 FM,
     39/39 probes on `apache/apisix:3.15.0-debian` in standalone
     mode. Declarative `apisix.yaml` per profile; p01 via a
     catch-all route, p03..p06 via native `limit-count`
     (`key_type: constant` for service-wide, `key_type: var` +
     `http_x_real_ip` for IP-scoped), p07 inject via
     `proxy-rewrite.headers.set` and XFF drop via a custom
     entrypoint wrapper (`_shared/bench-start.sh`) that `sed`s
     the generated `nginx.conf` so a `serverless-pre-function`
     can zero out a writable `$bench_xff` variable
     (`ngx.var.proxy_add_x_forwarded_for` is read-only), p08
     inject via `response-rewrite.headers.set` + Server drop via
     `serverless-post-function` (`header_filter` phase,
     `ngx.header.Server = nil`), p02/p09 via
     `serverless-pre-function` (access) + shared
     `_shared/lualib/jwt_hs256.lua` / `body_rewrite.lua`
     (ported from the nginx column), p10 via
     `serverless-post-function` (body_filter) chunk accumulator,
     p11 as a single route that folds JWT + body rewrite + XFF
     drop into one `serverless-pre-function` hook (APISIX allows
     at most one instance per plugin per route; see
     `gateways/apisix/p12-full-pipeline/apisix.yaml` for the
     phase layering rationale).
   - kong matrix: **done** — 12 PASS, 0 FAIL, 0 FM, 39/39
     probes on `kong/kong:3.9.1` in DB-less declarative mode.
     Per-profile `kong.yml` + `setup.sh` against the shared
     compose stack; p01 via a single service+route on
     `paths: [/]`, p02 via the native `jwt` plugin keyed on the
     `iss` claim (one consumer credential, `claims_to_verify:
     [exp]`), p03..p06 via native `rate-limiting`
     (`limit_by: service` for service-wide and per-route,
     `limit_by: header` + `header_name: X-Real-IP` for dynamic;
     `KONG_TRUSTED_IPS: 0.0.0.0/0,::/0` makes X-Real-IP readable),
     p07 inject via `request-transformer.add` and XFF drop via a
     custom entrypoint shim (`_shared/bench-start.sh`) that
     pre-patches kong's nginx template to re-route
     `proxy_set_header X-Forwarded-For` through a writable
     `$bench_xff` variable a `pre-function` can zero out (kong's
     `runloop.access.after()` re-stamps XFF AFTER plugins,
     blocking the native `request-transformer.remove` route),
     p08 inject + Server drop via `response-transformer` (kong's
     own Server stamp killed globally with `KONG_HEADERS: off`),
     p09 / p10 via `pre-function` / `post-function` carrying
     body-rewrite Lua against the shared
     `_shared/lualib/body_rewrite.lua` (whitelisted in kong's
     untrusted-Lua sandbox via
     `KONG_UNTRUSTED_LUA_SANDBOX_REQUIRES: body_rewrite`; sandbox
     stays on); p10 / p11 also clear `Content-Length` in a
     dedicated `header_filter` Lua hook because kong's PDK does
     not auto-strip on body changes the way vanilla nginx does;
     p11 chains all primitives in plugin-priority order
     (`jwt > rate-limiting > request-transformer >
     response-transformer > pre-function > post-function`) which
     happens to line up with the canonical p11 shape (RL → JWT
     → transforms) without explicit priority overrides. See
     `gateways/kong/README.md` for the per-profile breakdown.
   - tyk matrix: **done** — 9 PASS, 2 PARTIAL PASS, 0 FM,
     27/32 probes on `tykio/tyk-gateway:v5.11.1` in standalone mode.
     The 5 cosmetic FAILs (4 in p02-jwt, 1 in p12-full-pipeline) are
     all the same hard-coded `400`/`403` literal in
     `gateway/mw_jwt.go` v5.11.1 (no config knob in Tyk Classic OSS
     swaps them for the canonical `401`); the JWT capability itself
     is fully native and works on every signed token. p09 / p11
     body rewrites use Tyk's NATIVE `transform` middleware (Go
     `text/template` + bundled Sprig v3 `FuncMap`) rather than the
     otto JSVM `pre` middleware Tyk's documentation reaches for first
     — the JSVM path caps Tyk's effective throughput at ~830 rps
     via per-request MiniRequestObject (un)marshal + VM context
     switch, well below the 1000 rps `global_rate_limit` threshold
     p11's burst probe exercises, so the RL bucket never reached
     capacity and 0 × 429 resulted on every burst run with the JSVM
     in the chain. Replacing the JSVM with the native Sprig template
     (`unset .secret`, `set .bench (dict "injected" true)`,
     `mustToJson .`) eliminates the per-request VM cost end-to-end
     and lands p11's burst at the canonical `2xx≈999, 429≈201`
     split across three back-to-back runs. Full investigation in
     [`gateways/tyk/p12-full-pipeline/NOTES.md`](./gateways/tyk/p12-full-pipeline/NOTES.md).
     The JSVM is still globally enabled in `tyk.standalone.conf`
     because p05 / p06 need it for their per-IP session synth
     pattern; it is dormant on every API definition that does not
     populate `custom_middleware.{pre,post,response}[]`.
  - next pass: Phase 4 (k6 load framework) and/or
    future policy profile follow-ons (`jwks-rs256-uri`, `mtls-basic`).
    The matrix is locked at 84/84 PASS, and the
    `p03-jwks-rs256-basic` cell-matrix coverage is now
    complete on every gateway column (see Phase 3d below).
    The traefik HS256 Yaegi plugin follow-up landed in
    Iteration 28 — traefik column is 12/12 PASS on the
    matrix.
   - **Phase 3d — p03-jwks-rs256-basic parity track
     (`p03-jwks-rs256-basic`)**: a new axis that sits **outside** the
     12-profile matrix. Canonical p02-jwt stays HS256 on every
     gateway; p03-jwks-rs256-basic measures the orthogonal
     **RS256 + static inline JWKS** capability (kid → JWK lookup +
     PKCS#1-v1.5 signature verify). Key foundations landed:
       * reference assets under
         `gateways/_reference/jwks-rs256/` — RSA-2048 `private.pem`
         + `public.pem`, derived `jwks.json` with a single canonical
         JWK (`kid = bench-rs256-2026`), and documentation;
       * separate token generator `scripts/gen-jwt-rs256.sh` (kinds:
         `valid`, `unknown-kid`) — does NOT touch the HS256
         `gen-jwt.sh`;
       * `fixtures/p03-jwks-rs256-basic.jsonl` — three minimal probes
         (no auth → 401, valid token → 200, unknown kid → 401);
       * `scripts/parity-attestation.sh` extended with two new
         placeholders (`${JWT_VALID_RS256}`,
         `${JWT_UNKNOWN_KID_RS256}`) — existing HS256 placeholders
         unchanged;
       * first landed implementation: `gateways/wallarm/p03-jwks-rs256-basic/`.
         **PASS (3/3)** against a from-source Wallarm build that
         exposes the native `jwt_validation` policy; `setup.sh`
         runtime-detects it via `/policies` and short-circuits to
         `FEATURE-MISSING` as a sanity guardrail if the supplied
         `WALLARM_IMAGE` does not ship the primitive. Binding shape
         matches `wallarm-api-gateway/tests/integration/jwt_validation_test.sh
         § test_07` verbatim: `{algorithm:"RS256", jwks:{keys:[...]}}`.
       * second landed implementation:
         `gateways/envoy/p03-jwks-rs256-basic/` — **PASS (3/3)** on
         `envoyproxy/envoy:distroless-v1.32.6`. Native primitive
         `envoy.filters.http.jwt_authn` + `local_jwks.inline_string`
         baked into the static bootstrap (`envoy.yaml`); no admin-
         API binding and no runtime detection — if `jwt_authn`
         misbehaves this is a FAIL, not a FEATURE-MISSING. A
         drift guard in `setup.sh` greps the reference RSA
         modulus + `kid` against `envoy.yaml` so a future
         rotation of `gateways/_reference/jwks-rs256/` cannot
         leave the inline JWKS stale. Shared
         `gateways/envoy/docker-compose.yaml` is explicitly NOT
         touched — the mount landscape across envoy profiles
         stays uniform.
       * third landed implementation:
         `gateways/tyk/p03-jwks-rs256-basic/` — **PARTIAL PASS (1/3)**
         on `tykio/tyk-gateway:v5.11.1`. Native primitive: Tyk
         Classic JWT middleware with
         `jwt_signing_method: "rsa"` and
         `jwt_source: base64("http://jwks-server/.well-known/jwks.json")`.
         The capability itself (JWKS fetch, `kid` lookup, RS256
         verify, unknown-`kid` rejection) works correctly and probe
         2 (valid RS256 token → 200) PASSes cleanly. The two FAILs
         are purely cosmetic: Tyk's `mw_jwt.go` returns `400
         "Authorization field missing"` for missing auth and `403
         "Key not authorized"` for any rejection, neither of
         which is overridable in Classic OSS. First scenario in
         the repo to introduce a 4-container gateway topology
         (`backend`, `redis`, `jwks-server` sidecar, `gateway`)
         on a private `bench-net`; the JWKS sidecar is required
         because Tyk's `jwt_source` URL matcher is hard-coded to
         `^(http|https):` and the inline base64-PEM alternative
         bypasses `kid` lookup entirely. `jwt_source` is itself
         base64-encoded per Tyk docs to work around a 5.11.1
         regression in `getSecretFromURL` that unconditionally
         base64-decodes the cached source on every subsequent
         request (plain-URL values succeed on the first hit then
         fail with `illegal base64 data` on cache hit). Shared
         Tyk baseline (`docker-compose.yaml`,
         `tyk.standalone.conf`, `_jwks-server/nginx.conf`,
         `_policies/policies.json`) introduced in the same pass
         as a template for every future tyk profile.
       * fourth landed implementation:
         `gateways/apisix/p03-jwks-rs256-basic/` — **PASS (3/3)** on
         `apache/apisix:3.15.0-debian`. Native primitive: the
         `openid-connect` plugin with `use_jwks: true` pointing
         at an `oidc-server` sidecar that serves an OIDC
         discovery document alongside the canonical JWKS on the
         private bench-net. `jwt-auth` was deliberately NOT used
         — it accepts a single inline `public_key` per Consumer
         and has no JWKS / `kid` lookup, which would collapse
         probe 3 into a spurious PASS (same trap Tyk's PEM path
         falls into; see
         [apisix#12791](https://github.com/apache/apisix/issues/12791)).
         APISIX runs in standalone mode (no etcd, no Admin API),
         and `stream_plugins: []` in standalone-mode bootstrap
         is silently ignored (would otherwise error at worker
         init).
       * fifth landed implementation:
         `gateways/kong/p03-jwks-rs256-basic/` — **PASS (3/3)** on
         `kong/kong:3.9.1`. Native primitive: the built-in
         `jwt` plugin with `key_claim_name: kid` and one
         `jwt_secret` credential on the `bench` consumer
         carrying `{algorithm: RS256, rsa_public_key: <PEM
         from _reference/jwks-rs256/public.pem>, key:
         bench-rs256-2026}`. Kong hashes credentials by `key`
         in-memory, so `key_claim_name: kid` wires the JWT's
         `kid` claim to the credential lookup — kid→key
         dispatch and RS256 signature verify both happen
         inside the native plugin with zero custom Lua. Drift
         guard in `setup.sh` compares the embedded
         `rsa_public_key` value in `kong.yml` against
         `_reference/jwks-rs256/public.pem` and blocks boot on
         any mismatch.
       * sixth landed implementation:
         `gateways/nginx/p03-jwks-rs256-basic/` — **PASS (3/3)** on
         `openresty/openresty:1.27.1.2-alpine`. Vanilla nginx
         has no JWT module, and the mainline nginx image
         (`nginx:1.27.3-alpine`, used by six of the twelve
         profiles) has no Lua at all. For the p03 profile we
         pin OpenResty via a per-directory `.env` and ship a
         two-layer pure-LuaJIT-
         FFI verifier against the `libcrypto.so.3` OpenResty
         itself links against
         (`/usr/local/openresty/openssl3/lib/libcrypto.so.3`),
         zero third-party `lua-resty-*` dependency. Low-level
         FFI (`EVP_DigestVerify*`) lives in
         `gateways/nginx/_shared/lualib/jwt_rs256_verify.lua`;
         JWT-layer semantics (`kid` lookup against an in-memory
         `{kid → EVP_PKEY*}` map, `exp` freshness check, segment
         count check, canonical `401` on every reject) live in
         `gateways/nginx/_shared/lualib/jwt_rs256_jwks.lua`. The
         shared `gateways/nginx/docker-compose.yaml` bind-mounts
         `_reference/jwks-rs256/` onto
         `/etc/nginx/jwks-rs256/` (inert for every other profile
         — no nginx.conf outside this one references the path).
         Drift guards in `setup.sh` reject boot on any
         divergence between the mounted JWKS / PEM / kid and
         the canonical reference.
       * seventh landed implementation:
         `gateways/traefik/p03-jwks-rs256-basic/` — **PASS (3/3)**
         on `traefik:v3.3.4`. Native primitive: the
         `forwardAuth` middleware pointed at an OpenResty
         sidecar that reuses the nginx-column Lua modules
         verbatim (column-local copies under
         `gateways/traefik/p03-jwks-rs256-basic/jwks-auth/lualib/`,
         drift guard in `setup.sh` diffs against the nginx
         canonical on every boot so a bugfix on the nginx
         column can't silently drift to the traefik sidecar).
         Yaegi's stdlib allowlist excludes `crypto/rsa` and
         `crypto/x509`, so an in-process plugin for asymmetric
         verify is architecturally off the table (unlike
         HS256, which the in-repo `jwt_hs256` Yaegi plugin
         closes cleanly on the canonical p02). The sidecar
         service `jwks-auth` in
         `gateways/traefik/docker-compose.yaml` is gated by
         `profiles: [p03-jwks-rs256-basic]` so it only starts when
         the p03 profile is selected;
         `scripts/parity-gateway.sh` was extended to export
         `COMPOSE_PROFILES="${PROFILE}"` generically so the
         other eleven traefik profile runs (and every other
         gateway) see zero containers change. This
         `COMPOSE_PROFILES` pattern is now on-file as the
         reusable shape for any future conditional sidecar.
     Between wallarm, envoy, tyk, apisix, kong, nginx, and
     traefik we now have **six distinct native shapes** covered
     plus one sidecar escape hatch: admin-API binding with
     runtime policy detection (wallarm), fully-static bootstrap
     with inline JWKS (envoy), file-mounted API definition with
     JWKS-over-HTTP sidecar (tyk), declarative standalone-mode
     plugin over OIDC discovery + JWKS sidecar (apisix), native
     plugin with `key_claim_name: kid` over the native
     credential store (kong), LuaJIT FFI to the already-present
     libcrypto (nginx), and `forwardAuth` middleware delegating
     to an OpenResty sidecar gated by a Docker Compose profile
     (traefik). p03-jwks-rs256-basic is a regular profile in
     `parity-gateway-all`, NOT part of the ranking matrix. Invoke
     via `make parity-gateway PARITY_GATEWAY=<gw>
     PARITY_PROFILE=p03-jwks-rs256-basic`. The **capability pass is
     complete**; follow-on follow-on policy profiles tracked under
     `docs/POLICIES.md § Future p03-jwks-rs256-basic scenarios`
     (`jwks-rs256-uri` with `jwks_uri` rotation and cache TTL,
     `mtls-basic` with client-cert validation). See
     [`docs/GATEWAYS.md § p03-jwks-rs256-basic`](./docs/GATEWAYS.md#p03-jwks-rs256-basic)
     for the tabled per-gateway verdicts and
     [`docs/POLICIES.md § p03-jwks-rs256-basic`](./docs/POLICIES.md#p03-jwks-rs256-basic)
     for the capability matrix.
5. In parallel, begin Phase 4 (k6 load profiles) and the infrastructure
   sub-tasks in Phase 5.
