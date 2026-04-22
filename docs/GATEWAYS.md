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

#### [gw=wallarm, p=p02-jwt]

What differs
: `wallarm/api-gateway:0.2.0` (public Docker Hub image) does not ship
  a `jwt_validation` policy. The source tree has one
  (`wallarm-api-gateway/tests/integration/jwt_validation_test.sh`), but
  the pinned public tag does not. The `lua_runner` sandbox in 0.2.0 also
  lacks crypto primitives (no `openssl.hmac`, no `digest`), so a pure
  Lua HS256 check is impractical and would itself become a deviation.

Root cause
: Policy gap in the public 0.2.0 image. Tracked as
  [`gateways/wallarm/p02-jwt/NOTES.md`](../gateways/wallarm/p02-jwt/NOTES.md)
  and marked with a `FEATURE-MISSING` file that
  `scripts/parity-gateway.sh` short-circuits on.

Resolution
: Cell is explicitly tagged `FEATURE-MISSING` in the parity report so
  it is visible in the matrix but does not block the sweep. Revisit
  once a public tag ships with `jwt_validation`; the
  `NOTES.md` already contains the exact Admin API payloads we'll use
  once that lands.

Impact on ranking
: `excluded from ranking` for this cell only. Other wallarm cells are
  unaffected.

Status
: `feature-missing` — revisit on the next public wallarm release.

#### [gw=wallarm, p=p03-rl-static]

What differs
: `docs/POLICIES.md` specifies a *rolling* 1 s window. In the public
  0.2.0 Admin API, the `ratelimit` policy exposes a `window_type` flag
  with values `fixed` and `sliding`. Empirically, `window_type: fixed`
  with `window: 1` does not rate-limit (the upstream integration suite
  only exercises `window: 60`). `window_type: sliding` matches the
  "rolling" semantics from POLICIES.md and is what the setup script
  ships.

Root cause
: Implementation detail of the `fixed` bucket at
  `window: 1` in 0.2.0. See
  [`wallarm-api-gateway/tests/integration/single_node_ratelimit_accuracy_test.sh`](../wallarm-api-gateway/tests/integration/single_node_ratelimit_accuracy_test.sh)
  — no test covers `window: 1` at all.

Resolution
: `gateways/wallarm/p03-rl-static/setup.sh` picks
  `window_type: "sliding"`, which is documented, stable, and in line
  with POLICIES.md's rolling window. Result: parity passes with
  `burst 1200x/1s → 2xx=998, 429=202`.

Impact on ranking
: `none` — every gateway is required by
  [`docs/POLICIES.md`](./POLICIES.md) to implement a rolling window.
  Any competitor gateway that only supports a fixed window is its own
  deviation, not wallarm's.

Status
: `mitigated` — cell is green; document the window-type choice in the
  NOTES.md so reviewers can see the trade-off at a glance.

#### [gw=wallarm, p=p06-req-headers]

What differs
: wallarm 0.2.0's base-path strip **always** leaves a trailing `/`
  between the stripped `base_path` and the `target.endpoint.url`
  (e.g. client `GET /headers` → upstream `/headers/`), and
  `go-httpbin`'s `/headers`, `/response-headers`, `/get` endpoints
  all 404 on the trailing-slash variant.

Root cause
: Path-compose behaviour of the 0.2.0 proxy. Empirically verified on
  `wallarm/api-gateway:0.2.0` against a canonical p01-vanilla service
  (`GET /anything` → upstream sees `/anything/`; `GET /anything/foo`
  → upstream sees `/anything/foo`).

Resolution
: Point the service at `go-httpbin`'s permissive `/anything/<slug>`
  catch-all instead of the target endpoint directly:
  `target.endpoint.url: http://backend:8080/anything/headers`. The
  echo shape is identical (`.headers."X-Foo": ["v"]`), so the same
  gateway-agnostic fixture keeps working. The
  `scripts/parity-attestation.sh::assert_json_has_string` helper was
  added to accept both string and array-of-strings echoes so that the
  fixture stays portable.

Impact on ranking
: `none` — observable behaviour at the client is identical (policy
  fires, headers are rewritten, status is 200).

Status
: `accepted` — revisit if a later public tag exposes a
  `preserve_path` / `strip_path=false` knob.

#### [gw=wallarm, p=p07-resp-headers]

What differs
: Same base-path-strip workaround as p06, so this profile routes
  `/response-headers` → `backend:8080/anything/response-headers` and
  `/get` → `backend:8080/anything/get`. `go-httpbin`'s
  `/anything/*` catch-all does **not** emit a `Server:` header on
  responses; only the first-class `/response-headers` endpoint does,
  and we can't reach that one through wallarm 0.2.0 without hitting
  the trailing-slash 404.

Root cause
: Same 0.2.0 path-compose behaviour + go-httpbin's `Server` header
  being endpoint-specific.

Resolution
: The **add** side (`X-Bench-Out: 1`) is verified end-to-end. The
  **drop** side (`Server:`) is still bound in the `response_flow`
  Lua, but the upstream never sets `Server:` on this particular
  endpoint, so the fixture's `response_header_absent: ["Server"]`
  probe is structural on wallarm. Every other gateway in this bench
  routes `/response-headers` straight to `go-httpbin` and will
  exercise the drop for real.

Impact on ranking
: `none` for the add side. The drop side is verified transitively
  via `p10-full-pipeline`, which chains p07 with body-write policies
  that do surface an upstream `Server` header through `go-httpbin`.

Status
: `accepted` — mirrored in `gateways/wallarm/p07-resp-headers/NOTES.md`.

#### [platform, p=qemu-amd64-on-arm64]

What differs
: `docker pull --platform linux/amd64 wallarm/api-gateway:0.2.0`
  lands an amd64 image on Apple Silicon that Docker Desktop runs
  under qemu. Activating **any** `lua_runner` policy in that
  configuration aborts with
  `qemu: uncaught target signal 11 (Segmentation fault) - core dumped`.
  p06, p07 (and future p08..p10) therefore crash the gateway on the
  first smoke request.

Root cause
: qemu's x86-on-arm JIT dies on LuaJIT-style tracing. Not a wallarm
  bug: the image ships a native `linux/arm64` variant in the same
  multi-arch manifest index (digest
  `sha256:0857114a…`) and Lua policies work correctly on it.

Resolution
: Do **not** force `--platform linux/amd64` on Apple Silicon. The
  docker-compose image pin (`wallarm/api-gateway:0.2.0@sha256:a3d4d2f7…`)
  is a multi-arch **index**, so a plain `docker pull
  wallarm/api-gateway:0.2.0` (no `--platform`) resolves to the
  native arm64 variant locally and to amd64 on Linux CI.

Impact on ranking
: `none` — every benchmark run pins the arch used (x86_64 on Linux
  EC2 for "for-real" numbers, the native arch for smoke on laptops),
  and the `manifest.json` records the resolved digest along with
  `GOOS/GOARCH` of the benchmark host.

Status
: `accepted` — documented in
  `gateways/wallarm/p06-req-headers/NOTES.md § Gotcha`.

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
  - `wallarm / p02-jwt` — **FEATURE-MISSING** on the pinned 0.2.0
    image (see deviation above).
  - `wallarm / p03-rl-static` — **ready**, parity 2/2 green
    (1200 rps burst, `window_type: sliding`).
  - `wallarm / p06-req-headers` — **ready**, parity 3/3 green
    (`lua_runner` on `request_flow`, base-path-strip backend trick).
  - `wallarm / p07-resp-headers` — **ready**, parity 2/2 green
    (`lua_runner` on `response_flow`; `Server`-drop side is
    structural — see deviation below).
  - `wallarm / p04 / p05 / p08 / p09 / p10` — pending (next Phase 3b
    iterations).
  - `nginx / envoy / kong / apisix / traefik / tyk` — pending.
- Burst parity runner (p03/p04/p05) — **ready**, now uses
  `curl --parallel --parallel-max N -K <config>` so a 1200-rps burst
  actually fits inside its 1 s window. Validated end-to-end against
  `wallarm / p03-rl-static` → `2xx=998, 429=202, 5xx=0`.
- Full status by phase: [ROADMAP.md § Phase 3](../ROADMAP.md#phase-3-parity-framework-3-5-days--core-work).
