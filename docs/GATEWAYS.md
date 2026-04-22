# Gateways Under Test

Roster, pinned versions, uniform settings, deviations. Kept in sync
with [docs/POLICIES.md](./POLICIES.md) and
[`gateways/_reference/values.yaml`](../gateways/_reference/values.yaml).

## Canonical versions (target)

Digests are resolved by the orchestrator at the start of every run and
written both into the run's [`manifest.json`](./REPRODUCIBILITY.md) and
back into this table whenever a pin is bumped.

| Gateway  | Version       | Docker image                           | Digest        | Language       | Source |
|----------|---------------|----------------------------------------|---------------|----------------|--------|
| wallarm  | `0.2.0`       | `wallarm/api-gateway:0.2.0`            | `sha256:a3d4d2f780e8f1f22b27e2aa450d4a5cfde6d8c51e153a900f63da464393e825` | Rust | https://hub.docker.com/r/wallarm/api-gateway |
| nginx    | `1.27.3-alpine` | `nginx:1.27.3-alpine`                | `sha256:TBD`  | C              | https://hub.docker.com/_/nginx |
| envoy    | `v1.31.5`     | `envoyproxy/envoy:v1.31.5`             | `sha256:TBD`  | C++            | https://hub.docker.com/r/envoyproxy/envoy |
| kong     | `3.8.0`       | `kong:3.8.0`                           | `sha256:TBD`  | Lua / OpenResty | https://hub.docker.com/_/kong |
| apisix   | `3.11.0-debian` | `apache/apisix:3.11.0-debian`         | `sha256:TBD`  | Lua / OpenResty | https://hub.docker.com/r/apache/apisix |
| traefik  | `v3.2.1`      | `traefik:v3.2.1`                       | `sha256:TBD`  | Go             | https://hub.docker.com/_/traefik |
| tyk      | `v5.5.0`      | `tykio/tyk-gateway:v5.5.0`             | `sha256:TBD`  | Go             | https://hub.docker.com/r/tykio/tyk-gateway |

The final list may evolve. Proposed additions (HAProxy, others) are
tracked as GitHub issues on the repository.

## Uniform settings

Per [TASK.md §10](../TASK.md), certain settings must be identical on
every gateway; otherwise the cell-level comparison stops being apples
to apples. The baseline values are:

| Setting                       | Value                                  | Rationale |
|-------------------------------|----------------------------------------|-----------|
| HTTP version (downstream)     | HTTP/1.1 only                          | [TASK §6](../TASK.md), HTTP/2 & /3 forcibly disabled |
| HTTP version (upstream)       | HTTP/1.1 only                          | same |
| Request body buffering        | off (or smallest feasible window)      | [TASK §10](../TASK.md) |
| Response body buffering       | off (or smallest feasible window)      | same |
| Upstream connection pool      | 1024 idle connections, keep-alive ∞    | `BENCH_UPSTREAM_POOL` constant |
| Downstream keep-alive         | on                                     | same |
| Worker concurrency            | 1 worker per CPU core on gateway host  | [TASK §10](../TASK.md) |
| Access logging                | off on the hot path                    | log I/O would bias latency |
| Admin / metrics listeners     | off (separate port, not on the 8080 hot path) | the tested path must not be instrumented |
| Request timeout               | 10 s                                   | only matters for `p04/p05` where we throttle below the rate |
| TLS versions                  | TLSv1.2 + TLSv1.3                      | same cipher suite across gateways (pinned in `_reference/tls/`) |

Any gateway that cannot match a row in this table goes into the
[deviations](#deviations) table below with a pointer to its upstream
documentation.

## HTTP/1.1 enforcement per gateway

Each gateway needs an explicit configuration statement that prevents
HTTP/2 / HTTP/3 from sneaking in over ALPN.

| Gateway | Flag / setting                                              | Notes |
|---------|-------------------------------------------------------------|-------|
| wallarm | Listener `protocol: http` (no `http2`, no `h2c`)            | to be verified during Phase 3 |
| nginx   | `listen … http1;` (no `http2`), remove `http2` from http block | — |
| envoy   | HCM with `codec_type: HTTP1` and no ALPN h2 on listener     | — |
| kong    | `http2_protocol_version = 1.1`, `stream_listen = off`       | — |
| apisix  | `enable_http2: false` at the top of `apisix.yaml`           | — |
| traefik | `entryPoints.http.forwardedHeaders.insecure = false`, disable `h2c`, no `http2` experimental | — |
| tyk     | `http_server_options.force_http1 = true` or equivalent      | — |

These rows are verified in the parity attestation probe "HTTP/1.1 only":
a deliberate `--http2` request must be refused or forcibly downgraded.

## Deviations

Every objective difference that keeps a cell from being a 100 %
apples-to-apples comparison is recorded here. Each entry links the
exact cell (`<gw>, <profile>`), the root cause and the mitigation.

### Template

```markdown
### [gw=<gateway>, p=<profile-id>]

What differs
: One-line technical statement.

Root cause
: Reference to the upstream documentation or issue tracker.

Resolution
: What was done to keep the cell comparable (fixture shape, additional
  plugin, extra config knob, etc.).

Impact on ranking
: `none` | `may inflate latency by X %` | `excluded from ranking`.

Status
: `open` | `mitigated` | `accepted`.
```

### Landed deviations

#### [gw=wallarm, p=p01-vanilla]

What differs
: `base_path: "/"` is rejected by the Admin API with
  `INVALID_BASE_PATH` on `wallarm/api-gateway:0.2.0`, so we register
  one service per path prefix that the fixtures touch instead of a
  single catch-all.

Root cause
: Validation in `wallarm-api-gateway` (`crates/validation/src/base_path.rs`)
  required a non-empty suffix at the 0.2.0 tag; catch-all support
  landed in a later internal build (upstream ticket `NODE-7630`).

Resolution
: `gateways/wallarm/p01-vanilla/setup.sh` registers `bench-anything`,
  `bench-bytes`, `bench-status`, `bench-headers`,
  `bench-response-headers`. Each service's `target.endpoint.url`
  points at the already-prefixed backend URL so that the wallarm
  base-path strip is followed by a same-prefix append — net effect is
  identity forwarding.

Impact on ranking
: none; the user-observable data plane is identical across gateways.

Status
: `accepted` — revisit when a post-0.2.0 public tag ships with
  catch-all.

### Known / expected entries

> Will be confirmed as each per-gateway config lands. The ones below
> are the deviations we already anticipate.

- **Traefik / p02 jwt, p03 rl-static, p04 rl-dyn-low, p05 rl-dyn-high**
  — requires a community plugin. Expect one entry per profile pinned to
  a specific plugin version. Impact: none if the plugin is used by
  everyone the same way; otherwise the cell is marked
  `feature-missing`.

- **Nginx / p02 jwt, p08 req-body, p09 resp-body** — requires
  `lua-nginx-module`. We will use the `openresty:<pinned>` image
  instead of `nginx:<pinned>` for those profiles. The `ngx_http_lua`
  policy code is committed under `gateways/nginx/lua/`.

- **Envoy / p08 req-body, p09 resp-body** — requires a Lua filter.
  Code committed under `gateways/envoy/lua/`.

- **Tyk / p08 req-body, p09 resp-body, p10 full-pipeline** — no native
  body-rewrite primitive without middleware. Cells will be
  `feature-missing`.

## Reproducibility guarantee

1. The orchestrator resolves every image tag to a digest using
   `docker inspect --format='{{index .RepoDigests 0}}'` **before** the
   first cell runs.
2. The digest is written into `manifest.json` and re-verified before
   every cell. A mismatch aborts the run.
3. Both this table and `infra/local/docker-compose.yaml` are updated in
   the same PR whenever a tag is bumped.
4. Running `make parity-check` (Phase 3) re-runs every functional test
   without any load, which makes configuration drift obvious as soon as
   it is committed.

## Status

- Canonical roster: locked (7 gateways).
- Uniform settings: documented (this file).
- HTTP/1.1 enforcement knobs: documented; verified per gateway during
  Phase 3.
- Per-gateway configs:
  - `wallarm / p01-vanilla` — **ready**, parity 4/4 green.
  - `wallarm / p02…p10` — pending (next Phase 3b iteration).
  - `nginx / envoy / kong / apisix / traefik / tyk` — pending.
- Burst parity runner (p03/p04/p05) — **ready**, validated against
  the bare backend (0 × 429 → correct FAIL, the rate-limiting gateway
  rows will turn green as each per-gateway config lands).
- Full status by phase: [ROADMAP.md § Phase 3](../ROADMAP.md#phase-3-parity-framework-3-5-days--core-work).
