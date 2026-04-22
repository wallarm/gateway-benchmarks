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
| nginx    | `1.27.3-alpine` | `nginx:1.27.3-alpine`                | `sha256:814a8e88df978ade80e584cc5b333144b9372a8e3c98872d07137dbf3b44d0e4` | C              | https://hub.docker.com/_/nginx |
| envoy    | `v1.31.5`     | `envoyproxy/envoy:v1.31.5`             | `sha256:TBD`  | C++            | https://hub.docker.com/r/envoyproxy/envoy |
| kong     | `3.8.0`       | `kong:3.8.0`                           | `sha256:TBD`  | Lua / OpenResty | https://hub.docker.com/_/kong |
| apisix   | `3.11.0-debian` | `apache/apisix:3.11.0-debian`         | `sha256:TBD`  | Lua / OpenResty | https://hub.docker.com/r/apache/apisix |
| traefik  | `v3.2.1`      | `traefik:v3.2.1`                       | `sha256:TBD`  | Go             | https://hub.docker.com/_/traefik |
| tyk      | `v5.5.0`      | `tykio/tyk-gateway:v5.5.0`             | `sha256:TBD`  | Go             | https://hub.docker.com/r/tykio/tyk-gateway |

The final list may evolve. Proposed additions (HAProxy, others) are
tracked as GitHub issues on the repository.

For unreleased local validation, compose stacks may accept an image
override (for Wallarm:
`WALLARM_IMAGE=wallarm/api-gateway:main-5f1ab30`). Those runs are
documented in the profile-level `NOTES.md`, while the canonical pin in
the table above remains the released public image.

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
  and detected at runtime by `gateways/wallarm/p02-jwt/setup.sh`.

Resolution
: Cell is explicitly tagged `FEATURE-MISSING` in the parity report so
  it is visible in the matrix but does not block the sweep. Revisit
  once a public tag ships with `jwt_validation`; the
  `NOTES.md` already contains the exact Admin API payloads we'll use
  once that lands. A local override run against
  `WALLARM_IMAGE=wallarm/api-gateway:main-5f1ab30` is already green
  (`6/6 PASS`).

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

#### [gw=wallarm, p=p04-rl-dynamic-low / p05-rl-dynamic-high]

What differs
: Both dynamic-RL profiles use `ratelimit_key:
  "${request.headers.x-real-ip}"` — a wallarm context expression
  that resolves at request time. Bucketing happens per unique
  expression value inside a service-scoped namespace. Same
  `window_type: sliding` choice as p03 (`fixed` + `window: 1` is a
  no-op on 0.2.0).

Root cause
: Public Admin API shape: `scope` namespaces buckets but does not
  dictate the partition key — the key partition is always the
  resolved value of `ratelimit_key`. Matches the upstream
  accuracy-test harness
  ([`single_node_ratelimit_accuracy_test.sh`](../wallarm-api-gateway/tests/integration/single_node_ratelimit_accuracy_test.sh))
  exactly.

Resolution
: `setup.sh` on both profiles binds a single `ratelimit` policy on
  the service's `request_flow`. The math works out to the
  request: for p04 with 10 IPs × 45 req/s-sliding-window,
  `10 × 2xx + 35 × 429` per IP → cross-IP `100 × 2xx, 350 × 429`
  (observed `99 × 2xx, 351 × 429`). For p05 saturating a single
  IP with 500 reqs → `100 × 2xx, 400 × 429` exact.

Impact on ranking
: `none` — every gateway in the matrix implements dynamic RL with
  an IP-keyed bucket; wallarm's context expression is the same
  primitive as envoy's `local_ratelimit` descriptors, kong's
  `rate-limiting` plugin with `limit_by=header`, nginx's
  `limit_req_zone` keyed on `$http_x_real_ip`, etc.

Status
: `accepted` — mirrored in `gateways/wallarm/p04-rl-dynamic-low/NOTES.md`
  and `gateways/wallarm/p05-rl-dynamic-high/NOTES.md`.

#### [harness, p=burst-runner-ignores-duration_s]

What differs
: Rate-limit fixtures (`p03`, `p04`, `p05`) carry a `duration_s`
  field, but
  [`scripts/parity-attestation.sh::run_burst_probe`](../scripts/parity-attestation.sh)
  fires every request as fast as `curl --parallel` can open
  connections — it does **not** pace them across `duration_s`.

Root cause
: The parity harness is deliberately cheap: no `hey`, no `ab`, no
  `vegeta`. The `duration_s` field is preserved in the fixture
  for Phase-4 load profiles (k6 with paced arrivals), where it
  actually matters.

Resolution
: None needed — the per-window invariant ("≤ R × 2xx per IP per
  window") is *stricter* under an ASAP burst than under a paced
  trickle. A gateway that cannot limit under ASAP bursts would
  fail the parity check, even though it might pass under paced
  load. The same runner now also forwards static `.burst.headers`
  (for example `Authorization: Bearer ${JWT_VALID}` in `p10`) while
  keeping the same ASAP scheduling model.

Impact on ranking
: `none` — parity certifies correctness, not RPS. Phase 4 k6 load
  profiles produce the actual throughput numbers using paced
  arrivals.

Status
: `accepted` — documented here and in each RL profile's NOTES.md.

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
: `none` for the add side. The drop side was originally intended to
  be verified transitively via `p10-full-pipeline`, but since `p10`
  is itself FEATURE-MISSING on this image (cascade from `p02-jwt`),
  the drop-side check stays structural on wallarm until a public tag
  ships with either a `preserve_path` knob or `jwt_validation`.
  Every other gateway in this bench routes `/response-headers`
  straight to `go-httpbin` and exercises the drop for real.

Status
: `accepted` — mirrored in `gateways/wallarm/p07-resp-headers/NOTES.md`.

#### [gw=wallarm, p=p08-req-body]

What differs
: Wallarm 0.2.0 does not expose a dedicated `body_transform` policy.
  JSON request-body rewrite is performed via `lua_runner` +
  `cjson.safe`, which is the built-in Lua sandbox documented in the
  Wallarm policy guide. The policy reads `ctx.request.body`, decodes,
  mutates (`$.bench.injected = true`, `$.secret = nil`), re-encodes
  and writes back, and explicitly recomputes `Content-Length`.

Root cause
: No first-class `body_transform` primitive in 0.2.0. The Lua sandbox
  is the only available vehicle until a dedicated policy ships in a
  later release.

Resolution
: `lua_runner` on `request_flow`. `Transfer-Encoding` is not
  manipulated because wallarm does not expose chunked framing to Lua
  and buffered mode has already materialised the body.

Impact on ranking
: The benchmark measures a Lua-based rewrite path for wallarm on
  p08/p09; other gateways (envoy Lua filter, openresty ngx_http_lua,
  apisix serverless Lua) will do the same. A gateway that ships a
  native body-transform policy will show it against the same
  fixture and the manifest will mark the mechanism explicitly.

Status
: `accepted` — mirrored in `gateways/wallarm/p08-req-body/NOTES.md`.

#### [gw=wallarm, p=p09-resp-body]

What differs
: Same `lua_runner` + `cjson.safe` idiom as p08, but on
  `response_flow`. Content-Length is explicitly recomputed
  (`ctx.response.headers["content-length"] = tostring(#body)`),
  otherwise wallarm forwards the rewritten body with the stale
  upstream header and clients either see a truncated payload or hang
  on keep-alive.

Root cause
: No first-class `body_transform` primitive in 0.2.0.

Resolution
: `lua_runner` on `response_flow`, robust to non-JSON upstream
  bodies (they pass through unmodified).

Impact on ranking
: `none` — the same Lua path is exercised on every wallarm profile
  that touches bodies, so the numbers are comparable across p08, p09
  and p10.

Status
: `accepted` — mirrored in `gateways/wallarm/p09-resp-body/NOTES.md`.

#### [gw=wallarm, p=p10-full-pipeline]

What differs
: `p10` is defined by
  [`docs/POLICIES.md § p10`](./POLICIES.md#p10--full-pipeline) as the
  composition `p02 → p03 → p06 → p08 → p07 → p09`. The matching
  fixture ([`fixtures/p10-full-pipeline.jsonl`](../fixtures/p10-full-pipeline.jsonl))
  has two probes that expect `status=401` on missing / expired JWT
  and two probes that depend on a valid JWT reaching the rate-limit
  stage. Without a gateway-side JWT validator those probes return
  `200` and the cell fails.

Root cause
: Cascade from
  [`[gw=wallarm, p=p02-jwt]`](#gwwallarm-pp02-jwt) above — the
  pinned public image does not ship `jwt_validation`.

Resolution
: On the pinned public `0.2.0` image the profile is still
  `FEATURE-MISSING`, but now via runtime detection inside
  `gateways/wallarm/p10-full-pipeline/setup.sh` rather than a static
  marker file. The other five building blocks (`p03`, `p06`, `p07`,
  `p08`, `p09`) pass independently on that image, proving the
  orchestration path works end-to-end. A local override run against
  `WALLARM_IMAGE=wallarm/api-gateway:main-5f1ab30` is already green
  (`4/4 PASS`) with the same canonical flow ordering.

Impact on ranking
: `excluded from ranking` for this cell. No spillover: every other
  wallarm cell is green.

Status
: `feature-missing` — revisit on the next public wallarm release.

#### [harness, p=go-httpbin-echo-shape]

What differs
: Fixtures express intent ("arg `q` equals `hello`", "header
  `X-Foo` equals `1`"), but `go-httpbin` echoes both query args and
  request headers as arrays-of-strings (`"q": ["hello"]`,
  `"X-Foo": ["1"]`) to preserve multi-value semantics. Other echo
  backends may emit the scalar form.

Root cause
: `go-httpbin`'s echo schema, not any gateway.

Resolution
: `scripts/parity-attestation.sh` exposes
  `assert_json_contains_value` (for `response_body_json_contains`)
  and `assert_json_has_string` (for `backend_saw_header`) — both
  accept scalar and array-of-one representations. Fixtures stay
  backend-agnostic.

Impact on ranking
: `none` — the assertion is purely structural.

Status
: `accepted` — lives in `scripts/parity-attestation.sh` and is
  exercised on every gateway that routes to the shared go-httpbin
  backend.

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
  image (see deviation above), but **ready** on local override
  `main-5f1ab30` (`6/6 PASS`).
  - `wallarm / p03-rl-static` — **ready**, parity 2/2 green
    (1200 rps burst, `window_type: sliding`).
  - `wallarm / p04-rl-dynamic-low` — **ready**, parity 2/2 green
    (10 rps/IP, 10 IPs × 45 reqs ASAP → `2xx=99, 429=351`;
    theoretical `100/350`, one-request drift).
  - `wallarm / p05-rl-dynamic-high` — **ready**, parity 3/3 green
    (100 rps/IP; probe 2 `2xx=200/0` exact; probe 3 single IP
    saturation `2xx=100, 429=400` exact).
  - `wallarm / p06-req-headers` — **ready**, parity 3/3 green
    (`lua_runner` on `request_flow`, base-path-strip backend trick).
  - `wallarm / p07-resp-headers` — **ready**, parity 2/2 green
    (`lua_runner` on `response_flow`; `Server`-drop side is
    structural — see deviation below).
  - `wallarm / p08-req-body` — **ready**, parity 3/3 green
    (`lua_runner` + `cjson.safe` on `request_flow`,
    Content-Length recomputed).
  - `wallarm / p09-resp-body` — **ready**, parity 3/3 green
    (`lua_runner` + `cjson.safe` on `response_flow`,
    Content-Length recomputed).
  - `wallarm / p10-full-pipeline` — **FEATURE-MISSING** (cascade from
  `p02-jwt`) on pinned `0.2.0`, but **ready** on local override
  `main-5f1ab30` (`4/4 PASS`).
  - Wallarm roster on pinned public `0.2.0`: **8 PASS,
    2 FEATURE-MISSING (p02, p10), 0 FAIL**. On local unreleased
    override `wallarm/api-gateway:main-5f1ab30` (source-built
    image with the `jwt_validation` policy now present in the
    registry): **10 PASS, 0 FAIL, 32/32 probes**. The dual-mode
    `setup.sh` in `gateways/wallarm/p02-jwt/` + `p10-full-pipeline/`
    keys off `GET /policies` at runtime, so the same fixture set
    exercises both image flavours without any harness flags.
- Local Wallarm override roster on `main-5f1ab30`: **10 PASS, 0 FAIL,
  0 other**.
  - `nginx / p01-vanilla` — **ready**, parity 4/4 green on
    `nginx:1.27.3-alpine` (catch-all `proxy_pass` with uniform
    settings; zero deviations).
  - `nginx / p03-rl-static` — **ready**, parity 2/2 green
    (`limit_req_zone $server_name rate=1000r/s` + `burst=200 nodelay`
    + `error_page 429 @retry_after`; observed
    `2xx=262, 429=938, 5xx=0` under a 1200-req 1-second burst).
  - `nginx / p04-rl-dynamic-low` — **ready**, parity 2/2 green
    (`limit_req_zone $http_x_real_ip zone=bench_p04:1m rate=10r/s` +
    `burst=10 nodelay`; observed `2xx=109, 429=341, 5xx=0` under the
    10-IP / 450-req / 3-second fixture — symmetric to wallarm
    `99/351` within one request).
  - `nginx / p05-rl-dynamic-high` — **ready**, parity 3/3 green.
    Same mechanism as p04 with `zone=10m rate=100r/s` + `burst=20`.
    Zone size follows from POLICIES.md's 50 000-IP pool:
    50 000 keys × ~128 B ≈ 6.4 MB, rounded up to 10 MB for LRU
    slack. Observed shapes: burst #1 (10 IPs × 20 rps) = `200/0`,
    burst #2 (1 IP × 500 rps) = `2xx=24, 429=476`. See the `✓†`
    footnote in
    [`docs/POLICIES.md § Feature availability`](./POLICIES.md#feature-availability-as-of-current-images).
  - `nginx / p06-req-headers` — **ready**, parity 3/3 green on
    mainline. Pure `proxy_set_header` — inject via literal value,
    drop via empty-string idiom (`proxy_set_header X-Forwarded-For
    "";` omits the header from the upstream request rather than
    forwarding an empty value). No Lua, no extra module.
  - `nginx / p07-resp-headers` — **ready**, parity 2/2 green on
    **OpenResty** (`openresty/openresty:1.27.1.2-alpine@sha256:761047d6…`).
    The first nginx cell that overrides the base image — mainline
    has no directive that removes the nginx-generated `Server`
    response header. `ngx_headers_more`'s `more_clear_headers
    "Server";` does, and OpenResty bundles that module. The
    override is declared in `gateways/nginx/p07-resp-headers/.env`,
    which `scripts/parity-gateway.sh` passes to `docker compose`
    via `--env-file` so the image pin is strictly scoped to that
    profile's invocation (generic per-profile-env mechanism now
    reused by every Lua cell).
  - `nginx / p02-jwt` — **ready**, parity 6/6 green on OpenResty.
    The bench-specific HS256 verifier lives at
    `gateways/nginx/_shared/lualib/jwt_hs256.lua` — ~60 lines of
    pure Lua, using only primitives bundled with stock OpenResty
    (`resty.sha256`, `cjson.safe`, `bit.bxor`, `ngx.encode_base64`).
    HMAC-SHA-256 is built by hand via the classic RFC 2104
    construction (`K' = sha256(K) if |K|>64 else K; ipad/opad ⊕;
    sha256(opad||sha256(ipad||m))`), plus a constant-time byte
    compare and an `exp >= now` window check. Deliberately no
    dependency on `lua-resty-jwt` — pulling in a custom Dockerfile
    or `opm install` step would defeat the digest-pin reproducibility
    story. First nginx cell to turn a wallarm `FEATURE-MISSING`
    into a PASS.
  - `nginx / p08-req-body` — **ready**, parity 3/3 green on
    OpenResty. `access_by_lua_block` reads the full client body
    (`ngx.req.read_body` + `ngx.req.get_body_data`), runs it
    through `body_rewrite.rewrite_request` (shared cjson helper —
    injects `$.bench.injected`, drops `$.secret`), and hands the
    rewritten JSON back via `ngx.req.set_body_data`. That single
    call **auto-patches Content-Length** on the upstream-bound
    request, which is why the fixture's "Content-Length is
    correct after rewrite" probe passes without any header
    ceremony. Empty / non-JSON bodies are coerced to `{}` so the
    inject invariant always holds. Same transform semantics as
    `wallarm / p08-req-body` — both lean on cjson.safe inside a
    Lua sandbox.
  - `nginx / p09-resp-body` — **ready**, parity 3/3 green on
    OpenResty. Canonical two-phase Lua pattern:
    `header_filter_by_lua_block` clears `Content-Length` (so nginx
    emits `Transfer-Encoding: chunked` for the modified body) and
    `body_filter_by_lua_block` collects chunks into
    `ngx.ctx.bench_buf` until `ngx.arg[2]` (EOF) fires, then
    concatenates and rewrites through
    `body_rewrite.rewrite_response_if_json` (injects
    `$.bench.injected`, drops `$.origin`). Non-JSON upstream
    bodies pass through untouched — identical behaviour to
    `wallarm / p09-resp-body`.
  - `nginx / p10-full-pipeline` — **ready**, parity 4/4 green on
    OpenResty. Composes p02+p03+p06+p07+p08+p09 in a single
    request flow, relying on nginx phase ordering
    (`PREACCESS → ACCESS → CONTENT → header_filter → body_filter`)
    to encode "rate-limit first, then JWT, then req-body rewrite,
    then upstream, then resp-hdr + resp-body rewrite" semantics
    without any explicit sequencing. Observed burst shape under
    1200 rps of valid-JWT GETs: `2xx=0, 429=945, 5xx=0, other=255`
    — the 945×429 confirms rate-limit fires **before** Lua auth
    (the expected order, matching the fixture's tolerance of
    `status_429_min=150 ± 50`). First gateway in the bench with a
    complete green `p10`: wallarm's cell is still
    `FEATURE-MISSING` because `wallarm/api-gateway:0.2.0` lacks a
    `jwt_validation` policy, cascading the gap into p10.
  - nginx roster on `1.27.3-alpine` + `openresty:1.27.1.2-alpine`:
    **10 PASS, 0 FAIL, 32/32 probes** across all 10 canonical
    profiles.
  - `envoy / kong / apisix / traefik / tyk` — pending.
- Burst parity runner (p03/p04/p05) — **ready**, now uses
  `curl --parallel --parallel-max N -K <config>` so a 1200-rps burst
  actually fits inside its 1 s window. Validated end-to-end against
  `wallarm / p03-rl-static` → `2xx=998, 429=202, 5xx=0`.
- Full status by phase: [ROADMAP.md § Phase 3](../ROADMAP.md#phase-3-parity-framework-3-5-days--core-work).
