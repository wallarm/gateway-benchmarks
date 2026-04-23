# Gateway Benchmarks

> Reproducible, vendor-neutral performance benchmarks for production API gateways under a **policy × protocol × load** matrix.

[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](./LICENSE)
[![Status: Phase 3b matrix complete](https://img.shields.io/badge/status-phase_3b_core_matrix_complete-brightgreen.svg)](./ROADMAP.md)

---

## TL;DR

We compare seven API gateways under **identical conditions** and let any independent reviewer:

1. Re-run the benchmark locally or on AWS with a single command.
2. Obtain a **byte-for-byte equivalent ranking** (within tolerance — see [docs/REPRODUCIBILITY.md](./docs/REPRODUCIBILITY.md)).
3. Verify that all gateways treat the same request the same way (**parity attestation**).
4. Inspect the full run manifest: image digests, git SHA, RNG seed, host info.

## Neutrality Disclaimer

This project is developed and maintained by **Wallarm, Inc.** — the author of one of the gateways under test. To neutralise the conflict of interest, we follow strict rules:

- All gateway configs, k6 scenarios, and infrastructure are **open and frozen at report release** (the git SHA is pinned in `manifest.json`).
- **Parity attestation** runs before every cell: the same request, the same JWT seed, the same rate-limit window — gateways either behave identically, or the cell is marked as a `deviation` and excluded from the aggregate.
- Reasonable external tuning of a competing gateway is accepted as a PR — see the [template](./.github/PULL_REQUEST_TEMPLATE.md) *(to be added in Phase 8)*.
- All deviations are documented in [docs/GATEWAYS.md](./docs/GATEWAYS.md) with a reason and an upstream reference.

## Gateways Under Test

| Gateway | Language | Role |
|---------|----------|------|
| [Wallarm API Gateway](https://github.com/wallarm/wallarm-api-gateway) | Rust | subject under test |
| NGINX                   | C                  | baseline |
| Envoy                   | C++                | baseline |
| HAProxy *(candidate)*   | C                  | baseline |
| Kong                    | Lua/OpenResty      | baseline |
| Apache APISIX           | Lua/OpenResty      | baseline |
| Traefik                 | Go                 | baseline |
| Tyk                     | Go                 | baseline |

11 **policy profiles** × 4 **load profiles** × two protocols (HTTP/1.1 plaintext and HTTP/1.1 TLS) — **364 cells per run** (see [TASK.md](./TASK.md)).

## Quick Start — Local mode

> Requirements: Linux/macOS host, Docker ≥ 24, 8+ physical cores, 16 GB RAM, `make`, `go ≥ 1.23`.

```bash
git clone https://github.com/wallarm/gateway-benchmarks
cd gateway-benchmarks

make prereqs-check          # verify the environment
make perf-local-up          # bring loadgen + gateway + backend up in separate namespaces
make perf-local-run         # run the full matrix (~45 min)
make perf-local-report      # produce HTML + CSV in reports/<timestamp>/
make perf-local-down
```

Result: `reports/<timestamp>_<sha>/report.html`.

## Quick Start — AWS mode

> Requirements: AWS credentials, `tofu` ≥ 1.7 (or `terraform` ≥ 1.6), ~$15 per full run.

```bash
cd infra/aws
cp terraform.tfvars.example terraform.tfvars    # set your CIDR and region
tofu init && tofu apply -auto-approve

cd ../..
make perf-aws-deploy        # provision the stack on all 3 EC2 hosts
make perf-aws-run           # run the matrix (same orchestrator)
make perf-aws-report        # pull raw data and render the report
make perf-aws-down          # tear down EC2 (edits tfvars and runs apply)
```

## Repository Layout

```
.
├── TASK.md           # PRD — what we measure and why
├── ROADMAP.md        # phased implementation plan
├── Makefile          # single entry point
├── backend/          # forked go-httpbin — a predictable upstream
├── gateways/         # per-gateway configs × policy profile
├── k6/               # load profiles and scenarios
├── orchestrator/     # Go binary driving the run
├── infra/
│   ├── local/        # docker-compose + resource pins
│   └── aws/          # Terraform (3 EC2 cluster PG)
├── scripts/          # prereqs, parity, deploy, fetch
├── reports/          # output runs (local-only, never tracked — see docs/REPORT.md)
└── docs/             # ARCHITECTURE / POLICIES / LOAD-PROFILES / GATEWAYS / REPRODUCIBILITY / REPORT
```

## Documentation

- [TASK.md](./TASK.md) — PRD (mandatory properties of the benchmark)
- [ROADMAP.md](./ROADMAP.md) — phased implementation plan
- [docs/ARCHITECTURE.md](./docs/ARCHITECTURE.md) — local/AWS topology and network path
- [docs/POLICIES.md](./docs/POLICIES.md) — 12 policy profiles and parity requirements
- [docs/LOAD-PROFILES.md](./docs/LOAD-PROFILES.md) — 4 load profiles
- [docs/GATEWAYS.md](./docs/GATEWAYS.md) — versions, digests, deviations
- [docs/REPRODUCIBILITY.md](./docs/REPRODUCIBILITY.md) — manifest, seeds, tolerance

## Current Status

The project is in early phases. No benchmark runs yet — we are building the foundation.

- [x] Phase 1 — Skeleton (README, directories, license, lint CI)
- [x] Phase 2 — Synthetic backend (vendored `mccutchen/go-httpbin@v2.22.1`, static Docker image, smoke-tested)
- [x] Phase 3a — Parity foundation (canonical values, reference assets, fixtures, `make parity-check[-all]`)
- [x] Phase 3b — Per-gateway configs (7 gateways × 12 policy profiles
  = 84 cells: 81 PASS + 3 PARTIAL, 0 FEATURE-MISSING, 5 cosmetic FAILs inside
  2 PARTIAL PASS cells; see Iteration 27 below)
    - [x] burst runner (p03 / p05 / p06) + `parity-gateway` lifecycle
      (now using `curl --parallel -K` for sustained 1200 rps bursts)
    - [x] `FEATURE-MISSING` short-circuit in `scripts/parity-gateway.sh`
    - [x] `wallarm / p01-vanilla` — 4/4 green against a from-source
      Wallarm API Gateway build (pass via `WALLARM_IMAGE`)
    - [x] `wallarm / p02-jwt` — 6/6 green, native `jwt_validation`
      policy bound on `request_flow` (HS256 against the shared
      bench secret). `setup.sh` sanity-checks `jwt_validation` in
      `/policies` and exits `FEATURE-MISSING` if absent.
    - [x] `wallarm / p04-rl-static` — 2/2 green, `ratelimit` policy with
      `rate=1000/1s`, sliding window
    - [x] `wallarm / p05-rl-endpoint` — 4/4 green, route-level
      `POST /services/<svc>/routes/<rt>/flow` on the `limited`
      route only, 100 rps, sliding window. Canonical wallarm
      per-route policy-attachment idiom — the direct analogue of
      envoy's `typed_per_filter_config` and nginx's `limit_req`
      inside a `location` block.
    - [x] `wallarm / p08-req-headers` — 3/3 green, `lua_runner` on
      `request_flow` (`+X-Bench-In`, `-X-Forwarded-For`)
    - [x] `wallarm / p09-resp-headers` — 2/2 green, `lua_runner` on
      `response_flow` (`+X-Bench-Out`, `-Server`)
    - [x] `wallarm / p10-req-body` — 3/3 green, `lua_runner` +
      `cjson.safe` on `request_flow` (`+$.bench.injected`,
      `-$.secret`, Content-Length recomputed)
    - [x] `wallarm / p11-resp-body` — 3/3 green, `lua_runner` +
      `cjson.safe` on `response_flow` (`+$.bench.injected`,
      `-$.origin`, Content-Length recomputed)
    - [x] `wallarm / p06-rl-dynamic-low` — 2/2 green, `ratelimit`
      keyed on `X-Real-IP`, rate=10/s, sliding window
    - [x] `wallarm / p07-rl-dynamic-high` — 3/3 green, same policy
      shape as p05 with rate=100/s
    - [x] `wallarm / p12-full-pipeline` — 4/4 green, composes
      `jwt_validation + ratelimit + lua` in canonical order.
    - Wallarm roster: **12 PASS, 0 FAIL, 39/39 probes** against a
      from-source Wallarm API Gateway build. The previous dual-track
      "9 PASS / 2 FEATURE-MISSING on the public 0.2.0 image" was
      retired in [.notes/PROGRESS.md § Iteration 23](./.notes/PROGRESS.md) —
      the benchmark is now single-track against builds that ship the
      full policy surface (`jwt_validation`, `ratelimit`, `lua_runner`).
      Runners provide `WALLARM_IMAGE=wallarm/api-gateway:main-<sha>`
      at invocation time; setup scripts keep a `FEATURE-MISSING`
      sanity guard for misaligned image overrides.
    - [x] `nginx / p01-vanilla` — 4/4 green on `nginx:1.27.3-alpine`
      (catch-all `proxy_pass`, uniform settings fully expressed in
      `nginx.conf`, zero deviations)
    - [x] `nginx / p04-rl-static` — 2/2 green (`limit_req_zone
      $server_name rate=1000r/s` + `burst=200 nodelay` +
      `error_page 429 @retry_after`; 1200-req burst →
      `2xx=262, 429=938, 5xx=0`)
    - [x] `nginx / p05-rl-endpoint` — 4/4 green. `limit_req zone=
      bench_p05 burst=100 nodelay` placed INSIDE
      `location /anything/limited` while the catch-all `location /`
      has no `limit_req` directive. Burst shape on the limited
      path: `2xx=107, 429=1093, 5xx=0`; the scoping invariant is
      exercised by a parallel burst on `/anything/free` that must
      see `429=0` (new fixture-runner assertion:
      `status_429_max`). Location-scoped `limit_req` is nginx's
      direct analogue of envoy's per-route `typed_per_filter_config`.
    - [x] `nginx / p06-rl-dynamic-low` — 2/2 green
      (`limit_req_zone $http_x_real_ip rate=10r/s` +
      `burst=10 nodelay`; 10 IPs × 45 req → `2xx=109, 429=341` —
      symmetric to wallarm/p05 within one request)
    - [x] `nginx / p07-rl-dynamic-high` — 3/3 green (same mechanism,
      `zone=10m rate=100r/s` + `burst=20 nodelay`, zone sized for
      the 50 000-IP pool per POLICIES.md; burst #2 →
      `2xx=24, 429=476`)
    - [x] `nginx / p08-req-headers` — 3/3 green on mainline
      (`proxy_set_header X-Bench-In "1";` +
      `proxy_set_header X-Forwarded-For "";` empty-string drop
      idiom; no Lua, no extra module)
    - [x] `nginx / p09-resp-headers` — 2/2 green on
      `openresty/openresty:1.27.1.2-alpine` (first nginx cell
      that overrides the base image — uses bundled
      `ngx_headers_more`'s `more_clear_headers "Server"` because
      mainline has no directive to remove the built-in Server
      response header). Image override declared in
      `gateways/nginx/p09-resp-headers/.env`; `parity-gateway.sh`
      now passes it via `docker compose --env-file` (generic
      per-profile override contract — also carries OpenResty pins
      for p02/p09/p10/p11 cells below).
    - [x] `nginx / p02-jwt` — 6/6 green on OpenResty. ~60-line
      pure-Lua HS256 verifier at
      `gateways/nginx/_shared/lualib/jwt_hs256.lua`, uses bundled
      `resty.sha256` + `cjson.safe` + `bit.bxor` via classic
      RFC 2104 HMAC construction (no `lua-resty-jwt` dependency —
      keeps digest-pin reproducibility intact). **First gateway
      where p02 lands on an off-the-shelf public image** (wallarm
      also passes natively, but on a from-source build).
    - [x] `nginx / p10-req-body` — 3/3 green on OpenResty.
      `access_by_lua_block` + `ngx.req.set_body_data`
      (auto-patches Content-Length); shared cjson helper at
      `gateways/nginx/_shared/lualib/body_rewrite.lua` injects
      `$.bench.injected`, drops `$.secret`.
    - [x] `nginx / p11-resp-body` — 3/3 green on OpenResty.
      Canonical two-phase Lua pattern:
      `header_filter_by_lua_block` clears Content-Length,
      `body_filter_by_lua_block` buffers chunks and rewrites on
      EOF. Non-JSON responses pass through untouched.
    - [x] `nginx / p12-full-pipeline` — 4/4 green on OpenResty.
      Composes p02+p03+p07+p08+p09+p10 in one request flow. nginx
      phase ordering (`PREACCESS → ACCESS → CONTENT →
      header/body_filter`) encodes the semantics for free; burst
      probe at 1200 rps of valid-JWT GETs observes
      `2xx=0, 429=945, 5xx=0` (rate-limit fires before Lua auth,
      as the fixture expects). **First gateway in the bench with
      a complete green p11** on an off-the-shelf public image
      (wallarm also closes p11 natively but needs a from-source
      build for `jwt_validation`).
    - **nginx column snapshot**: **12 PASS, 0 FAIL, 39/39 probes**
      across all 12 canonical profiles (`nginx:1.27.3-alpine` for
      mainline, `openresty:1.27.1.2-alpine` for Lua profiles).
      **nginx is the first gateway to close every cell** — including
      the new `p05-rl-endpoint` per-endpoint RL axis. Warm
      sweep wall-clock: ~15 s. `p03-jwks-rs256-basic`
      also lands on nginx as **3/3 PASS** on
      `openresty:1.27.1.2-alpine`, pure LuaJIT FFI to the
      `libcrypto.so.3` OpenResty itself links against
      (`EVP_DigestVerify*`); no third-party `lua-resty-*`
      dependency and no Dockerfile layer bump. Two-layer shared
      Lua library at
      `gateways/nginx/_shared/lualib/jwt_rs256_verify.lua` +
      `gateways/nginx/_shared/lualib/jwt_rs256_jwks.lua`.
    - [x] `envoy` — **12 PASS, 0 FAIL, 39/39 probes** across all 11
      canonical profiles on
      `envoyproxy/envoy:distroless-v1.32.6` (closed in
      [.notes/PROGRESS.md § Iteration 22](./.notes/PROGRESS.md)).
      p01/p03/p04/p05/p06 are the native rate-limit + routing
      baseline; p02/p07/p08/p09/p10/p11 lean on
      `envoy.filters.http.lua` with pure-Lua shared modules
      under `gateways/envoy/_shared/lualib/`
      (`base64.lua`, `sha256.lua`, `json.lua`, `jwt_hs256.lua`,
      `body_rewrite.lua`) — API-identical to the nginx column's
      OpenResty-bundled versions so invariants are
      reviewer-checkable by eyeball diff. Notable non-obvious
      knobs that landed: `max_connection_duration` left unset
      (the explicit `0s` means "close at t=0", not "no
      maximum"); `server_header_transformation: PASS_THROUGH`
      is required alongside `response_headers_to_remove:
      [server]` for p08; envoy's request-body buffering is
      explicit (`envoy.filters.http.buffer` before the Lua
      filter for p09) while response-body buffering is implicit
      (first call to `response_handle:body()` installs the
      buffer in p10); method guard on `buf:setBytes` protects
      the keep-alive pool by skipping the rewrite on
      GET/HEAD/DELETE. `p03-jwks-rs256-basic` also
      lands on envoy as **3/3 PASS** via native
      `envoy.filters.http.jwt_authn` with inline JWKS.
    - [x] `traefik` — **12 PASS, 0 FAIL, 39/39 probes** on
      `traefik:v3.3.4` (Iteration 24 landed 9/11 + 2 FM,
      [Iteration 28](./.notes/PROGRESS.md) closed the FM cells
      to deliver the full column). p01/p03/p04/p05/p06/p07/p08
      use only native middleware primitives (`rateLimit` with
      `sourceCriterion.requestHeaderName: X-Real-IP` for
      p05/p06, `headers.customRequestHeaders` /
      `customResponseHeaders` with empty-string drop idiom for
      p07/p08); p09/p10 use a custom Yaegi plugin
      `body_rewrite` shipped in-repo under
      `gateways/traefik/_shared/plugins-local/src/github.com/
      wallarm/body_rewrite/` (~160 LoC Go, stdlib-only); p02
      and p11 use a second custom Yaegi plugin `jwt_hs256` in
      the same `_shared/plugins-local/` tree (~250 LoC Go,
      stdlib-only: `crypto/hmac`, `crypto/sha256`,
      `encoding/base64`, `encoding/json`, `time`, `net/http`,
      `strings`, `context` — every package on Yaegi's
      allowlist). p11 chains six middleware in canonical order
      (`bench-p02 → bench-p04 → bench-p08 → bench-p10 →
      bench-p09 → bench-p11`), with the burst probe landing
      `2xx=270, 429=930` (well past the `status_429_min: 150`
      threshold; the lopsided split is loadgen-side burst
      parallelism draining the rate-limit's 200-token bucket
      in <200 ms). Three landed deviations: per-profile
      `entryPoints.web.forwardedHeaders.insecure: true` in
      p05/p06/p07/p11 (traefik strips `X-Real-IP` /
      `X-Forwarded-For` as untrusted forwarded headers by
      default; also: traefik's static config sources are
      mutually exclusive — the knob MUST live in YAML, CLI
      flags alongside `--configFile` are silently ignored);
      `coerceJSONLiteral` shim in `body_rewrite.go::New()`
      for the YAML → plugin-config pipeline, which stringifies
      scalar boolean/number literals; and the
      `map[string]json.RawMessage` decode pattern in
      `jwt_hs256.go::verify()` to work around Yaegi's
      reflect-driven JSON decoder skipping method dispatch
      on user-declared types (the textbook custom-
      `UnmarshalJSON` pattern silently fails inside Yaegi).
      `p03-jwks-rs256-basic` also lands on traefik as
      **3/3 PASS** via a native `forwardAuth` middleware
      delegating to an OpenResty sidecar that reuses the
      nginx-column Lua modules verbatim — Yaegi's allowlist
      excludes `crypto/rsa`, so in-process asymmetric verify is
      architecturally off the table. Sidecar is gated by
      Docker Compose profile `p03-jwks-rs256-basic` so the core-
      matrix runs see zero containers change
      (`scripts/parity-gateway.sh` now exports
      `COMPOSE_PROFILES="${PROFILE}"` generically — reusable
      shape for any future conditional sidecar).
    - [x] `apisix` — **12 PASS, 0 FAIL, 39/39 probes** on
      `apache/apisix:3.15.0-debian` in standalone mode (closed in
      [.notes/PROGRESS.md § Iteration 25](./.notes/PROGRESS.md)).
      Native `limit-count` (service-wide / per-route /
      header-keyed), `proxy-rewrite`, `response-rewrite`, and
      `serverless-pre-function` / `serverless-post-function` for
      JWT (HS256 via shared `_shared/lualib/jwt_hs256.lua`) and
      body rewrites (shared `body_rewrite.lua` ABI-identical to
      the nginx column). Two infra hooks: `extra_lua_path` plus a
      bind-mount of `_shared/lualib` (so OpenResty can `require`
      the shared modules), and the same XFF re-stamping
      workaround as kong (apisix's runloop re-emits XFF after
      plugins, blocking the native `proxy-rewrite.headers.remove`
      path; closed via a fused `serverless-pre-function`).
    - [x] `kong` — **12 PASS, 0 FAIL, 39/39 probes** on
      `kong/kong:3.9.1` in DB-less declarative mode (closed in
      [.notes/PROGRESS.md § Iteration 26](./.notes/PROGRESS.md)).
      Native `jwt` plugin keyed on `iss` (one consumer
      credential per issuer, not per token — cleaner than
      apisix's `jwt-auth` for our one-shared-secret model),
      `rate-limiting`, `request-transformer`, `response-
      transformer`, `pre-function` / `post-function` carrying
      body-rewrite Lua against the byte-for-byte `body_rewrite.lua`
      port. Three infra hooks: a custom entrypoint shim
      (`_shared/bench-start.sh`) pre-patches kong's nginx template
      to re-route `proxy_set_header X-Forwarded-For` through a
      writable `$bench_xff` variable; the env pair
      `KONG_UNTRUSTED_LUA: sandbox` +
      `KONG_UNTRUSTED_LUA_SANDBOX_REQUIRES: body_rewrite`
      whitelists the shared module inside kong's Lua sandbox
      without disabling sandboxing globally; and a `header_filter`
      Lua hook in p10/p11 clears `Content-Length` (kong's PDK
      does not auto-strip on body changes the way vanilla nginx
      does). `p03-jwks-rs256-basic` also lands on kong as
      **3/3 PASS** via the native `jwt` plugin with
      `key_claim_name: kid` plus one consumer `jwt_secret`
      credential carrying `algorithm: RS256` and
      `rsa_public_key: <PEM>` — Kong's per-consumer credential
      store indexes by `key`, so setting `key_claim_name: kid`
      wires the JWT's `kid` claim to the lookup: kid→key dispatch
      and RS256 signature verify both happen inside the native
      plugin with zero custom Lua.
    - [x] `tyk` — **9 PASS, 2 PARTIAL PASS, 27/32 probes** on
      `tykio/tyk-gateway:v5.11.1` in standalone (file-based apps +
      policies) mode (closed in
      [.notes/PROGRESS.md § Iteration 27](./.notes/PROGRESS.md)).
      Every canonical capability is green: `global_rate_limit`
      (p03), `extended_paths.rate_limit` (p04), JSVM per-IP session
      synth (p05/p06), `transform_headers` /
      `transform_response_headers` (p07/p08), and the
      request/response body rewrites (p09/p10) which both use
      Tyk's NATIVE `transform` / `transform_response` middleware
      against shared Sprig v3 templates. The 5 cosmetic FAILs
      (4 in p02-jwt, 1 in p12-full-pipeline) are all the same
      hard-coded `400`/`403` from `gateway/mw_jwt.go` v5.11.1
      (literal `http.StatusBadRequest` / `http.StatusForbidden`
      with no config knob in the Classic API def or
      `tyk.standalone.conf` that swaps them for `401`); the JWT
      capability itself works on every probe. p09 was migrated
      off the JSVM `pre` middleware during the p11 rollout: the
      otto driver caps Tyk's effective throughput at ~830 rps
      (per-request `MiniRequestObject` (un)marshal + VM context
      switch), well below the 1000 rps `global_rate_limit`
      threshold p11's burst probe exercises, so the RL bucket
      never reached capacity and 0 × 429 resulted on every burst
      run with the JSVM in the chain. Replacing it with the
      native Sprig template (Sprig v3 is wired into every Tyk
      Classic Go template via
      `apidef.APIDefinitionLoader.filterSprigFuncs`) lands p11's
      burst at the canonical `2xx≈999, 429≈201` split.
    - **Phase 3b matrix verdict (7 gateways × 11 policy
      profiles = 84 cells):** **81 PASS + 3 PARTIAL (tyk status-code deviations), 0 FEATURE-MISSING, 0
      unaccounted FAIL**, with 5 cosmetic FAILs inside the 2 tyk
      PARTIAL PASS cells (all tracing to one fixed `mw_jwt.go`
      literal). Six full-green columns (nginx, envoy,
      wallarm, apisix, kong) plus traefik 12/12 after
      Iteration 28 closed the 2 FM cells via the in-repo
      `jwt_hs256` Yaegi plugin, leaving tyk 9/12 + 3 PARTIAL PASS
      as the lone non-fully-green column. Closed by
      [.notes/PROGRESS.md § Iteration 28](./.notes/PROGRESS.md).
    - **Phase 3b p03-jwks-rs256-basic track (capability pass)
      verdict (7 gateways × 1 p03 profile = 7 cells):**
      **6 PASS, 1 PARTIAL PASS (tyk), 0 FEATURE-MISSING**.
      `p03-jwks-rs256-basic` exercises the orthogonal RS256 + JWKS
      axis (kid→JWK lookup + asymmetric signature verify) that
      sits **outside** the 12-profile matrix by design — the
      canonical `p02-jwt` stays HS256 on every gateway, so the
      shape of that question doesn't bend to accommodate
      asymmetric crypto. Six distinct native primitives cover
      the seven columns: wallarm `jwt_validation` with inline
      JWKS, envoy `envoy.filters.http.jwt_authn` with
      `local_jwks.inline_string`, kong `jwt` plugin with
      `key_claim_name: kid` over its per-consumer credential
      store, apisix `openid-connect` plugin with `use_jwks: true`
      over an OIDC-discovery sidecar, nginx LuaJIT FFI to the
      already-present `libcrypto.so.3`, traefik `forwardAuth`
      middleware delegating to an OpenResty sidecar gated by a
      Docker Compose profile, and tyk Classic JWT middleware
      with `jwt_signing_method: "rsa"` over a private-net JWKS
      sidecar (the one PARTIAL — capability works, rejection
      status codes are hard-coded `400`/`403` in `mw_jwt.go`).
      p03-jwks-rs256-basic is a regular profile in
      `parity-gateway-all`, NOT part of the ranking matrix;
      invoke via `make parity-gateway PARITY_GATEWAY=<gw>
      PARITY_PROFILE=p03-jwks-rs256-basic`.
- [~] Phase 4 — k6 load framework (4 profiles × 13 scenarios). **Iteration 29
  landed the foundation**: pinned
  `grafana/k6:1.7.1@sha256:4fd3a694926b064d3491d9b02b01cde886583c4931f1223816e3d9a7bdfa7e0f`
  + all 4 load profiles
  (`p1-baseline`/`p2-sustained`/`p3-ramp`/`p4-stress`) under
  `k6/profiles/` + `k6/lib/{env,options,jwt,payloads,metrics}.js`
  helpers (single source of truth for env vars, runtime dispatch on
  `BENCH_LOAD_PROFILE`, four-bucket custom-metric classifier matching
  the four error columns from `TASK §8`) + `k6/scenarios/s01-vanilla-
  http.js` as the first scenario + `scripts/load-gateway.sh` runner
  that mirrors `scripts/parity-gateway.sh` lifecycle byte-for-byte
  (compose up → setup → parity precondition → JWT mint on host →
  k6 on `bench-net` → trap teardown) + `make load-gateway[-load-
  sweep]` Makefile entries. Smoke verified end-to-end against nginx:
  **PASS, 1 417 860 requests / 60s (≈23.6k RPS), p95=1.23 ms, 0
  failures, parity precondition PASS, 100% checks on Apple Silicon
  Docker Desktop**. Remaining 13 scenarios + paced
  `constant-arrival-rate` variants + access-log silence sweep across
  the 84 profile configs are explicit follow-ups (not Phase 4
  blockers — they don't change the framework, only the per-cell
  config); HTTPS variants land alongside Phase 5 (TLS infrastructure
  is a prerequisite). See
  [.notes/PROGRESS.md § Iteration 29](./.notes/PROGRESS.md).
- [ ] Phase 5 — Infra (local + AWS 3-EC2)
- [ ] Phase 6 — Go orchestrator
- [ ] Phase 7 — Report generator
- [ ] Phase 8 — Quality gates + docs
- [ ] Phase 9 — Publication / v0.1.0

See [ROADMAP.md](./ROADMAP.md) for details.

## License

Apache 2.0 — see [LICENSE](./LICENSE).
