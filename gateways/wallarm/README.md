# wallarm

Per-profile configurations for the Wallarm API Gateway (the gateway
that this benchmark primarily measures). Each profile lives in its own
sub-directory with a static config plus a setup script that bootstraps
the Admin API.

## Image

The Wallarm API Gateway is **built from sources** by the runner — this
repository does not ship a default Docker Hub pin. Pass the tag or
digest of your built image via the `WALLARM_IMAGE` environment
variable:

```bash
WALLARM_IMAGE=wallarm/api-gateway:main-<sha> \
    make parity-gateway-all PARITY_GATEWAY=wallarm
```

If `WALLARM_IMAGE` is unset when the compose stack starts, Docker
fails loudly with "`WALLARM_IMAGE must be set`" — this is intentional;
an earlier iteration pinned the public `0.2.0` image as a default, but
that release lacks `jwt_validation` (p02, p11,
`p03-jwks-rs256-basic`) and the full body-rewrite policy surface (p09,
p10) the benchmark exercises, so we dropped the pin in
[`.notes/PROGRESS.md § Iteration 23`](../../.notes/PROGRESS.md).

### Comparing multiple wallarm builds in one sweep

`WALLARM_IMAGE` accepts a comma-separated list — `bench run` expands
each entry into a distinct column named `wallarm@<variant>` so two (or
more) builds run side-by-side through the same matrix:

```bash
WALLARM_IMAGE='wallarm:branch-main,wallarm:branch-other' \
    orchestrator/bin/bench run --gateways wallarm,nginx --matrix canonical
# columns: nginx, wallarm@branch-main, wallarm@branch-other
```

The variant label is derived from the image tag (everything after the
last `:` in the reference). Duplicate labels get a `-2`/`-3` suffix.
A single-value `WALLARM_IMAGE` (no comma) keeps the legacy column name
`wallarm`, so existing pipelines are unaffected.

Variant cells share `gateways/wallarm/docker-compose.yaml` and all the
profile sub-directories below it — only the image swap and column
label differ. Per-cell artefacts land at
`reports/<run-id>/raw/wallarm@<variant>/...`.

| Field        | Value                                                       |
|--------------|-------------------------------------------------------------|
| Language     | Rust                                                        |
| Admin plane  | `:9081` (declarative `POST /services`, `POST /policies`, …) |
| Data plane   | `:9080` (HTTP/1.1 only by the benchmark's uniform-settings) |
| Source       | internal; provided via `WALLARM_IMAGE` at runtime           |

## Layout

```
gateways/wallarm/
├── README.md                  (this file)
├── docker-compose.yaml        (gateway + backend on bench-net)
├── p01-vanilla/
│   ├── gateway.yaml           (static listener + pool)
│   ├── setup.sh               (Admin API bootstrap)
│   └── NOTES.md               (parity compliance, deviations)
├── p02-jwt/
│   ├── gateway.yaml           (same listener + pool as p01)
│   ├── setup.sh               (Admin API: jwt_validation on request_flow)
│   └── NOTES.md               (HS256 shared-secret policy binding)
├── p04-rl-static/
│   ├── gateway.yaml           (listener + pool; copied from p01)
│   ├── setup.sh               (Admin API: ratelimit policy on flow)
│   └── NOTES.md               (deviation: sliding window, not fixed)
├── p05-rl-endpoint/
│   ├── gateway.yaml           (same listener + pool as p01)
│   ├── setup.sh               (Admin API: two routes, ratelimit on `limited` route only)
│   └── NOTES.md               (route-level `POST /flow`; sliding-window deviation inherited from p03)
├── p06-rl-dynamic-low/
│   ├── gateway.yaml           (same listener + pool as p01)
│   ├── setup.sh               (Admin API: ratelimit keyed on X-Real-IP, 10 rps)
│   └── NOTES.md               (sliding window, scope=service, math check)
├── p07-rl-dynamic-high/
│   ├── gateway.yaml           (same listener + pool as p01)
│   ├── setup.sh               (Admin API: ratelimit keyed on X-Real-IP, 100 rps)
│   └── NOTES.md               (same shape as p05, rate=100)
├── p08-req-headers/
│   ├── gateway.yaml           (same listener + pool as p01)
│   ├── setup.sh               (Admin API: lua_runner on request_flow)
│   └── NOTES.md               (base-path strip workaround; qemu gotcha)
├── p09-resp-headers/
│   ├── gateway.yaml           (same listener + pool as p01)
│   ├── setup.sh               (Admin API: lua_runner on response_flow)
│   └── NOTES.md               (`Server`-drop is tautological on go-httpbin)
├── p10-req-body/
│   ├── gateway.yaml           (same listener + pool as p01)
│   ├── setup.sh               (Admin API: lua_runner + cjson on request_flow)
│   └── NOTES.md               (JSON rewrite + Content-Length recompute)
├── p11-resp-body/
│   ├── gateway.yaml           (same listener + pool as p01)
│   ├── setup.sh               (Admin API: lua_runner + cjson on response_flow)
│   └── NOTES.md               (JSON rewrite + Content-Length recompute)
├── p12-full-pipeline/
│   ├── gateway.yaml           (same listener + pool as p01)
│   ├── setup.sh               (compose jwt_validation + ratelimit + lua chain)
│   └── NOTES.md               (full-chain composition)
└── p03-jwks-rs256-basic/          
    ├── gateway.yaml           (same listener + pool as p01/p02)
    ├── setup.sh               (jwt_validation bound to RS256 + inline JWKS)
    └── NOTES.md               (p03 axis: asymmetric + JWKS kid lookup)
```

## Feature matrix

Every cell is expected **PASS** against the from-source build. A
sanity-check step in each JWT / body-rewrite profile's `setup.sh`
inspects the running image's policy registry (`GET /policies`) and
exits with `FEATURE-MISSING` (exit code 42) if the image the runner
passed via `WALLARM_IMAGE` does not expose the required primitive.
This is purely a guardrail against accidentally wiring the harness to
an older image; there is no longer a "dual-verdict" track.

| Profile                 | Primitive                                                                      | Parity     |
|-------------------------|--------------------------------------------------------------------------------|------------|
| `p01-vanilla`           | Catch-all service `/ → backend`                                                | PASS (4/4) |
| `p02-jwt`               | `jwt_validation` policy (HS256 via shared secret) on `request_flow`            | PASS (6/6) |
| `p04-rl-static`         | `ratelimit` policy, key = service, 1000 rps                                    | PASS (2/2) |
| `p05-rl-endpoint`       | `ratelimit` bound on ONE route only via `POST /services/<svc>/routes/<rt>/flow`, 100 rps | PASS (4/4) |
| `p06-rl-dynamic-low`    | `ratelimit` keyed on `X-Real-IP`, 10 rps                                       | PASS (2/2) |
| `p07-rl-dynamic-high`   | `ratelimit` keyed on `X-Real-IP`, 100 rps                                      | PASS (3/3) |
| `p08-req-headers`       | `lua_runner` on `request_flow`                                                 | PASS (3/3) |
| `p09-resp-headers`      | `lua_runner` on `response_flow`                                                | PASS (2/2) |
| `p10-req-body`          | `lua_runner` on `request_flow` (JSON body rewrite)                             | PASS (3/3) |
| `p11-resp-body`         | `lua_runner` on `response_flow` (JSON body rewrite)                            | PASS (3/3) |
| `p12-full-pipeline`     | Composition of p02…p10 in that exact order                                     | PASS (4/4) |
| `p03-jwks-rs256-basic`‡     | `jwt_validation` with `{algorithm:"RS256", jwks:{keys:[...]}}` (inline)        | PASS (3/3) |

‡ **p03-jwks-rs256-basic** — RS256 JWT via JWKS (12-profile matrix)
and therefore NOT included in `parity-gateway-all`. Runs opt-in:
`make parity-gateway PARITY_GATEWAY=wallarm PARITY_PROFILE=p03-jwks-rs256-basic`.
Measures the RS256+JWKS axis (asymmetric signature + kid→JWK lookup)
orthogonal to the HS256 question asked by canonical `p02-jwt`. See
[`p03-jwks-rs256-basic/NOTES.md`](./p03-jwks-rs256-basic/NOTES.md) and
[`../../docs/POLICIES.md § p03-jwks-rs256-basic`](../../docs/POLICIES.md#p03-jwks-rs256-basic).

The full list of canonical values (rate limit, JWT secret, header
names, JSON body paths) lives in
[`../_reference/values.yaml`](../_reference/values.yaml) and
[`docs/POLICIES.md`](../../docs/POLICIES.md). This directory never
hard-codes values that differ from those files; if it ever does, the
parity attestation will surface the drift.

## Uniform settings enforcement

This gateway's declared settings versus the uniform values from
[`docs/GATEWAYS.md`](../../docs/GATEWAYS.md):

| Row                             | Uniform value                 | `wallarm` setting                           |
|---------------------------------|-------------------------------|---------------------------------------------|
| HTTP/1.1 only downstream        | HTTP/1.1 only                 | `net.http_port` (no `http2`, no `h2c`)      |
| Upstream pool size              | 1024                          | `upstream.pool.size: 1024`                  |
| Pool idle timeout               | 60 s                          | `upstream.pool.idle_timeout_ms: 60000`      |
| TCP keep-alive                  | on                            | `upstream.tcp.keepalive_secs: 90`           |
| TCP nodelay                     | on                            | `upstream.tcp.nodelay: true`                |
| Downstream keep-alive           | on                            | default (handled by unigw)                  |
| Access logging on hot path      | off                           | default (no logging config)                 |
| Admin / data plane separation   | yes                           | 9081 (admin) vs 9080 (data)                 |
| Request buffering               | off                           | Rust proxy is streaming; no explicit toggle |
| Response buffering              | off                           | same                                        |

Anything that later deviates goes into the matching profile's `NOTES.md`
and into `docs/GATEWAYS.md § Deviations`.

## Running parity

```bash
# One profile end-to-end (bring up, setup, parity, tear down):
WALLARM_IMAGE=wallarm/api-gateway:main-<sha> \
make parity-gateway \
    PARITY_GATEWAY=wallarm \
    PARITY_PROFILE=p01-vanilla

# All 12 profiles end-to-end:
WALLARM_IMAGE=wallarm/api-gateway:main-<sha> \
make parity-gateway-all \
    PARITY_GATEWAY=wallarm

# All 12 profiles against an already-running wallarm:
make parity-check-all \
    PARITY_GATEWAY=wallarm \
    PARITY_TARGET=http://localhost:9080
```

See [`../../Makefile`](../../Makefile) for the full list of targets and
variables.
