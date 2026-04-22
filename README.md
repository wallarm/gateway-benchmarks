# Gateway Benchmarks

> Reproducible, vendor-neutral performance benchmarks for production API gateways under a **policy × protocol × load** matrix.

[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](./LICENSE)
[![Status: Phase 3b in progress](https://img.shields.io/badge/status-phase_3b_in_progress-orange.svg)](./ROADMAP.md)

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

10 **policy profiles** × 4 **load profiles** × two protocols (HTTP/1.1 plaintext and HTTP/1.1 TLS) — **336 cells per run** (see [TASK.md](./TASK.md)).

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
├── reports/          # output runs
└── docs/             # ARCHITECTURE / POLICIES / LOAD-PROFILES / GATEWAYS / REPRODUCIBILITY / REPORT
```

## Documentation

- [TASK.md](./TASK.md) — PRD (mandatory properties of the benchmark)
- [ROADMAP.md](./ROADMAP.md) — phased implementation plan
- [docs/ARCHITECTURE.md](./docs/ARCHITECTURE.md) — local/AWS topology and network path
- [docs/POLICIES.md](./docs/POLICIES.md) — 10 policy profiles and parity requirements
- [docs/LOAD-PROFILES.md](./docs/LOAD-PROFILES.md) — 4 load profiles
- [docs/GATEWAYS.md](./docs/GATEWAYS.md) — versions, digests, deviations
- [docs/REPRODUCIBILITY.md](./docs/REPRODUCIBILITY.md) — manifest, seeds, tolerance

## Current Status

The project is in early phases. No benchmark runs yet — we are building the foundation.

- [x] Phase 1 — Skeleton (README, directories, license, lint CI)
- [x] Phase 2 — Synthetic backend (vendored `mccutchen/go-httpbin@v2.22.1`, static Docker image, smoke-tested)
- [x] Phase 3a — Parity foundation (canonical values, reference assets, fixtures, `make parity-check[-all]`)
- [~] Phase 3b — Per-gateway configs (7 gateways × 10 policy profiles)
    - [x] burst runner (p03 / p04 / p05) + `parity-gateway` lifecycle
      (now using `curl --parallel -K` for sustained 1200 rps bursts)
    - [x] `FEATURE-MISSING` short-circuit in `scripts/parity-gateway.sh`
    - [x] `wallarm / p01-vanilla` — 4/4 green against `wallarm/api-gateway:0.2.0`
    - [x] `wallarm / p02-jwt` — **FEATURE-MISSING** on the pinned public
      `0.2.0`, but **6/6 PASS** with
      `WALLARM_IMAGE=wallarm/api-gateway:main-5f1ab30`
    - [x] `wallarm / p03-rl-static` — 2/2 green, `ratelimit` policy with
      `rate=1000/1s`, sliding window
    - [x] `wallarm / p06-req-headers` — 3/3 green, `lua_runner` on
      `request_flow` (`+X-Bench-In`, `-X-Forwarded-For`)
    - [x] `wallarm / p07-resp-headers` — 2/2 green, `lua_runner` on
      `response_flow` (`+X-Bench-Out`, `-Server`)
    - [x] `wallarm / p08-req-body` — 3/3 green, `lua_runner` +
      `cjson.safe` on `request_flow` (`+$.bench.injected`,
      `-$.secret`, Content-Length recomputed)
    - [x] `wallarm / p09-resp-body` — 3/3 green, `lua_runner` +
      `cjson.safe` on `response_flow` (`+$.bench.injected`,
      `-$.origin`, Content-Length recomputed)
    - [x] `wallarm / p04-rl-dynamic-low` — 2/2 green, `ratelimit`
      keyed on `X-Real-IP`, rate=10/s, sliding window
    - [x] `wallarm / p05-rl-dynamic-high` — 3/3 green, same policy
      shape as p04 with rate=100/s
    - [x] `wallarm / p10-full-pipeline` — **FEATURE-MISSING** on the
      pinned public `0.2.0` (cascade from `p02-jwt`), but **4/4 PASS**
      with `WALLARM_IMAGE=wallarm/api-gateway:main-5f1ab30`
    - Wallarm roster on pinned public `0.2.0`: **8 PASS,
      2 FEATURE-MISSING (p02, p10), 0 FAIL**. Under local
      unreleased override
      (`WALLARM_IMAGE=wallarm/api-gateway:main-5f1ab30 make
      parity-gateway-all PARITY_GATEWAY=wallarm`): **10 PASS,
      0 FAIL, 32/32 probes** — the dual-mode `setup.sh` in p02/p10
      runtime-detects `jwt_validation` in `/policies` and binds
      the native policy chain when available.
    - Local Wallarm override roster on `main-5f1ab30`:
      **10 PASS, 0 FAIL, 0 other** via
      `WALLARM_IMAGE=wallarm/api-gateway:main-5f1ab30`
    - [x] `nginx / p01-vanilla` — 4/4 green on `nginx:1.27.3-alpine`
      (catch-all `proxy_pass`, uniform settings fully expressed in
      `nginx.conf`, zero deviations)
    - [x] `nginx / p03-rl-static` — 2/2 green (`limit_req_zone
      $server_name rate=1000r/s` + `burst=200 nodelay` +
      `error_page 429 @retry_after`; 1200-req burst →
      `2xx=262, 429=938, 5xx=0`)
    - [x] `nginx / p04-rl-dynamic-low` — 2/2 green
      (`limit_req_zone $http_x_real_ip rate=10r/s` +
      `burst=10 nodelay`; 10 IPs × 45 req → `2xx=109, 429=341` —
      symmetric to wallarm/p04 within one request)
    - [x] `nginx / p05-rl-dynamic-high` — 3/3 green (same mechanism,
      `zone=10m rate=100r/s` + `burst=20 nodelay`, zone sized for
      the 50 000-IP pool per POLICIES.md; burst #2 →
      `2xx=24, 429=476`)
    - [x] `nginx / p06-req-headers` — 3/3 green on mainline
      (`proxy_set_header X-Bench-In "1";` +
      `proxy_set_header X-Forwarded-For "";` empty-string drop
      idiom; no Lua, no extra module)
    - [x] `nginx / p07-resp-headers` — 2/2 green on
      `openresty/openresty:1.27.1.2-alpine` (first nginx cell
      that overrides the base image — uses bundled
      `ngx_headers_more`'s `more_clear_headers "Server"` because
      mainline has no directive to remove the built-in Server
      response header). Image override declared in
      `gateways/nginx/p07-resp-headers/.env`; `parity-gateway.sh`
      now passes it via `docker compose --env-file` (generic
      per-profile override contract — also carries OpenResty pins
      for p02/p08/p09/p10 cells below).
    - [x] `nginx / p02-jwt` — 6/6 green on OpenResty. ~60-line
      pure-Lua HS256 verifier at
      `gateways/nginx/_shared/lualib/jwt_hs256.lua`, uses bundled
      `resty.sha256` + `cjson.safe` + `bit.bxor` via classic
      RFC 2104 HMAC construction (no `lua-resty-jwt` dependency —
      keeps digest-pin reproducibility intact). **First gateway
      where p02 flips from FEATURE-MISSING (wallarm 0.2.0) to
      PASS.**
    - [x] `nginx / p08-req-body` — 3/3 green on OpenResty.
      `access_by_lua_block` + `ngx.req.set_body_data`
      (auto-patches Content-Length); shared cjson helper at
      `gateways/nginx/_shared/lualib/body_rewrite.lua` injects
      `$.bench.injected`, drops `$.secret`.
    - [x] `nginx / p09-resp-body` — 3/3 green on OpenResty.
      Canonical two-phase Lua pattern:
      `header_filter_by_lua_block` clears Content-Length,
      `body_filter_by_lua_block` buffers chunks and rewrites on
      EOF. Non-JSON responses pass through untouched.
    - [x] `nginx / p10-full-pipeline` — 4/4 green on OpenResty.
      Composes p02+p03+p06+p07+p08+p09 in one request flow. nginx
      phase ordering (`PREACCESS → ACCESS → CONTENT →
      header/body_filter`) encodes the semantics for free; burst
      probe at 1200 rps of valid-JWT GETs observes
      `2xx=0, 429=945, 5xx=0` (rate-limit fires before Lua auth,
      as the fixture expects). **First gateway in the bench with
      a complete green p10** — wallarm's cell is still
      FEATURE-MISSING because `jwt_validation` is absent from the
      0.2.0 public image.
    - **nginx column snapshot**: **10 PASS, 0 FAIL, 32/32 probes**
      across all 10 canonical profiles (`nginx:1.27.3-alpine` for
      mainline, `openresty:1.27.1.2-alpine` for Lua profiles).
      **nginx is the first gateway to close every cell.** Warm
      sweep wall-clock: ~15 s.
    - [~] `envoy` — column opened on
      `envoyproxy/envoy:distroless-v1.32.6` pinned by digest.
      **2 PASS / 0 FAIL / 6 probes** so far (p01 + p03).
      `p01-vanilla` — static bootstrap (listener + HCM + router +
      STRICT_DNS cluster), every uniform setting wired explicitly.
      `p03-rl-static` — `envoy.filters.http.local_ratelimit` at
      HCM level, per-worker `token_bucket` × `--concurrency 2`
      with a **documented rate deviation**: canonical 1000 rps
      lowered to ≈200 rps because envoy on Docker Desktop /
      Apple Silicon saturates at 500–800 rps of HTTP/1.1 accept
      under the 128-parallel burst probe (the filter would never
      engage otherwise). Canonical rate restored in Phase 4 on a
      real Linux host. Config ingestion moved from bind-mount to
      Docker `configs:` to work around VirtioFS cache staleness.
      Remaining 8 profiles planned via native `local_ratelimit`
      with descriptors (p04/p05), `*_headers_to_add/_to_remove`
      (p06/p07) and a Lua filter reusing the same
      `jwt_hs256.lua` / `body_rewrite.lua` the nginx column uses
      (`envoy.filters.http.jwt_authn` only supports asymmetric
      RS/ES/PS — not the canonical HS256 secret).
    - [ ] `kong`, `apisix`, `traefik`, `tyk` (subsequent iterations)
- [ ] Phase 4 — k6 load framework (4 profiles)
- [ ] Phase 5 — Infra (local + AWS 3-EC2)
- [ ] Phase 6 — Go orchestrator
- [ ] Phase 7 — Report generator
- [ ] Phase 8 — Quality gates + docs
- [ ] Phase 9 — Publication / v0.1.0

See [ROADMAP.md](./ROADMAP.md) for details.

## Contact

- Issues / Discussions: this repository
- Security: `security@wallarm.com`
- Wallarm API Gateway: https://github.com/wallarm/wallarm-api-gateway

## License

Apache 2.0 — see [LICENSE](./LICENSE).
