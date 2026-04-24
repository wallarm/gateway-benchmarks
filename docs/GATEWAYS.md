# Gateways Under Test

Roster, pinned versions, uniform settings, deviations. Kept in sync
with [docs/POLICIES.md](./POLICIES.md) and
[`gateways/_reference/values.yaml`](../gateways/_reference/values.yaml).

## Canonical versions (target)

Digests are resolved by the orchestrator at the start of every run and
written both into the run's [`manifest.json`](./REPRODUCIBILITY.md) and
back into this table whenever a pin is bumped.

| Gateway  | Version         | Docker image                           | Digest        | Language       | Source |
|----------|-----------------|----------------------------------------|---------------|----------------|--------|
| wallarm  | from-sources    | `${WALLARM_IMAGE:?required}`           | set by runner | Rust           | internal build — tag passed via `WALLARM_IMAGE` |
| nginx    | `1.27.3-alpine` | `nginx:1.27.3-alpine`                  | `sha256:814a8e88df978ade80e584cc5b333144b9372a8e3c98872d07137dbf3b44d0e4` | C              | https://hub.docker.com/_/nginx |
| envoy    | `v1.31.5`       | `envoyproxy/envoy:v1.31.5`             | `sha256:TBD`  | C++            | https://hub.docker.com/r/envoyproxy/envoy |
| kong     | `3.9.1`         | `kong/kong:3.9.1`                      | `sha256:6addf50e6bd8d578314cb9ce4f2d2d1e3781d2edecef59f707e00c6e05d384f5` | Lua / OpenResty | https://hub.docker.com/r/kong/kong |
| apisix   | `3.15.0-debian` | `apache/apisix:3.15.0-debian`          | `sha256:4c201af4f6887def17c22be19e38f64cedf507db8bcc43991089778ad1188b9c` | Lua / OpenResty | https://hub.docker.com/r/apache/apisix |
| traefik  | `v3.3.4`        | `traefik:v3.3.4`                       | `sha256:TBD`  | Go             | https://hub.docker.com/_/traefik |
| tyk      | `v5.11.1`       | `tykio/tyk-gateway:v5.11.1`            | `sha256:225624f56be59a54614ff8ba88255fec1c430037a4f7232fc141d2615bdff598` | Go | https://hub.docker.com/r/tykio/tyk-gateway |

The final list may evolve. Proposed additions (HAProxy, others) are
tracked as GitHub issues on the repository.

Wallarm is deliberately shipped from sources: we removed the previous
public the current build pin in
[.notes/PROGRESS.md § Iteration 23](../.notes/PROGRESS.md) because that
release lacked `jwt_validation` and the body-rewrite policy surface
the benchmark exercises, which forced two profiles into
`FEATURE-MISSING`. Runners provide the built image's tag/digest via
`WALLARM_IMAGE` at invocation time; the corresponding digest is
captured in each run's `manifest.json` for reproducibility. Every
other gateway keeps a public image pin in this table.

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
| Request timeout               | 10 s                                   | only matters for `p06/p07` where we throttle below the rate |
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

> **Profile numbering note.** The canonical numbering is
> `p01-vanilla`, `p02-jwt`, `p03-jwks-rs256-basic` (supplemental,
> off-grid), then ranking profiles `p04-rl-static` … `p12-full-pipeline`.
> See [`docs/POLICIES.md`](./POLICIES.md) for the full roster. Section
> headers and the rollup table below use this numbering. Pre-Phase-3b
> historical narratives (in "Iteration N" subsections at the bottom of
> this file) may still use the older `p03..p11` ranking numbering that
> predates the `p03-jwks-rs256-basic` insertion; treat those as
> chronological log entries.

### Summary table

One-row-per-cell rollup (Phase 8 §
[`docs/REPRODUCIBILITY.md`](./REPRODUCIBILITY.md)). The detailed
entries live below — jump straight there via the `↓ details` link
on each row. `Ranking impact` obeys the tolerance table in
REPRODUCIBILITY.md §Tolerances; `status` matches the per-entry
footer.

| Gateway  | Cell(s)                               | Category     | Ranking impact | Status    | Mitigation (summary) |
|----------|---------------------------------------|--------------|----------------|-----------|----------------------|
| wallarm  | `p01-vanilla`                         | gw-config    | none           | accepted  | Register one service per path prefix (`base_path: "/"` rejected by Admin API). [↓ details](#gwwallarm-pp01-vanilla) |
| wallarm  | `p02-jwt`                             | (historical) | none           | retired   | Retired once `WALLARM_IMAGE` went source-built; `/policies` sanity guard preserved. [↓ details](#gwwallarm-pp02-jwt-historical-no-longer-active) |
| wallarm  | `p04-rl-static`                       | gw-primitive | none           | mitigated | `window_type: sliding` (`fixed+window=1` is a no-op on the public build). [↓ details](#gwwallarm-pp04-rl-static) |
| wallarm  | `p06-rl-dynamic-low`, `p07-rl-dynamic-high` | gw-primitive | none    | accepted  | Same `window_type: sliding`; `ratelimit_key: ${request.headers.x-real-ip}`. [↓ details](#gwwallarm-pp06-rl-dynamic-low--p07-rl-dynamic-high) |
| harness  | every RL burst probe                  | harness      | none           | accepted  | `run_burst_probe` fires ASAP instead of pacing across `duration_s` — a *stricter* invariant. [↓ details](#harness-pburst-runner-ignores-duration_s) |
| wallarm  | `p08-req-headers`                     | gw-routing   | none           | accepted  | Upstream re-pointed at `/anything/headers` to dodge trailing-slash 404. [↓ details](#gwwallarm-pp08-req-headers) |
| wallarm  | `p09-resp-headers`                    | gw-routing   | none on add-side; drop-side structural | accepted | add-side verified; drop-side (`Server:` strip) structural on wallarm until `preserve_path` lands. [↓ details](#gwwallarm-pp09-resp-headers) |
| wallarm  | `p10-req-body`                        | gw-primitive | none           | accepted  | `lua_runner` (no first-class `body_transform` policy in the current build). [↓ details](#gwwallarm-pp10-req-body) |
| wallarm  | `p11-resp-body`                       | (see §p11-resp-body) | none           | accepted  | Same `lua_runner` + chunked fallback as p10. [↓ details](#gwwallarm-pp11-resp-body) |
| wallarm  | `p12-full-pipeline`                   | (historical) | none           | retired   | Same retirement as wallarm/p02. [↓ details](#gwwallarm-pp12-full-pipeline-historical-no-longer-active) |
| envoy    | `p04-rl-static`                       | gw-primitive | none           | no deviation | Canonical 1000 rps rolling; historical `max_connection_duration: 0s` trap documented only. [↓ details](#gwenvoy-pp04-rl-static) |
| envoy    | `p06-rl-dynamic-low`, `p07-rl-dynamic-high` | gw-primitive | none on parity; cardinality mitigated | mitigated | Enumerated `descriptors[]` (v1.33 wildcard landed post-pin); bump to v1.33+ tracked. [↓ details](#gwenvoy-pp06-rl-dynamic-low--p07-rl-dynamic-high-infraenumerated-descriptors) |
| envoy    | `*`                                   | infra        | none           | accepted  | Docker Desktop VirtioFS inode swap gotcha (macOS only). [↓ details](#gwenvoy-p-infradocker-desktop-virtiofs-cache) |
| traefik  | `p06-rl-dynamic-low`, `p07-rl-dynamic-high` | gw-config    | none     | accepted  | `forwardedHeaders.insecure: true` inside YAML (CLI flag silently ignored). [↓ details](#gwtraefik-pp06-rl-dynamic-low--p07-rl-dynamic-high-infraforwardedheaders-insecure) |
| traefik  | `p10-req-body`, `p11-resp-body`, `p12-full-pipeline` | plugin       | none | accepted  | Yaegi literal coercion helper in `body_rewrite`. [↓ details](#gwtraefik-pp10-req-body--p11-resp-body--p12-full-pipeline-infrayaegi-json-literal-coercion) |
| traefik  | `p02-jwt`, `p12-full-pipeline`        | plugin       | none           | accepted  | `RawMessage` per-claim decoding (Yaegi skips method dispatch on custom JSON types). [↓ details](#gwtraefik-pp02-jwt--p12-full-pipeline-infrayaegi-json-no-method-dispatch) |
| apisix   | `p08-req-headers`, `p12-full-pipeline` | infra-patch | none           | accepted  | Entrypoint `sed` rerouting XFF through a writable `$bench_xff` variable. [↓ details](#gwapisix-pp08-req-headers--p12-full-pipeline-infranginx-conf-xff-patch) |
| apisix   | `p09-resp-headers`, `p12-full-pipeline` | gw-config    | none          | accepted  | `serverless-post-function` header_filter for `p09`; baseline `server_tokens: false` for `p12`. [↓ details](#gwapisix-pp09-resp-headers--p12-full-pipeline-infrangx-header-server-nil) |
| kong     | `p08-req-headers`, `p12-full-pipeline` | infra-patch | none           | accepted  | Entrypoint `sed` on kong's nginx template; `$bench_xff` rewrite + one-line Lua shim. [↓ details](#gwkong-pp08-req-headers--p12-full-pipeline-infranginx-template-xff-patch) |
| kong     | `p10-req-body`, `p11-resp-body`, `p12-full-pipeline` | sandbox      | none     | accepted  | `KONG_UNTRUSTED_LUA_SANDBOX_REQUIRES=body_rewrite` (single 80-line shared module). [↓ details](#gwkong-pp10-req-body--p11-resp-body--p12-full-pipeline-infrauntrusted-lua-sandbox-whitelist) |
| kong     | `p11-resp-body`, `p12-full-pipeline`  | gw-config    | none           | accepted  | `header_filter` chunk clears upstream `Content-Length`; chunked fallback. [↓ details](#gwkong-pp11-resp-body--p12-full-pipeline-infrapost-function-content-length-drop) |
| harness  | `go-httpbin-echo-shape`               | harness      | none           | accepted  | `assert_json_*` helpers accept both scalar and array-of-one. [↓ details](#harness-pgo-httpbin-echo-shape) |
| platform | every cell on Apple Silicon           | platform     | none           | accepted  | Never `--platform linux/amd64` wallarm on arm64 (qemu Lua segfault). [↓ details](#platform-pqemu-amd64-on-arm64) |

Categories explained:

- **gw-config** — deviation is a knob exposed by the gateway's own
  config surface (YAML / Admin API / env var).
- **gw-primitive** — the gateway's native primitive differs in shape
  from `docs/POLICIES.md` but remains canonical-equivalent (e.g.
  bucket type, window semantics).
- **gw-routing** — path-compose / header assembly quirks we route
  around at the fixture level.
- **plugin** — a Yaegi / Lua user plugin that emulates a primitive
  the gateway does not ship natively.
- **infra** / **infra-patch** — a shim outside the gateway's own
  plugin surface (entrypoint `sed`, template patch, etc.).
- **sandbox** — Lua sandbox whitelist for a known-audited module.
- **harness** — the parity harness itself makes the deviation (and
  Phase 4 k6 load confirms it is stricter than paced traffic).
- **platform** — host-OS / architecture quirk, never ranking-bearing.
- **historical** — retired in-tree, kept here for reviewer context.

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
  `INVALID_BASE_PATH` on the Wallarm API Gateway, so we register
  one service per path prefix that the fixtures touch instead of a
  single catch-all.

Root cause
: Validation in `wallarm-api-gateway` (`crates/validation/src/base_path.rs`)
  required a non-empty suffix at the current build; catch-all support
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
: `accepted` — revisit when a later public tag ships with
  catch-all.

#### [gw=wallarm, p=p02-jwt] (historical, no longer active)

What this deviation used to say
: Earlier iterations pinned the public `wallarm/api-gateway:0.2.0`
  image which did not ship a `jwt_validation` policy; the benchmark
  tagged `p02-jwt` as `FEATURE-MISSING` and reran against a
  source-built override. Iteration 23 retired the public pin
  entirely and made `WALLARM_IMAGE` a required variable (see
  [.notes/PROGRESS.md § Iteration 23](../.notes/PROGRESS.md)). The
  profile now expects `PASS (6/6)` unconditionally and
  [`setup.sh`](../gateways/wallarm/p02-jwt/setup.sh) keeps the
  `GET /policies → FEATURE-MISSING` path only as a sanity guard
  against mis-aimed `WALLARM_IMAGE` values.

Status
: `retired` — single-track. See
  [`gateways/wallarm/p02-jwt/NOTES.md`](../gateways/wallarm/p02-jwt/NOTES.md)
  for the current notes.

#### [gw=wallarm, p=p04-rl-static]

What differs
: `docs/POLICIES.md` specifies a *rolling* 1 s window. In the public
  the current build Admin API, the `ratelimit` policy exposes a `window_type` flag
  with values `fixed` and `sliding`. Empirically, `window_type: fixed`
  with `window: 1` does not rate-limit (the upstream integration suite
  only exercises `window: 60`). `window_type: sliding` matches the
  "rolling" semantics from POLICIES.md and is what the setup script
  ships.

Root cause
: Implementation detail of the `fixed` bucket at
  `window: 1` in the current wallarm build. See
  [`wallarm-api-gateway/tests/integration/single_node_ratelimit_accuracy_test.sh`](../wallarm-api-gateway/tests/integration/single_node_ratelimit_accuracy_test.sh)
  — no test covers `window: 1` at all.

Resolution
: `gateways/wallarm/p04-rl-static/setup.sh` picks
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

#### [gw=wallarm, p=p06-rl-dynamic-low / p07-rl-dynamic-high]

What differs
: Both dynamic-RL profiles use `ratelimit_key:
  "${request.headers.x-real-ip}"` — a wallarm context expression
  that resolves at request time. Bucketing happens per unique
  expression value inside a service-scoped namespace. Same
  `window_type: sliding` choice as `p04-rl-static` (`fixed` +
  `window: 1` is a no-op against the current build).

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
  request: for `p06-rl-dynamic-low` with 10 IPs ×
  45 req/s-sliding-window, `10 × 2xx + 35 × 429` per IP → cross-IP
  `100 × 2xx, 350 × 429` (observed `99 × 2xx, 351 × 429`). For
  `p07-rl-dynamic-high` saturating a single IP with 500 reqs →
  `100 × 2xx, 400 × 429` exact.

Impact on ranking
: `none` — every gateway in the matrix implements dynamic RL with
  an IP-keyed bucket; wallarm's context expression is the same
  primitive as envoy's `local_ratelimit` descriptors, kong's
  `rate-limiting` plugin with `limit_by=header`, nginx's
  `limit_req_zone` keyed on `$http_x_real_ip`, etc.

Status
: `accepted` — mirrored in `gateways/wallarm/p06-rl-dynamic-low/NOTES.md`
  and `gateways/wallarm/p07-rl-dynamic-high/NOTES.md`.

#### [harness, p=burst-runner-ignores-duration_s]

What differs
: Rate-limit fixtures (`p04-rl-static`, `p06-rl-dynamic-low`,
  `p07-rl-dynamic-high`) carry a `duration_s` field, but
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
  (for example `Authorization: Bearer ${JWT_VALID}` in
  `p12-full-pipeline`) while keeping the same ASAP scheduling model.

Impact on ranking
: `none` — parity certifies correctness, not RPS. Phase 4 k6 load
  profiles produce the actual throughput numbers using paced
  arrivals.

Status
: `accepted` — documented here and in each RL profile's NOTES.md.

#### [gw=wallarm, p=p08-req-headers]

What differs
: wallarm's base-path strip **always** leaves a trailing `/`
  between the stripped `base_path` and the `target.endpoint.url`
  (e.g. client `GET /headers` → upstream `/headers/`), and
  `go-httpbin`'s `/headers`, `/response-headers`, `/get` endpoints
  all 404 on the trailing-slash variant.

Root cause
: Path-compose behaviour of the Rust proxy. Empirically verified on
  the Wallarm API Gateway against a canonical p01-vanilla service
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

#### [gw=wallarm, p=p09-resp-headers]

What differs
: Same base-path-strip workaround as `p08-req-headers`, so this
  profile routes `/response-headers` →
  `backend:8080/anything/response-headers` and
  `/get` → `backend:8080/anything/get`. `go-httpbin`'s
  `/anything/*` catch-all does **not** emit a `Server:` header on
  responses; only the first-class `/response-headers` endpoint does,
  and we can't reach that one through wallarm without hitting
  the trailing-slash 404.

Root cause
: Same the current build path-compose behaviour + go-httpbin's `Server` header
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
  be verified transitively via `p12-full-pipeline`, but since
  `p12-full-pipeline` was itself FEATURE-MISSING on the public image
  (cascade from `p02-jwt`), the drop-side check stays structural on
  wallarm until a public tag ships with either a `preserve_path`
  knob or `jwt_validation`. Both `p02-jwt` and `p12-full-pipeline`
  are now retired in favour of the from-source `WALLARM_IMAGE`
  build (Iteration 23).
  Every other gateway in this bench routes `/response-headers`
  straight to `go-httpbin` and exercises the drop for real.

Status
: `accepted` — mirrored in `gateways/wallarm/p09-resp-headers/NOTES.md`.

#### [gw=wallarm, p=p10-req-body]

What differs
: Wallarm does not expose a dedicated `body_transform` policy.
  JSON request-body rewrite is performed via `lua_runner` +
  `cjson.safe`, which is the built-in Lua sandbox documented in the
  Wallarm policy guide. The policy reads `ctx.request.body`, decodes,
  mutates (`$.bench.injected = true`, `$.secret = nil`), re-encodes
  and writes back, and explicitly recomputes `Content-Length`.

Root cause
: No first-class `body_transform` primitive in the current wallarm build. The Lua sandbox
  is the only available vehicle until a dedicated policy ships in a
  later release.

Resolution
: `lua_runner` on `request_flow`. `Transfer-Encoding` is not
  manipulated because wallarm does not expose chunked framing to Lua
  and buffered mode has already materialised the body.

Impact on ranking
: The benchmark measures a Lua-based rewrite path for wallarm on
  `p10-req-body` / `p11-resp-body`; other gateways (envoy Lua
  filter, openresty ngx_http_lua, apisix serverless Lua) will do
  the same. A gateway that ships a native body-transform policy
  will show it against the same fixture and the manifest will mark
  the mechanism explicitly.

Status
: `accepted` — mirrored in `gateways/wallarm/p10-req-body/NOTES.md`.

#### [gw=wallarm, p=p11-resp-body]

What differs
: Same `lua_runner` + `cjson.safe` idiom as `p10-req-body`, but on
  `response_flow`. Content-Length is explicitly recomputed
  (`ctx.response.headers["content-length"] = tostring(#body)`),
  otherwise wallarm forwards the rewritten body with the stale
  upstream header and clients either see a truncated payload or hang
  on keep-alive.

Root cause
: No first-class `body_transform` primitive in the current wallarm build.

Resolution
: `lua_runner` on `response_flow`, robust to non-JSON upstream
  bodies (they pass through unmodified).

Impact on ranking
: `none` — the same Lua path is exercised on every wallarm profile
  that touches bodies, so the numbers are comparable across
  `p10-req-body`, `p11-resp-body` and `p12-full-pipeline`.

Status
: `accepted` — mirrored in `gateways/wallarm/p11-resp-body/NOTES.md`.

#### [gw=wallarm, p=p12-full-pipeline] (historical, no longer active)

What this deviation used to say
: Cascade from the historical `p02-jwt` deviation: on
  `wallarm/api-gateway:0.2.0` the composed pipeline returned `200`
  on the "missing JWT" and "expired JWT" probes because
  `jwt_validation` wasn't in the registry. Iteration 23 retired the
  public pin (see
  [.notes/PROGRESS.md § Iteration 23](../.notes/PROGRESS.md)) — the
  benchmark now requires a from-source build via `WALLARM_IMAGE`,
  and the profile expects `PASS (4/4)` unconditionally.
  [`setup.sh`](../gateways/wallarm/p12-full-pipeline/setup.sh)
  preserves the `FEATURE-MISSING` sanity guard on `/policies`.

Status
: `retired` — single-track. See
  [`gateways/wallarm/p12-full-pipeline/NOTES.md`](../gateways/wallarm/p12-full-pipeline/NOTES.md)
  for the current notes.

#### [gw=envoy, p=p04-rl-static]

What differs
: None today — the cell runs the canonical `1000 rps service-wide,
  rolling 1-second window` from `POLICIES.md § p04` at full rate.

Historical context
: An earlier iteration **did** ship a rate deviation (≈200 rps
  instead of 1000 rps) after observing envoy drop most of the
  128-parallel burst probe as connection-refused ("other" in the
  tally) on Docker Desktop / Apple Silicon. Root cause turned
  out not to be Docker Desktop throughput but
  `max_connection_duration: 0s` in envoy's
  `common_http_protocol_options` (both HCM and cluster levels).
  Per v1.32 proto docs, `0s` means "close every connection
  immediately at t=0", not "no maximum" — every request
  aborted mid-response. Removing that field (leaving
  `max_connection_duration` UNSET, which is envoy's actual
  "no maximum" setting) eliminates the connection churn and the
  rate limiter engages deterministically at the canonical rate.

Bucket shape
: `max_tokens: 200, tokens_per_fill: 50, fill_interval: 0.05s`
  — 1000 rps steady refill with a 200-request burst cap, matching
  nginx's `limit_req_zone ... rate=1000r/s` + `burst=200 nodelay`
  shape verbatim. A naive `max_tokens: 1000, tokens_per_fill: 1000,
  fill_interval: 1s` would let 1000 requests through unchecked at
  the top of every second (envoy's `max_tokens` is total capacity,
  NOT a steady-rate ceiling — this is the single most common
  cross-gateway parity trap for `local_ratelimit`).

Thread model
: `--concurrency 1` with a process-wide shared token bucket.
  Envoy's `local_ratelimit` is shared across workers by default
  (v1.17+, confirmed empirically: `--concurrency 2` and
  `--concurrency 1` produced identical pass counts on the same
  1200-req burst). Raising `--concurrency` changes raw throughput
  but never the effective rate limit.

Status
: `no deviation` — canonical 1000 rps, parity 2/2 green on the
  Apple-Silicon / Docker Desktop reference rig.

#### [gw=envoy, p=p06-rl-dynamic-low / p07-rl-dynamic-high, infra=enumerated-descriptors]

What differs
: Canonical `POLICIES.md § p06 / § p07` mandates per-client-IP
  rate limiting across a pool of 100 (`p06-rl-dynamic-low`) /
  50 000 (`p07-rl-dynamic-high`) distinct IPs. The envoy cells
  implement per-IP limiting via `envoy.filters.http.local_ratelimit`
  with `rate_limits.actions` extracting `X-Real-IP` into a
  `client_ip` descriptor key, but the `descriptors[]` list
  enumerates only the IPs the fixture exercises
  (10 for `p06-rl-dynamic-low` on `10.0.0.1..10.0.0.10`;
  11 for `p07-rl-dynamic-high` on `10.5.0.1..10.5.0.10 + 10.5.9.9`).

Root cause
: Envoy v1.32's `local_ratelimit` requires **verbatim descriptor
  matches** — quoting the v1.32.0 proto docs: "The descriptors
  must match verbatim for rate limiting to apply. There is no
  partial match by a subset of descriptor entries in the current
  implementation." Blank-value wildcard descriptors (the
  idiomatic "one bucket per unique header value" shape) landed
  in envoy v1.33 via envoyproxy/envoy#36623, one minor version
  above the pinned column image
  (`envoyproxy/envoy:distroless-v1.32.6`).

Resolution
: Enumerate every IP the fixture touches, one `descriptors[]`
  entry per IP. Each entry gets its own shared-across-workers
  token bucket sized at the canonical per-IP rate
  (`p06-rl-dynamic-low: max_tokens=10, tokens_per_fill=10,
  fill_interval=1s`; `p07-rl-dynamic-high: max_tokens=100,
  tokens_per_fill=100, fill_interval=1s`).
  `always_consume_default_token_bucket: false` so an enumerated
  match does not also drain the global safety-net bucket. Full
  parity green under this mechanism: `p06-rl-dynamic-low` 2/2,
  `p07-rl-dynamic-high` 3/3.

Impact on ranking
: `none on the parity verdict` — the filter, descriptor
  extraction, token-bucket accounting, 429 status stamping and
  `Retry-After: 1` header are all fully exercised on the
  enumerated pool. The deviation is strictly about cardinality:
  an unlisted IP falls through to the default safety-net bucket
  (sized 5 orders of magnitude above the Docker Desktop ceiling
  so it never trips in parity) rather than getting its own
  per-IP bucket.

Resolution path
: Either (a) bump the column to v1.33+ and collapse the
  enumerated list into a single wildcard-value descriptor, or
  (b) pair `local_ratelimit` with a global RLS (external rate-
  limit service) keyed on `X-Real-IP`. (a) is cheaper; (b) is
  more production-realistic. Revisit in Phase 4.

Status
: `mitigated` — parity green on the enumerated pool; full
  cardinality restoration tracked in Phase 4.

#### [gw=envoy, p=*, infra=docker-desktop-virtiofs-cache]

What differs
: Not a runtime deviation — a macOS/Apple-Silicon Docker Desktop
  **iteration-velocity gotcha** documented here for future
  contributors.

Root cause
: Docker Desktop's VirtioFS bind-mount layer occasionally caches
  a file by inode and continues serving a pre-edit copy inside
  the container even after `docker compose down -v && up`. The
  symptom surfaces as envoy rejecting an on-disk-correct
  `envoy.yaml` with `no such field` / `unknown fields` errors
  referencing an old indentation. Verified: on-host `awk` /
  `Read` show the correct file; `docker run -v <same-path>`
  alpine `sed` shows a stale copy; `docker run -v /tmp/copy`
  alpine `sed` shows the correct copy.

Resolution
: One-shot inode swap forces VirtioFS to drop the stale entry:

  ```bash
  f=gateways/envoy/<profile>/envoy.yaml
  cp "$f" "$f.new" && rm "$f" && mv "$f.new" "$f"
  ```

  `touch "$f"` does NOT invalidate the cache; only a genuine
  inode change does. After the first run the cache refreshes
  and normal editor saves (which write-then-rename, changing
  the inode) work without manual intervention.

Impact on ranking
: `none` — purely an iteration-speed concern.

Status
: `accepted` — documented in `gateways/envoy/README.md §
  Config ingestion`. Ceases to apply on Linux hosts (Phase 4
  benchmark target).

#### [gw=traefik, p=p06-rl-dynamic-low / p07-rl-dynamic-high, infra=forwardedHeaders-insecure]

What differs
: Both dynamic-RL profiles key the per-IP bucket by the
  `X-Real-IP` header
  (`middlewares.bench-pNN.rateLimit.sourceCriterion.
  requestHeaderName: X-Real-IP`). Traefik's implicit
  `ForwardedHeaders` layer at the entryPoint strips `X-Real-IP`
  as an "untrusted forwarded header" **before** the rate-limit
  middleware runs, collapsing every request into a single
  empty-string bucket and defeating the per-IP invariant.

Root cause
: Traefik's entryPoint-level forwarded-headers handling defaults
  to `insecure: false`, under which only `Forwarded`,
  `X-Forwarded-*` and `X-Real-IP` from already-trusted peers are
  preserved. On the bench `loadgen → traefik` path, the peer is
  `127.0.0.1` (loopback), which is not in the default trusted
  set, so `X-Real-IP` is stripped before any middleware sees it.

Resolution
: Set `entryPoints.web.forwardedHeaders.insecure: true` inside
  the profile's `traefik.yaml` so the rate-limit middleware
  trusts the client-supplied `X-Real-IP` verbatim. Safe in this
  topology: loadgen runs on the bench-net only, the fixture
  itself owns what `X-Real-IP` should be, and no
  production-topology assumptions are carried over.

  **Gotcha:** Traefik's static-config sources are **mutually
  exclusive** — setting `--entryPoints.web.forwardedHeaders.
  insecure=true` on the CLI alongside `--configFile=/etc/
  traefik/traefik.yaml` is silently ignored. The knob **must**
  live inside the YAML file. This tripped up ~2h of
  `p06-rl-dynamic-low` debug before the CLI flag was removed from
  `gateways/traefik/docker-compose.yaml` in favour of per-profile
  YAML. The same cut-corner shows up in
  `jkaninda/goma-gateway-vs-traefik` as a commented-out CLI flag.

Impact on ranking
: `none` — the rate-limit primitive (leaky-bucket, `429` +
  `Retry-After: 1`) is fully exercised end-to-end with the
  canonical per-IP shape; the only knob tuned is which header
  traefik uses to identify the client IP on a bench-net peer.

Status
: `accepted` — mirrored in
  `gateways/traefik/p06-rl-dynamic-low/NOTES.md` and
  `gateways/traefik/p07-rl-dynamic-high/NOTES.md`.

#### [gw=traefik, p=p10-req-body / p11-resp-body / p12-full-pipeline, infra=yaegi-json-literal-coercion]

What differs
: The body-rewrite middleware is implemented as a local Yaegi
  plugin under `gateways/traefik/_shared/plugins-local/src/
  github.com/wallarm/body_rewrite/`. Its config
  (`injectValue: true`, `dropPaths: [secret]` / `[origin]`)
  is passed through Traefik's plugin-config deserializer, which
  stringifies every YAML scalar — so `injectValue: true` arrives
  in the Go code as the literal `string("true")`, not as
  `bool(true)`.

Root cause
: Traefik's plugin config pipeline decodes YAML into
  `map[string]interface{}` with string-typed leaves (unlike the
  main static-config decoder, which preserves types). Yaegi
  plugin authors are expected to coerce scalar strings back to
  their intended JSON literal type inside the plugin's `New()`
  constructor. Not documented prominently; found via first
  failure on the canonical "inject unquoted `true`" probe.

Resolution
: A `coerceJSONLiteral` helper inside `body_rewrite.go::New()`
  promotes `"true" | "false" | "null" | <number-like>` strings
  to their native Go types (`bool`, `nil`, `float64`) before
  they reach the JSON encoder. After the fix,
  `{"bench":{"injected":true}}` (unquoted) is what the fixture
  asserts on, both for `p10-req-body` (request body seen by backend)
  and `p11-resp-body` (response body seen by client).

Impact on ranking
: `none` — the body-rewrite primitive itself (JSON decode →
  dotted-path mutate → encode → framing recompute) is fully
  exercised end-to-end; the coercion shim only rescues scalar
  literals carrying a JSON-primitive semantic through a YAML
  surface.

Status
: `accepted` — captured in
  `gateways/traefik/_shared/plugins-local/src/github.com/
  wallarm/body_rewrite/body_rewrite.go` and in the profile
  NOTES for `p10-req-body` / `p11-resp-body` /
  `p12-full-pipeline`.

#### [gw=traefik, p=p02-jwt / p12-full-pipeline, infra=yaegi-json-no-method-dispatch]

What differs
: The HS256 JWT middleware is implemented as a local Yaegi
  plugin under `gateways/traefik/_shared/plugins-local/src/
  github.com/wallarm/jwt_hs256/`. The textbook way to accept a
  JWT `exp` claim that arrives as either a JSON number or a
  numeric string is a small struct with a custom
  `UnmarshalJSON` method (cf. `flexInt` pattern). Native Go:
  works perfectly. Yaegi: silently fails — the interpreter's
  reflect-driven JSON decoder skips method dispatch on
  user-declared types, so the custom `UnmarshalJSON` never
  fires and the fallback decoder bombs with
  `"json: cannot unmarshal number into Go struct field .exp of
  type struct { Xvalue int64; Xset bool }"`.

Root cause
: Yaegi's `encoding/json` wrappers expose the package
  symbols (`Unmarshal`, `Marshal`, `RawMessage`, …) but the
  reflect plumbing inside `Unmarshal` walks the AST of types
  declared in interpreted Go, NOT compiled Go, and method
  resolution on those interpreted types takes a different
  path that misses pointer-receiver method dispatch. This is
  not documented as a hard restriction; it surfaces only when
  a plugin tries to wire `json.Unmarshaler` onto a custom type.

Resolution
: Replace the `flexInt` struct with a per-claim `RawMessage`
  pattern: decode the payload as
  `map[string]json.RawMessage`, then re-decode each individual
  claim (`exp`, `nbf`) as `int64` via a second
  `json.Unmarshal` call. Sticks to plain stdlib types Yaegi
  hands back byte-for-byte — no method dispatch needed. The
  fallback gives up the "accept either number or
  numeric-string" flexibility, which is acceptable because the
  canonical `gen-jwt.sh` minter (and every other gateway in
  the matrix) emits raw JSON numbers; numeric-string `exp`
  is a non-canonical shape we don't have to support.

Impact on ranking
: `none` — the JWT primitive itself (HMAC-SHA-256 verify,
  `alg=HS256` gate, exp/nbf check, 401 with
  `WWW-Authenticate: Bearer`) is fully exercised end-to-end;
  the workaround only changes the claim-decoding mechanic
  inside the plugin's `verify()`.

Status
: `accepted` — captured in
  `gateways/traefik/_shared/plugins-local/src/github.com/
  wallarm/jwt_hs256/jwt_hs256.go` (inline comment on the
  decode block) and in the profile NOTES for `p02-jwt` /
  `p12-full-pipeline`.

#### [gw=apisix, p=p08-req-headers / p12-full-pipeline, infra=nginx-conf-xff-patch]

What differs
: APISIX generates its own `nginx.conf` at container start via
  `apisix init` and the generated file hard-codes
  `proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;`.
  `$proxy_add_x_forwarded_for` is an nginx builtin that is
  **read-only from Lua**, so neither
  `proxy-rewrite.headers.remove: [X-Forwarded-For]` (only touches
  the client-supplied header; nginx's proxy module re-stamps its
  own after the plugin runs) nor a `serverless-pre-function`
  doing `ngx.var.proxy_add_x_forwarded_for = ""` (500 Internal
  Server Error — variable is read-only) can fully suppress the
  header. Nothing in the shipped plugin surface exposes this
  knob.

Root cause
: APISIX's runtime config generator (`apisix init`) does not have
  a template knob for the XFF assembly. The header is assembled
  inside nginx's core http_proxy module, below the plugin surface
  that APISIX exposes.

Resolution
: A custom entrypoint wrapper
  [`gateways/apisix/_shared/bench-start.sh`](../gateways/apisix/_shared/bench-start.sh)
  runs after `apisix init` and `sed`s the generated `nginx.conf`
  in-place, rerouting XFF through a writable NGINX variable:

  ```nginx
  # before
  proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
  # after
  set              $bench_xff      $proxy_add_x_forwarded_for;
  proxy_set_header X-Forwarded-For $bench_xff;
  ```

  A `serverless-pre-function` (access phase) can then do
  `ngx.var.bench_xff = ""` to fully suppress   the downstream
  header, including the NGINX-auto-appended portion. The patch
  is idempotent: guarded by a literal-line `grep`, it no-ops if
  APISIX upstream changes the default shape. If that ever
  happens, `p08-req-headers` / `p12-full-pipeline` fail their
  respective fixture assertions, which is the intended
  early-warning signal.

Impact on ranking
: `none` — the sed patch only targets the header-carrying line
  of `nginx.conf`, reshaping it into a functionally equivalent
  writable-variable form. Upstream headers and trust semantics
  are unchanged.

Status
: `accepted` — captured in
  `gateways/apisix/_shared/bench-start.sh` + the shared
  `docker-compose.yaml` entrypoint override.

#### [gw=apisix, p=p09-resp-headers / p12-full-pipeline, infra=ngx-header-server-nil]

What differs
: Suppressing the `Server:` response header on APISIX requires a
  `serverless-post-function` in the `header_filter` phase that
  does `ngx.header["Server"] = nil` (the same escape hatch nginx
  uses via `more_clear_headers "Server"`). The native
  `response-rewrite.headers.remove: [Server]` primitive on its
  own does not reliably strip OpenResty's late `Server:
  openresty/...` stamp; the remove-pass runs at plugin-output
  stage, while nginx re-stamps during its own header filter
  chain later.

Root cause
: OpenResty's core header filter runs after the plugin output
  stage. `response-rewrite.headers.remove` works against headers
  present at plugin-output time; OpenResty's core module stamps
  `Server:` after that pass.

Resolution
: `p09-resp-headers` uses a `serverless-post-function` pinned to
  `phase: header_filter` that calls `ngx.header["Server"] = nil`
  — the canonical OpenResty escape hatch that executes during
  nginx's own header filter chain. The shared baseline also sets
  `apisix.server_tokens: false` in
  `apisix.standalone.yaml` to disable APISIX's own default
  Server stamp (which is a separate source of the header).

  `p12-full-pipeline` cannot repeat the same mechanism: APISIX
  allows only one `serverless-post-function` instance per route
  (each serverless plugin resolves exactly one phase per
  instance, see
  `/usr/local/apisix/apisix/plugins/serverless/init.lua`,
  `call_funcs`), and `p12-full-pipeline`'s post-function slot is
  spent on `phase: body_filter` for response-body rewrite
  (`p11-resp-body`). In `p12-full-pipeline` we rely on
  `response-rewrite.headers.remove: [Server]` alone — which
  suffices under the combined conditions of
  `server_tokens: false` in the baseline, and the fact that
  go-httpbin's `/anything` endpoint (the only path
  `p12-full-pipeline` probes) does not emit a Server header of
  its own. Empirically verified against `/anything`, `/get`,
  and `/response-headers?Server=foo` on `p12-full-pipeline` —
  all three return a Server-header-free response.

Impact on ranking
: `none` — the external semantic (client never sees a Server
  header) is identical across `p09-resp-headers` and
  `p12-full-pipeline`; the split is purely a consequence of
  APISIX's one-instance-per-plugin-per-route rule.

Status
: `accepted` — captured in
  `gateways/apisix/p09-resp-headers/apisix.yaml`
  (explicit `serverless-post-function` hook) and
  `gateways/apisix/p12-full-pipeline/apisix.yaml`
  (plain `response-rewrite.headers.remove` + shared
  `server_tokens: false`).

#### [gw=kong, p=p08-req-headers / p12-full-pipeline, infra=nginx-template-xff-patch]

What differs
: Kong's nginx template
  (`/usr/local/share/lua/5.1/kong/templates/nginx_kong.lua`)
  hard-codes
  `proxy_set_header X-Forwarded-For $upstream_x_forwarded_for;`
  in six locations, and `runloop.access.after()` writes
  `$upstream_x_forwarded_for` AFTER all access-phase plugins
  finish (kong's plugin lifecycle is
  `runloop.access.before → plugins[access] → runloop.access.after`).
  Plugins trying to drop the header via `request-transformer.remove`,
  `kong.service.request.clear_header()`, or
  `ngx.req.clear_header()` therefore **always lose** to Kong's
  later write — the upstream sees X-Forwarded-For regardless.
  Both `p08-req-headers` and `p12-full-pipeline` need the header
  gone; Kong's plugin surface alone cannot deliver this.

Root cause
: Plugin lifecycle ordering in `kong/init.lua::Kong.access()`. The
  `proxy_set_header` directive itself is not a plugin-controllable
  knob — it lives in Kong's compiled nginx template, which the
  Admin API / declarative config does not expose.

Resolution
: A custom entrypoint shim
  [`gateways/kong/_shared/bench-start.sh`](../gateways/kong/_shared/bench-start.sh)
  pre-patches the kong template before the stock `/entrypoint.sh`
  runs (idempotent `sed`s, guarded by needle-presence checks):

  1. Adds `set $bench_xff '__BENCH_XFF_DEFAULT__';` next to every
     existing `set $upstream_x_forwarded_for '';`.
  2. Re-routes every `proxy_set_header X-Forwarded-For` directive
     (and the one `grpc_set_header` twin) to `$bench_xff`.
  3. Adds a one-line shim inside `access_by_lua_block` that runs
     after `Kong.access()`:
     ```lua
     if ngx.var.bench_xff == "__BENCH_XFF_DEFAULT__" then
       ngx.var.bench_xff = ngx.var.upstream_x_forwarded_for or ""
     end
     ```
     The sentinel lets us tell apart "profile didn't touch it"
     (=> mirror Kong's default XFF; observable behaviour
     unchanged) from "profile explicitly set `bench_xff = ""`"
     (=> drop the header; an empty `proxy_set_header` value tells
     nginx not to send the header at all).

  A `pre-function` plugin in the access phase can then opt in
  with `ngx.var.bench_xff = ""`. Same pattern as the APISIX shim
  (`gateways/apisix/_shared/bench-start.sh`); both gateways hit
  the same architectural limitation (the gateway's own runloop
  stamps XFF after plugins run) and both fix it by re-routing
  through a writable variable.

Impact on ranking
: `none` — the sed targets only the X-Forwarded-For carrying
  lines and the post-`Kong.access()` shim is `O(1)` per request.
  Other X-Forwarded-* headers (Host, Port, Proto, Path, Prefix)
  are not touched. Default observable behaviour for profiles
  that don't drop XFF is identical to vanilla Kong.

Status
: `accepted` — captured in `gateways/kong/_shared/bench-start.sh`
  + the shared `docker-compose.yaml` entrypoint override.

#### [gw=kong, p=p10-req-body / p11-resp-body / p12-full-pipeline, infra=untrusted-lua-sandbox-whitelist]

What differs
: Kong's `pre-function` / `post-function` plugins run user Lua
  inside a sandbox derived from
  `kong/tools/kong-lua-sandbox.lua`. The sandbox blocks arbitrary
  `require()` by default ("require 'X' not allowed within
  sandbox"). `p10-req-body` / `p11-resp-body` /
  `p12-full-pipeline` require `require("body_rewrite")` to pull
  in the shared JSON-shape-aware editor at
  `_shared/lualib/body_rewrite.lua` — the same module the nginx
  and APISIX columns use, byte-for-byte.

Root cause
: Kong's stock sandbox policy. `pre-function`/`post-function` are
  the OSS-image-bundled extensibility points; `request-transformer`
  does flat string replacement (not JSON-shape-aware), and the
  Enterprise-only `request-transformer-advanced` would violate the
  "no third-party plugins" principle in `docs/POLICIES.md`.

Resolution
: Two compose-level env vars in `gateways/kong/docker-compose.yaml`:
  ```yaml
  KONG_UNTRUSTED_LUA: "sandbox"
  KONG_UNTRUSTED_LUA_SANDBOX_REQUIRES: "body_rewrite"
  ```
  Sandbox stays engaged; only the single, audited 80-line shared
  module can be `require`d. We deliberately do NOT use
  `KONG_UNTRUSTED_LUA: on` (which removes the sandbox entirely).

Impact on ranking
: `none` — body-rewrite semantics are identical to nginx and
  APISIX columns (the same `body_rewrite.lua` module powers all
  three).

Status
: `accepted` — single env-var pair in the shared compose file.

#### [gw=kong, p=p11-resp-body / p12-full-pipeline, infra=post-function-content-length-drop]

What differs
: A `post-function.body_filter` chunk that rewrites the response
  payload changes its byte length, but Kong's PDK does NOT
  auto-strip the upstream's `Content-Length` the way vanilla
  nginx's `body_filter` does (the apisix and nginx columns get
  this for free). Without an explicit clear, the client sees
  `Content-Length: <upstream-bytes>` and a body of
  `<rewritten-bytes>` — curl reports
  `transfer closed with N bytes remaining to read`, parity probes
  see a wedged socket.

Root cause
: Kong's PDK header filter does not detect length changes
  performed in the body filter. Documented behaviour, not a bug.

Resolution
: Every `post-function` profile that rewrites the body
  (`gateways/kong/p11-resp-body/kong.yml`,
  `gateways/kong/p12-full-pipeline/kong.yml`) carries a
  `header_filter` chunk:
  ```lua
  ngx.header["Content-Length"] = nil
  ```
  nginx then falls back to `Transfer-Encoding: chunked`, which
  is RFC-7230-legal and matches what the apisix / nginx columns
  ship for the same profiles.

Impact on ranking
: `none` — chunked-vs-fixed-length is invisible to the fixture
  (the parity script asserts JSON content, not bytes-on-wire),
  and chunked encoding is the cross-gateway default for body-
  rewrite profiles already.

Status
: `accepted` — captured in the affected profile `kong.yml` files.

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
: `docker pull --platform linux/amd64 the Wallarm API Gateway`
  lands an amd64 image on Apple Silicon that Docker Desktop runs
  under qemu. Activating **any** `lua_runner` policy in that
  configuration aborts with
  `qemu: uncaught target signal 11 (Segmentation fault) - core dumped`.
  Every `lua_runner` profile (`p08-req-headers`, `p09-resp-headers`,
  `p10-req-body`, `p11-resp-body`, `p12-full-pipeline`) therefore
  crashes the gateway on the first smoke request.

Root cause
: qemu's x86-on-arm JIT dies on LuaJIT-style tracing. Not a wallarm
  bug: the image ships a native `linux/arm64` variant in the same
  multi-arch manifest index (digest
  `sha256:0857114a…`) and Lua policies work correctly on it.

Resolution
: Do **not** force `--platform linux/amd64` on Apple Silicon. The
  docker-compose image pin (`the Wallarm API Gateway build`)
  is a multi-arch **index**, so a plain `docker pull
  the Wallarm API Gateway` (no `--platform`) resolves to the
  native arm64 variant locally and to amd64 on Linux CI.

Impact on ranking
: `none` — every benchmark run pins the arch used (x86_64 on Linux
  EC2 for "for-real" numbers, the native arch for smoke on laptops),
  and the `manifest.json` records the resolved digest along with
  `GOOS/GOARCH` of the benchmark host.

Status
: `accepted` — documented in
  `gateways/wallarm/p08-req-headers/NOTES.md § Gotcha`.

### Known / expected entries (historical, all closed by Phase 3b)

> These were the deviations we anticipated **before** each per-gateway
> config landed. Every entry below has since been resolved during the
> Phase 3b rollout — preserved here as a paper trail of how each
> blocker was closed. The canonical state-of-the-cell rollup is the
> table at the top of this section; per-cell detail is in the
> "Landed deviations" entries above.

- **Traefik / `p02-jwt`, `p12-full-pipeline`** *(closed by
  Iteration 28).* Traefik OSS ships no native HS256 JWT primitive
  and no community plugin carries knob-for-knob parity with
  `POLICIES.md § p02` (HS256-only, `Authorization: Bearer <jwt>`,
  canonical `401` on every rejection path). Closed via a custom
  HS256-only Yaegi plugin under
  `gateways/traefik/_shared/plugins-local/src/github.com/wallarm/
  jwt_hs256/`; both cells now `PASS`. The Yaegi-specific
  `RawMessage` workaround is captured in the landed deviation
  `[gw=traefik, p=p02-jwt / p12-full-pipeline,
  infra=yaegi-json-no-method-dispatch]` above.

- **Nginx / `p02-jwt`, `p10-req-body`, `p11-resp-body`** *(closed
  during Phase 3b nginx column).* All three required
  `lua-nginx-module`; resolved by switching the column to
  `openresty/openresty:<pinned>`. `ngx_http_lua` policy code lives
  under `gateways/nginx/_shared/lualib/`.

- **Envoy / `p10-req-body`, `p11-resp-body`** *(closed during
  Phase 3b envoy column).* Implemented via the Lua filter; code
  under `gateways/envoy/_shared/lua/`.

- **Tyk / `p10-req-body`, `p11-resp-body`, `p12-full-pipeline`** —
  **falsified during the Phase 3b rollout.** Tyk Classic OSS DOES
  ship a native body-rewrite primitive that we missed initially:
  `extended_paths.transform` (request body) and
  `extended_paths.transform_response` (response body), both Go
  `text/template` evaluators with the bundled
  [Sprig v3 `FuncMap`](https://masterminds.github.io/sprig/) wired
  in by `apidef.APIDefinitionLoader.filterSprigFuncs` (only the
  env-leak pair `env`/`expandenv` is stripped). Sprig's `unset` /
  `set` / `dict` / `hasKey` / `index` / `mustToJson` between them
  give us JSON-aware dotted-path mutation natively — no JSVM,
  no MiniRequestObject (un)marshal, no per-request VM context
  switch. `p10-req-body` / `p11-resp-body` / `p12-full-pipeline`
  all PASS on this primitive (`p10` 3/3, `p11` 3/3, `p12` 3/4
  with the only FAIL being the cosmetic 400/401 inherited from
  `mw_jwt.go`). The JSVM throughput cap that this redirection
  avoids is documented in
  [`gateways/tyk/p12-full-pipeline/NOTES.md`](../gateways/tyk/p12-full-pipeline/NOTES.md).

## p03-jwks-rs256-basic

`p03-jwks-rs256-basic` exercises a policy axis that sits
**outside** the 11-profile ranking matrix (see
[`docs/POLICIES.md § p03-jwks-rs256-basic`](./POLICIES.md#p03-jwks-rs256-basic)).
It is NOT part of `parity-gateway-all` and NOT part of the ranking;
it documents per-gateway capability on the RS256 + JWKS axis and is
invoked explicitly via `make parity-gateway
PARITY_GATEWAY=<gw> PARITY_PROFILE=<slug>`.

### `p03-jwks-rs256-basic` — capability pass

Per-gateway expected binding primitive on the RS256+JWKS axis:

| Gateway  | Expected primitive                                                           | Verdict                                                                                                                 |
|----------|------------------------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------------------|
| wallarm  | native `jwt_validation` policy with `{algorithm: "RS256", jwks: {...}}`      | **Verified** — `PASS 3/3` against a from-source Wallarm build passed via `WALLARM_IMAGE` (binding shape matches `wallarm-api-gateway/tests/integration/jwt_validation_test.sh § test_07`) |
| envoy    | native `envoy.filters.http.jwt_authn` with `local_jwks.inline_string`        | **Verified** — `PASS 3/3` on `envoyproxy/envoy:distroless-v1.32.6` (static bootstrap, no runtime binding)                |
| nginx    | LuaJIT FFI → `libcrypto.so`'s `EVP_DigestVerify*` on OpenResty; JWKS + `kid` dispatch in pure Lua on top of `{kid → EVP_PKEY*}` map | **Verified** — `PASS 3/3` on `openresty/openresty:1.27.1.2-alpine`. FFI against the `libcrypto.so.3` OpenResty itself links against, no extra image layers, no third-party `lua-resty-*` dependency. Profile pins OpenResty via a per-directory `.env` since `nginx:1.27.3-alpine` lacks LuaJIT FFI |
| kong     | built-in `jwt` plugin with `key_claim_name: kid` + per-consumer `jwt_secret` carrying `algorithm: RS256` + `rsa_public_key: <PEM>` | **Verified** — `PASS 3/3` on `kong/kong:3.9.1`. Kong's plugin hashes credentials by `key` (wired to the JWT's `kid` claim via `key_claim_name`), so kid→key dispatch and RS256 verify both happen inside the native plugin with zero custom Lua |
| apisix   | native `openid-connect` plugin with `use_jwks: true` + OIDC discovery URL (NOT `jwt-auth` — has no JWKS / `kid` support, see [apisix#12791](https://github.com/apache/apisix/issues/12791)) | **Verified** — `PASS 3/3` on `apache/apisix:3.15.0-debian` (standalone mode + `oidc-server` sidecar serving OIDC discovery doc alongside the canonical JWKS) |
| traefik  | native `forwardAuth` middleware delegating to an OpenResty sidecar that reuses the nginx-column Lua modules verbatim — Yaegi's stdlib allowlist excludes `crypto/rsa`/`crypto/x509`, so in-process asymmetric verify is architecturally off the table | **Verified** — `PASS 3/3` on `traefik:v3.3.4`. Sidecar is gated by Docker Compose profile `p03-jwks-rs256-basic` (enabled via `COMPOSE_PROFILES` exported by `parity-gateway.sh`), so the other eleven profile runs see zero containers change |
| tyk      | native JWT middleware with `jwt_signing_method=rsa` + JWKS URL              | **Verified** — `PARTIAL PASS 1/3` on `tykio/tyk-gateway:v5.11.1`: capability works (JWKS fetch, `kid` lookup, RS256 verify), but native rejection codes diverge (`400`/`403` vs canonical `401`) |

This table is the **capability pass** referred to in the roadmap —
every cell is now landed. Between them they cover **six distinct
native shapes** plus one sidecar escape hatch:

- **Wallarm** — Admin-API binding against a from-source build
  (`PASS 3/3`); `setup.sh` sanity-checks `jwt_validation` in
  `/policies` and exits `FEATURE-MISSING` if the primitive is
  absent on the image `WALLARM_IMAGE` points at.
- **Envoy** — fully-static bootstrap with inline JWKS (`PASS 3/3`).
- **Tyk** — file-mounted Classic API definition + JWKS-over-HTTP
  via a private-network sidecar, with two cosmetic FAILs on the
  rejection status-code axis (hard-coded `400`/`403` in Tyk's JWT
  middleware).
- **APISIX** — `openid-connect` plugin in standalone mode +
  `oidc-server` sidecar serving OIDC discovery doc alongside JWKS
  (`PASS 3/3`). Not `jwt-auth` — that plugin lacks JWKS / `kid`
  support.
- **Kong** — native `jwt` plugin with `key_claim_name: kid` and
  one `jwt_secret` credential per consumer carrying the RS256 PEM
  in `rsa_public_key` (`PASS 3/3`). The `key_claim_name` knob
  makes Kong's per-consumer credential store act as the JWKS, with
  `kid` as the dispatch key.
- **Nginx** — LuaJIT FFI to `libcrypto.so`'s `EVP_DigestVerify*`
  on OpenResty (`PASS 3/3`). FFI is against the `libcrypto.so.3`
  that OpenResty itself links against, so no extra image layers
  or third-party `lua-resty-openssl` dependency. Two-layer Lua
  library: `jwt_rs256_verify.lua` (low-level verify primitive) +
  `jwt_rs256_jwks.lua` (JWKS parse + `{kid → EVP_PKEY*}` map +
  JWT/`exp`/signature orchestration). The p03 profile pins
  `openresty/openresty:1.27.1.2-alpine` via a per-directory
  `.env`; the other eleven nginx profiles keep their existing
  image pins.
- **Traefik** — `forwardAuth` middleware pointing at an OpenResty
  sidecar that mounts the nginx-column Lua modules verbatim
  (`PASS 3/3`). Yaegi plugins have no access to `crypto/rsa`, so
  an in-process plugin is architecturally off the table. The
  sidecar is gated by Docker Compose profile `p03-jwks-rs256-basic`,
  enabled via `COMPOSE_PROFILES="${PROFILE}"` exported by
  `scripts/parity-gateway.sh`, so the other eleven traefik runs
  see zero containers change.

Together these serve as the shape-of-the-config templates for the
rest — and for any future non-JWT auth axis, the Kong
"native-store keyed by claim" pattern, the Nginx "FFI to the
libcrypto already in the image" pattern, and the Traefik
"`forwardAuth` sidecar gated by Compose profile" pattern are now
each on-file.

Per-scenario reference material:
- [`gateways/_reference/jwks-rs256/`](../gateways/_reference/jwks-rs256/)
  (private / public key + static JWKS + canonical `kid`).
- [`fixtures/p03-jwks-rs256-basic.jsonl`](../fixtures/p03-jwks-rs256-basic.jsonl)
  (3-probe fixture).
- [`scripts/gen-jwt-rs256.sh`](../scripts/gen-jwt-rs256.sh)
  (RS256 token minting — `valid` and `unknown-kid`).
- [`gateways/wallarm/p03-jwks-rs256-basic/`](../gateways/wallarm/p03-jwks-rs256-basic/)
  (landed config — Wallarm Admin API binding the
  native `jwt_validation` policy with `{algorithm: "RS256", jwks: …}`).
- [`gateways/envoy/p03-jwks-rs256-basic/`](../gateways/envoy/p03-jwks-rs256-basic/)
  (landed config — static bootstrap with inline JWKS +
  drift guard).
- [`gateways/tyk/p03-jwks-rs256-basic/`](../gateways/tyk/p03-jwks-rs256-basic/)
  (landed config — file-mounted Tyk Classic API
  definition with `jwt_source` pointing to a sidecar nginx JWKS
  origin on the private bench-net).
- [`gateways/apisix/p03-jwks-rs256-basic/`](../gateways/apisix/p03-jwks-rs256-basic/)
  (landed config — standalone-mode declarative
  `openid-connect` plugin with `use_jwks: true`, pointing at an
  `oidc-server` sidecar that serves both the OIDC discovery doc
  and the canonical JWKS on the private bench-net).
- [`gateways/kong/p03-jwks-rs256-basic/`](../gateways/kong/p03-jwks-rs256-basic/)
  (landed config — DB-less declarative `kong.yml`
  wiring Kong's native `jwt` plugin with `key_claim_name: kid`
  and a single consumer `jwt_secret` carrying
  `algorithm: RS256` + `rsa_public_key: <PEM>` embedded verbatim
  from `_reference/jwks-rs256/public.pem`; drift guard in
  `setup.sh` rejects any divergence between the embedded PEM and
  the canonical reference).
- [`gateways/nginx/p03-jwks-rs256-basic/`](../gateways/nginx/p03-jwks-rs256-basic/)
  (landed config — OpenResty 1.27.1.2 pinned via an
  in-directory `.env`; `init_by_lua_block` loads the canonical
  JWKS + PEM from a bind-mount onto `/etc/nginx/jwks-rs256/` and
  builds a `{kid → EVP_PKEY*}` map; `access_by_lua_block` runs
  `jwt_rs256_jwks.verify(authz)` per request. FFI target:
  `libcrypto.so.3` at
  `/usr/local/openresty/openssl3/lib/libcrypto.so.3`, the same
  binary OpenResty itself links against).
- [`gateways/traefik/p03-jwks-rs256-basic/`](../gateways/traefik/p03-jwks-rs256-basic/)
  (landed config — `forwardAuth` middleware pointed
  at an OpenResty sidecar reusing the nginx-column Lua modules;
  sidecar service `jwks-auth` in `gateways/traefik/docker-compose.yaml`
  is gated by `profiles: [p03-jwks-rs256-basic]` so it only boots on
  this p03 profile, and `scripts/parity-gateway.sh`
  exports `COMPOSE_PROFILES="${PROFILE}"` generically so any
  future column can use the same conditional-sidecar pattern).

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
  - `wallarm / p02-jwt` — **ready**, parity 6/6 green against a
    from-source build that exposes `jwt_validation` (pass via
    `WALLARM_IMAGE`); the deviation above is preserved for context.
  - `wallarm / p04-rl-static` — **ready**, parity 2/2 green
    (1200 rps burst, `window_type: sliding`).
  - `wallarm / p05-rl-endpoint` — **ready**, parity 4/4 green.
    Canonical per-endpoint RL via single service + two routes
    (`limited` / `free`) and `POST /services/<svc>/routes/limited/flow`
    binding the `ratelimit` policy to ONE route only. Sliding-window
    deviation inherited from `p04-rl-static`. Observed burst:
    `2xx=98, 429=1102`
    on `/anything/limited`, `2xx=1200, 429=0` on `/anything/free` —
    symmetric with nginx `2xx=107, 429=1093` and envoy
    `2xx=112, 429=1088` within a handful of requests.
  - `wallarm / p06-rl-dynamic-low` — **ready**, parity 2/2 green
    (10 rps/IP, 10 IPs × 45 reqs ASAP → `2xx=99, 429=351`;
    theoretical `100/350`, one-request drift).
  - `wallarm / p07-rl-dynamic-high` — **ready**, parity 3/3 green
    (100 rps/IP; probe 2 `2xx=200/0` exact; probe 3 single IP
    saturation `2xx=100, 429=400` exact).
  - `wallarm / p08-req-headers` — **ready**, parity 3/3 green
    (`lua_runner` on `request_flow`, base-path-strip backend trick).
  - `wallarm / p09-resp-headers` — **ready**, parity 2/2 green
    (`lua_runner` on `response_flow`; `Server`-drop side is
    structural — see deviation below).
  - `wallarm / p10-req-body` — **ready**, parity 3/3 green
    (`lua_runner` + `cjson.safe` on `request_flow`,
    Content-Length recomputed).
  - `wallarm / p11-resp-body` — **ready**, parity 3/3 green
    (`lua_runner` + `cjson.safe` on `response_flow`,
    Content-Length recomputed).
  - `wallarm / p12-full-pipeline` — **ready**, parity 4/4 green
    against the from-source build; the `setup.sh` sanity-checks
    `jwt_validation` in `/policies` and exits `FEATURE-MISSING`
    (code 42) if the primitive is absent.
  - Wallarm roster: **12 PASS, 0 FAIL, 39/39 probes** against a
    Wallarm API Gateway built from sources and passed through
    `WALLARM_IMAGE`. The previous "9 PASS / 2 FEATURE-MISSING"
    roster against `wallarm/api-gateway:0.2.0` was dropped in
    [.notes/PROGRESS.md § Iteration 23](../.notes/PROGRESS.md) —
    the public `0.2.0` image lacks `jwt_validation` and the full
    body-rewrite policy surface, so the benchmark is single-track
    against builds that ship the complete primitive set.
  - `wallarm / p03-jwks-rs256-basic` (supplemental — RS256 JWT via
    JWKS axis, sits outside the 11-profile ranking matrix) —
    **ready**, parity 3/3 green against
    the from-source build. Missing auth → 401, valid RS256 token
    with `kid=bench-rs256-2026` → 200, RS256 token with
    `kid=unknown-kid-2026` (signature mathematically valid against
    the canonical private key) → 401. Binding shape: native
    `jwt_validation` policy with `{algorithm: "RS256",
    jwks: {keys: [<one JWK derived from public.pem>]}}` matching
    `wallarm-api-gateway/tests/integration/jwt_validation_test.sh §
    test_07` verbatim. Inline JWKS only (no `jwks_uri`) for the
    first iteration. See
    [`gateways/wallarm/p03-jwks-rs256-basic/NOTES.md`](../gateways/wallarm/p03-jwks-rs256-basic/NOTES.md)
    and
    [`docs/POLICIES.md § p03-jwks-rs256-basic`](./POLICIES.md#p03-jwks-rs256-basic).
  - `nginx / p01-vanilla` — **ready**, parity 4/4 green on
    `nginx:1.27.3-alpine` (catch-all `proxy_pass` with uniform
    settings; zero deviations).
  - `nginx / p04-rl-static` — **ready**, parity 2/2 green
    (`limit_req_zone $server_name rate=1000r/s` + `burst=200 nodelay`
    + `error_page 429 @retry_after`; observed
    `2xx=262, 429=938, 5xx=0` under a 1200-req 1-second burst).
  - `nginx / p05-rl-endpoint` — **ready**, parity 4/4 green.
    `limit_req zone=bench_p05 burst=100 nodelay` placed INSIDE
    `location /anything/limited` while the catch-all `location /`
    has no `limit_req` directive. Observed burst: `2xx=107,
    429=1093, 5xx=0` on the limited endpoint, `2xx=1200, 429=0`
    on the free endpoint (the scoping invariant asserted via the
    new `status_429_max` fixture-runner assertion).
  - `nginx / p06-rl-dynamic-low` — **ready**, parity 2/2 green
    (`limit_req_zone $http_x_real_ip zone=bench_p06:1m rate=10r/s` +
    `burst=10 nodelay`; observed `2xx=109, 429=341, 5xx=0` under the
    10-IP / 450-req / 3-second fixture — symmetric to wallarm
    `99/351` within one request).
  - `nginx / p07-rl-dynamic-high` — **ready**, parity 3/3 green.
    Same mechanism as `p06-rl-dynamic-low` with
    `zone=10m rate=100r/s` + `burst=20`.
    Zone size follows from POLICIES.md's 50 000-IP pool:
    50 000 keys × ~128 B ≈ 6.4 MB, rounded up to 10 MB for LRU
    slack. Observed shapes: burst #1 (10 IPs × 20 rps) = `200/0`,
    burst #2 (1 IP × 500 rps) = `2xx=24, 429=476`. See the `✓†`
    footnote in
    [`docs/POLICIES.md § Feature availability`](./POLICIES.md#feature-availability-as-of-current-images).
  - `nginx / p08-req-headers` — **ready**, parity 3/3 green on
    mainline. Pure `proxy_set_header` — inject via literal value,
    drop via empty-string idiom (`proxy_set_header X-Forwarded-For
    "";` omits the header from the upstream request rather than
    forwarding an empty value). No Lua, no extra module.
  - `nginx / p09-resp-headers` — **ready**, parity 2/2 green on
    **OpenResty** (`openresty/openresty:1.27.1.2-alpine@sha256:761047d6…`).
    The first nginx cell that overrides the base image — mainline
    has no directive that removes the nginx-generated `Server`
    response header. `ngx_headers_more`'s `more_clear_headers
    "Server";` does, and OpenResty bundles that module. The
    override is declared in `gateways/nginx/p09-resp-headers/.env`,
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
  - `nginx / p10-req-body` — **ready**, parity 3/3 green on
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
    `wallarm / p10-req-body` — both lean on cjson.safe inside a
    Lua sandbox.
  - `nginx / p11-resp-body` — **ready**, parity 3/3 green on
    OpenResty. Canonical two-phase Lua pattern:
    `header_filter_by_lua_block` clears `Content-Length` (so nginx
    emits `Transfer-Encoding: chunked` for the modified body) and
    `body_filter_by_lua_block` collects chunks into
    `ngx.ctx.bench_buf` until `ngx.arg[2]` (EOF) fires, then
    concatenates and rewrites through
    `body_rewrite.rewrite_response_if_json` (injects
    `$.bench.injected`, drops `$.origin`). Non-JSON upstream
    bodies pass through untouched — identical behaviour to
    `wallarm / p11-resp-body`.
  - `nginx / p12-full-pipeline` — **ready**, parity 4/4 green on
    OpenResty. Composes
    `p02-jwt + p04-rl-static + p08-req-headers + p09-resp-headers +
    p10-req-body + p11-resp-body` in a single
    request flow, relying on nginx phase ordering
    (`PREACCESS → ACCESS → CONTENT → header_filter → body_filter`)
    to encode "rate-limit first, then JWT, then req-body rewrite,
    then upstream, then resp-hdr + resp-body rewrite" semantics
    without any explicit sequencing. Observed burst shape under
    1200 rps of valid-JWT GETs: `2xx=0, 429=945, 5xx=0, other=255`
    — the 945×429 confirms rate-limit fires **before** Lua auth
    (the expected order, matching the fixture's tolerance of
    `status_429_min=150 ± 50`). First gateway in the bench with a
    complete green `p12-full-pipeline`: at that point wallarm's
    cell was still `FEATURE-MISSING` because the public Wallarm
    API Gateway image lacked a `jwt_validation` policy, cascading
    the gap into the full-pipeline composition. Both wallarm
    `p02-jwt` and `p12-full-pipeline` are now retired in favour
    of the from-source `WALLARM_IMAGE` build (Iteration 23).
  - nginx roster on `1.27.3-alpine` + `openresty:1.27.1.2-alpine`:
    **12 PASS, 0 FAIL, 39/39 probes** across all 12 canonical
    profiles (including the new `p05-rl-endpoint` per-endpoint
    RL axis).
  - `envoy / p01-vanilla, p04-rl-static, p05-rl-endpoint,
    p06-rl-dynamic-low, p07-rl-dynamic-high` — **ready**, parity
    15/15 green on
    `envoyproxy/envoy:distroless-v1.32.6@sha256:569ad5b2…acf56`.
    * `p01-vanilla` — static bootstrap (listener + HCM + router),
      `codec_type: HTTP1`, `reuse_port`,
      `common_http_protocol_options.idle_timeout: 60s`,
      `request_timeout: 10s`, single `STRICT_DNS` cluster
      `backend_cluster`. Admin API exposed read-only on :9901 for
      debugging; no profile mutates envoy through it.
    * `p04-rl-static` — `envoy.filters.http.local_ratelimit` at
      HCM level, canonical 1000 rps service-wide. Bucket shape
      `max_tokens: 200, tokens_per_fill: 50, fill_interval: 0.05s`
      mirrors nginx's `rate=1000r/s, burst=200 nodelay` leaky-
      bucket semantics verbatim (a naive `max_tokens: 1000 /
      fill_interval: 1s` would let 1000 requests through at the
      top of every second — envoy's `max_tokens` is total capacity,
      not a steady ceiling). Previous "≈200 rps rate deviation"
      was traced to a `max_connection_duration: 0s` bug (closes
      every connection at t=0) and dropped after that field was
      unset across every envoy profile.
    * `p05-rl-endpoint` — per-endpoint rate limiting via the
      HCM-level `local_ratelimit` filter installed with
      `filter_enabled.default_value: 0/HUNDRED` (globally
      disabled) plus a `typed_per_filter_config` override on the
      `/anything/limited` route. Per the v1.32 LocalRateLimit
      proto: per-route config is a **full replacement**, not a
      merge — the override carries its own token bucket
      (`max_tokens: 100, tokens_per_fill: 5, fill_interval:
      0.05s` = canonical 100 rps) and its own
      `filter_enabled/enforced: 100%`. The catch-all `/` route
      ships without `typed_per_filter_config` and inherits the
      disabled HCM filter, keeping `/anything/free` unrestricted.
      No deviation today; route-level overrides are envoy's
      native per-route policy-attachment primitive.
    * `p06-rl-dynamic-low` / `p07-rl-dynamic-high` — per-IP rate
      limiting via `local_ratelimit` with `rate_limits.actions`
      extracting `X-Real-IP` into a `client_ip` descriptor key and
      enumerated `descriptors[]` entries (one per fixture IP, 10
      for `p06-rl-dynamic-low` on `10.0.0.1..10.0.0.10`, 11 for
      `p07-rl-dynamic-high` on `10.5.0.1..10.5.0.10 + 10.5.9.9`).
      Per-entry token buckets at the canonical rate
      (`p06-rl-dynamic-low: 10 rps, p07-rl-dynamic-high: 100 rps`)
      with
      `always_consume_default_token_bucket: false` to isolate
      IPs. **Enumerated-descriptors deviation** documented in
      § Deviations: v1.32 requires verbatim descriptor matches;
      wildcard-value descriptors land in v1.33
      (envoyproxy/envoy#36623). Full pool cardinality (100 /
      50 000 IPs) restored in Phase 4 by bumping the column or
      pairing with a global RLS.
    * Thread model: `--concurrency 1`. Envoy's `local_ratelimit`
      uses a **shared** token bucket across workers by default
      (v1.17+), not per-worker — we verified empirically
      (`--concurrency 1` and `--concurrency 2` produced identical
      pass counts on the same 1200-req burst) and sized every
      RL bucket at the canonical rate verbatim. Raising
      `--concurrency` changes throughput but never the effective
      rate limit.
    * Config ingestion stays on bind-mounts (`volumes:`). An
      earlier switch to Docker `configs:` was reverted once the
      `max_connection_duration: 0s` bug was fixed; that bug was
      the real cause of the phantom "bind-mount staleness" we
      thought we were seeing. An Apple-Silicon-specific VirtioFS
      cache gotcha (rare) is documented in § Deviations and
      `gateways/envoy/README.md § Config ingestion`.
  - `envoy / p03-jwks-rs256-basic` (supplemental — RS256 JWT via
    JWKS axis, sits outside the 11-profile ranking matrix) —
    **ready**, parity 3/3 green on
    `envoyproxy/envoy:distroless-v1.32.6`. Native primitive
    `envoy.filters.http.jwt_authn` at HCM level with a single
    `JwtProvider` (`issuer: gateway-benchmarks`, `forward: true`,
    `local_jwks.inline_string: '<compact JWKS>'`) and one rule
    (`match.prefix: "/", requires.provider_name:
    bench_rs256_provider`). No admin-API binding — everything is
    baked into `envoy.yaml` at container start. `setup.sh` runs a
    **drift guard** that greps the reference RSA modulus and
    `kid` verbatim against `envoy.yaml` so a future rotation of
    `gateways/_reference/jwks-rs256/` cannot leave the inline
    JWKS stale. Probes: missing auth → 401 (envoy body
    `Jwt is missing`), valid RS256 token with
    `kid=bench-rs256-2026` → 200, RS256 token with
    `kid=unknown-kid-2026` → 401 (envoy body
    `Jwt verification fails: Jwks doesn't have key to match kid
    or alg from Jwt`). Observed `jwt_authn.allowed=1,
    jwt_authn.denied=4, jwt_authn.jwks_fetch_success=0`
    confirming the filter actually fired and no remote JWKS
    fetch happened. First iteration is inline JWKS only; a
    future `jwks-rs256-remote` profile will exercise
    `remote_jwks` + `cache_duration`. See
    [`gateways/envoy/p03-jwks-rs256-basic/NOTES.md`](../gateways/envoy/p03-jwks-rs256-basic/NOTES.md)
    and
    [`docs/POLICIES.md § p03-jwks-rs256-basic`](./POLICIES.md#p03-jwks-rs256-basic).
  - `envoy / p02 jwt` — **ready**, parity 6/6 green on
    `envoyproxy/envoy:distroless-v1.32.6`. Not implemented via
    `envoy.filters.http.jwt_authn` — that filter is
    **asymmetric-only** (RS/ES/PS) and the canonical p02 fixture
    uses HS256 with a plain shared secret, which `jwt_authn` cannot
    accept. Instead: `envoy.filters.http.lua` with
    `envoy_on_request` calling into
    `gateways/envoy/_shared/lualib/jwt_hs256.lua`, a pure-Lua HS256
    verifier that composes three sibling pure-Lua modules in the
    same directory (`base64.lua`, `sha256.lua`, `json.lua`) — all
    written to run on envoy's bundled LuaJIT sandbox, which does NOT
    ship `lua-cjson` or any OpenResty `ngx.*` helper. Rejection
    path: `request_handle:respond({":status"="401",
    "www-authenticate"='Bearer realm="bench", charset="UTF-8"',
    "content-type"="application/json"}, '{"error":"unauthorized",
    "reason":"jwt_validation_failed"}')`, short-circuiting the
    filter chain before the router hands off upstream. Verifier
    rejects `alg: none`, non-HS256 algorithms, missing/expired
    `exp`, and forged signatures (constant-time HMAC compare). See
    [`gateways/envoy/p02-jwt/NOTES.md`](../gateways/envoy/p02-jwt/NOTES.md).
  - `envoy / p08-req-headers` — **ready**, parity 3/3 green.
    Native primitive: `request_headers_to_add` (with
    `append_action: OVERWRITE_IF_EXISTS_OR_ADD`) +
    `request_headers_to_remove` at the virtual-host level on the
    `route_config`. No Lua involvement; the header-mutation stage
    runs between filter-chain request phase and `router`.
    Header-key matching is case-insensitive on the envoy side, and
    wire-canonical form (`X-Bench-In`) is what the backend
    observes in `go-httpbin`'s `.headers` echo.
  - `envoy / p09-resp-headers` — **ready**, parity 2/2 green.
    Combines three knobs to fully suppress the `Server` header:
    HCM-level `server_header_transformation: PASS_THROUGH`
    prevents envoy from restamping `Server: envoy` after our
    `response_headers_to_remove: [server]` mutation;
    `response_headers_to_add` injects `X-Bench-Out: 1` with
    `OVERWRITE_IF_EXISTS_OR_ADD`. The three run in envoy's
    fixed order: upstream-sent `Server` arrives → `PASS_THROUGH`
    lets it through → `_to_remove` drops it → `_to_add` attaches
    `X-Bench-Out`. Without `PASS_THROUGH` the first step stamps
    `Server: envoy` over whatever the upstream sent, so the
    subsequent removal still leaves an envoy-stamped header; we
    verified empirically that all three must be set together.
  - `envoy / p10-req-body` — **ready**, parity 3/3 green.
    Two-filter chain: `envoy.filters.http.buffer` (with
    `max_request_bytes: 1048576`) pre-buffers the full request
    body so `request_handle:body()` returns a non-nil buffer in
    the Lua filter immediately below it. The Lua filter calls
    `gateways/envoy/_shared/lualib/body_rewrite.lua` to inject
    `$.bench.injected=true` and drop `$.secret`, then writes back
    via `buf:setBytes(new)`. Envoy's `setBytes` auto-recomputes
    `Content-Length`, so the Lua code never touches framing
    headers (unlike the nginx/OpenResty column, which has to
    update `Content-Length` manually via `ngx.req.set_header`).
    Method guard: only `POST`/`PUT`/`PATCH` get rewritten —
    `setBytes` on `GET`/`HEAD`/`DELETE` fabricates HTTP/1.1
    framing that corrupts the keep-alive pool.
  - `envoy / p11-resp-body` — **ready**, parity 3/3 green.
    Single Lua filter, no buffer filter needed — calling
    `response_handle:body()` in `envoy_on_response` installs the
    internal buffer as a side effect, which is a deliberate
    asymmetry versus `p10-req-body` (where `request_handle:body()`
    returns nil without an explicit `buffer` filter). Uses
    `body_rewrite.rewrite_response_if_json` so non-JSON upstream
    bodies (HTML error pages, streamed binary) pass through
    unchanged; only well-formed JSON objects get
    `$.bench.injected=true` injected and `$.origin` dropped.
    Identical contract to the nginx cell's
    `body_filter_by_lua_block` two-phase collector, just with
    envoy's synchronous `body()` API collapsing the whole
    thing into one callback.
  - `envoy / p12-full-pipeline` — **ready**, parity 4/4 green.
    Composition of `p02-jwt` + `p04-rl-static` + `p08-req-headers` +
    `p09-resp-headers` + `p10-req-body` + `p11-resp-body` in a single
    filter chain: `local_ratelimit` (at position 1, so a
    valid-JWT flood gets shed before any HMAC work) → `buffer`
    (request-body prerequisite for `p10-req-body`) → single Lua filter
    carrying both phase callbacks (`envoy_on_request` = JWT
    verify + request-body rewrite; `envoy_on_response` =
    response-body rewrite) → `router`. Header mutations live on
    the virtual_host. Under the 1200-req/s burst probe: `2xx=337,
    429=863, 5xx=0` — well above the fixture's `status_429_min=150
    ± 50` threshold and inside the nginx column's observed
    variance band. Matches the nginx column's phase semantics
    verbatim: rate-limit first, then auth, then rewrite.
  - `envoy` roster on
    `envoyproxy/envoy:distroless-v1.32.6@sha256:569ad5b2…acf56`:
    **12 PASS, 0 FAIL, 39/39 probes** across all 12 canonical
    profiles, matching the nginx column PASS-count verbatim.
    Second gateway column in the bench with a complete green
    matrix.
  - `tyk / p03-jwks-rs256-basic` (supplemental — RS256 JWT via
    JWKS axis, sits outside the 11-profile ranking matrix) — **ready with documented deviation**,
    parity 1/3 on `tykio/tyk-gateway:v5.11.1`. 4-container topology
    (`gwb-tyk-backend`, `gwb-tyk-redis`, `gwb-tyk-jwks-server`,
    `gwb-tyk`) on a private `bench-net`. Native primitive: Tyk
    Classic API definition with
    `enable_jwt: true, jwt_signing_method: "rsa",
    jwt_source: base64("http://jwks-server/.well-known/jwks.json"),
    jwt_identity_base_field: "sub", jwt_skip_kid: false,
    jwt_default_policies: ["bench-default-policy"]`. The JWKS sidecar
    is a single-endpoint nginx serving
    `gateways/_reference/jwks-rs256/jwks.json` at
    `/.well-known/jwks.json`; it exists because Tyk's `jwt_source`
    URL matcher is hard-coded to `^(http|https):` — `file://` is not
    supported, and the alternative (inline base64-PEM) bypasses
    `kid` lookup entirely, which would make the scenario's
    discriminating probe 3 a free PASS. `jwt_source` is itself
    base64-encoded (`aHR0c…`) per Tyk docs convention: a regression
    in Tyk 5.11.1's `getSecretFromURL` unconditionally
    base64-decodes the cached source on every subsequent request,
    so plain-URL values succeed once then fail with `illegal
    base64 data at input byte 4` on cache hit. `bench-default-
    policy` is a minimum-viable permissive policy (ACL only, no
    RL/quota) loaded from `_policies/policies.json` via
    `policies.policy_record_name` — required because Tyk rejects
    every decoded JWT with `no session found for token user
    identity` when `jwt_default_policies` is empty. `setup.sh`
    enforces drift via a direct fetch against the sidecar and
    compares `keys[0].n` + `keys[0].kid` against
    `_reference/jwks-rs256/jwks.json`. Probes: missing Authorization
    → **`400`** (Tyk returns `"Authorization field missing"`;
    canonical fixture expects `401` — **FAIL** on status code, but
    Tyk is rejecting correctly), valid RS256 token with
    `kid=bench-rs256-2026` → `200` **PASS** (capability axis),
    RS256 token with `kid=unknown-kid-2026` → **`403`** (Tyk
    returns `"Key not authorized"`; canonical fixture expects
    `401` — **FAIL** on status code, but Tyk is rejecting
    correctly). Both deviations are in `tyk/gateway/mw_jwt.go` at
    v5.11.1 as literal `http.StatusBadRequest` /
    `http.StatusForbidden` returns and are not overridable in
    Classic OSS. See
    [`gateways/tyk/p03-jwks-rs256-basic/NOTES.md`](../gateways/tyk/p03-jwks-rs256-basic/NOTES.md).
  - `apisix / p03-jwks-rs256-basic` (supplemental — RS256 JWT via
    JWKS axis, sits outside the 11-profile ranking matrix) — **ready**, parity 3/3 on
    `apache/apisix:3.15.0-debian`. 3-container topology
    (`gwb-apisix-backend`, `gwb-apisix-oidc-server`, `gwb-apisix`)
    on a private `bench-net`, APISIX deployed in **standalone mode**
    (`deployment.role: data_plane` +
    `role_data_plane.config_provider: yaml`) so the parity harness
    never touches the Admin API. Native primitive: `openid-connect`
    plugin with `bearer_only: true`, `use_jwks: true`,
    `token_signing_alg_values_expected: RS256`, and
    `discovery: http://oidc-server/.well-known/openid-configuration`.
    Under the hood the plugin uses `lua-resty-openidc`'s
    `bearer_jwt_verify`, which does proper JWKS + `kid` lookup
    (vs the simpler `jwt-auth` plugin that accepts a single inline
    `public_key` per Consumer and ignores `kid` — see
    [apisix#12791](https://github.com/apache/apisix/issues/12791)).
    The `openid-connect` plugin reads `jwks_uri` out of an OIDC
    discovery document, not a bare JWKS URL, so the
    `gwb-apisix-oidc-server` sidecar is an `nginx:1.27.3-alpine`
    container (same image digest as the core nginx column) serving
    two static endpoints — `/.well-known/openid-configuration`
    (hand-crafted minimal discovery doc pinning `issuer` to
    `gateway-benchmarks` and `jwks_uri` to its own JWKS endpoint)
    and `/.well-known/jwks.json` (bind-mounted byte-for-byte from
    `gateways/_reference/jwks-rs256/jwks.json`). `setup.sh` enforces
    drift via direct fetches from inside the sidecar and compares
    `keys[0].n` + `keys[0].kid` against the reference, plus checks
    that `issuer` matches the JWT payload template's `iss` claim.
    One bootstrap quirk: APISIX's nginx.conf template declares
    `lua_shared_dict prometheus-cache` only when the `prometheus`
    plugin is in the HTTP allow-list, so
    `apisix.standalone.yaml` lists `prometheus` (even though no
    route uses it) to prevent the `syslog` stream plugin's
    transitive require on `plugins/prometheus/exporter.lua` from
    erroring at worker init; `stream_plugins: []` is silently
    ignored in standalone-mode. See
    [`gateways/apisix/p03-jwks-rs256-basic/NOTES.md`](../gateways/apisix/p03-jwks-rs256-basic/NOTES.md).
  - `traefik / p01..p12` — **ready**, parity 36/36 green on
    `traefik:v3.3.4` (shared `docker-compose.yaml` + per-profile
    `{traefik.yaml,dynamic.yaml,setup.sh}`). Two locally-vendored
    Yaegi plugins live under
    `_shared/plugins-local/src/github.com/wallarm/`:
    `body_rewrite/` (used by `p10-req-body` / `p11-resp-body` /
    `p12-full-pipeline`) and `jwt_hs256/` (used by `p02-jwt` /
    `p12-full-pipeline`).
    * `p01-vanilla` — single `routers.bench` on
      `PathPrefix("/")`, one service on `http://backend:8080`.
      Zero middleware. 4/4 PASS.
    * `p04-rl-static` — `middlewares.bench-p04.rateLimit`
      with `average: 1000, burst: 200, period: 1s`. Leaky-bucket
      semantics map 1:1 onto nginx `rate=1000r/s burst=200
      nodelay`. 2/2 PASS.
    * `p05-rl-endpoint` — two routers: `router-limited` on
      `PathPrefix("/anything/limited")` with `bench-p05-limited`
      attached (100 rps), `router-free` on `PathPrefix("/")` without any
      middleware. Router precedence is deterministic (more
      specific path-matchers win); explicit `priority: 10` on
      the limited router is paranoia. 4/4 PASS.
    * `p06-rl-dynamic-low` / `p07-rl-dynamic-high` — `rateLimit`
      with `sourceCriterion.requestHeaderName: X-Real-IP` at
      10/100 rps respectively. Requires
      `entryPoints.web.forwardedHeaders.insecure: true` in each
      profile's `traefik.yaml` (see deviation
      [`[gw=traefik, p=p06/p07, infra=forwardedHeaders-insecure]`](#gwtraefik-pp06-rl-dynamic-low--p07-rl-dynamic-high-infraforwardedheaders-insecure));
      without it, traefik's implicit forwarded-header layer
      strips `X-Real-IP` before rate-limit sees it. 2/2 + 3/3
      PASS.
    * `p08-req-headers` — `headers.customRequestHeaders` injects
      `X-Bench-In: "1"`, drops `X-Forwarded-For: ""` (empty
      string → header removed, same idiom as nginx's
      `proxy_set_header X-Forwarded-For "";`). Drop runs before
      inject. 3/3 PASS.
    * `p09-resp-headers` — `headers.customResponseHeaders`
      injects `X-Bench-Out: "1"`, drops `Server: ""`. Traefik
      does NOT re-stamp `Server:` on the response (unlike envoy,
      which needs `server_header_transformation: PASS_THROUGH`
      to stop envoy from overwriting the upstream's `Server`
      after the drop); a single middleware carries both sides.
      2/2 PASS.
    * `p10-req-body` / `p11-resp-body` — custom Yaegi plugin
      `body_rewrite` under
      `gateways/traefik/_shared/plugins-local/src/github.com/
      wallarm/body_rewrite/`. Declared via
      `experimental.localPlugins.body_rewrite` in each
      profile's `traefik.yaml` and attached via
      `middlewares.bench-pNN.plugin.body_rewrite` with
      `target: request|response`, `injectPath: bench.injected`,
      `injectValue: true`, `dropPaths: [secret|origin]`.
      Go stdlib used (`encoding/json`, `io`, `net/http`,
      `strconv`) is entirely within Yaegi's whitelist.
      `coerceJSONLiteral` in `New()` coerces YAML-stringified
      scalars back to native Go types (see deviation
      [`[gw=traefik, p=p10/p11/p12, infra=yaegi-json-literal-coercion]`](#gwtraefik-pp10-req-body--p11-resp-body--p12-full-pipeline-infrayaegi-json-literal-coercion)).
      3/3 + 3/3 PASS.
    * `p02-jwt` — local Yaegi plugin `jwt_hs256` under
      `_shared/plugins-local/src/github.com/wallarm/jwt_hs256/`,
      ~250 LoC of stdlib-only Go (`crypto/hmac`, `crypto/sha256`,
      `encoding/base64`, `encoding/json`, `time`, `net/http`,
      `strings`, `context` — every package on Yaegi's
      allowlist). Validates HS256 signature in constant time
      (`hmac.Equal`), refuses any non-HS256 `alg` (no `none`,
      no RS256, no ES256), checks `exp` / `nbf` against
      `time.Now().Unix()` with optional leeway, rejects with
      configurable status code (default 401) + empty body +
      `WWW-Authenticate: Bearer`. Earlier `traefik:v3.3.4` baseline
      shipped this cell as `FEATURE-MISSING` because vetted
      community JWT plugins
      ([traefik-plugin-jwt](https://plugins.traefik.io/plugins/627d9a5e617b22368bde0c67/jwt),
      [traefik-plugin-jwt-validate](https://plugins.traefik.io/plugins/629a9e84617b22368b62a4d6/jwt-access-control))
      were either stale (>12 months since last commit), pulled
      in stdlib helpers outside Yaegi's allowlist (`crypto/rsa`,
      `x/crypto/ed25519`), or bundled claim-axis knobs the
      fixture doesn't exercise. Shipping ~250 LoC of stdlib-only
      Go inside the repo is cheaper to audit than vendoring any
      of those dependencies — the falsified earlier assumption
      was that no stdlib-only Yaegi-compatible HMAC verifier
      could carry the canonical p02 contract; this iteration
      proves it can. See
      [`gateways/traefik/p02-jwt/NOTES.md`](../gateways/traefik/p02-jwt/NOTES.md).
      6/6 PASS.
    * `p12-full-pipeline` — single router with six chained
      middleware in canonical order: `bench-p02 (jwt_hs256) →
      bench-p04 (rateLimit 1000 rps) → bench-p08 (headers) →
      bench-p10 (body_rewrite/req) → bench-p09 (headers) →
      bench-p11 (body_rewrite/resp)`. A 401 from `bench-p02`
      short-circuits the whole chain, so the body rewrite
      plugins only pay for requests that survived JWT + RL,
      keeping the per-request budget within Yaegi's interpreted
      reach. Burst probe (1200 req in 1 s, valid JWT) lands
      `2xx=270, 429=930` — well past the `status_429_min: 150`
      threshold. The lopsided 2xx/429 split is the loadgen's
      burst-mode parallelism (128 concurrent senders) drying out
      the rate-limit's 200-token bucket in <200 ms; same shape
      observed on kong/apisix/nginx under the same probe. See
      [`gateways/traefik/p12-full-pipeline/NOTES.md`](../gateways/traefik/p12-full-pipeline/NOTES.md).
      4/4 PASS.
  - traefik roster on `traefik:v3.3.4`:
    **12 PASS, 0 FAIL, 0 FEATURE-MISSING, 39/39 probes** —
    fourth full-baseline column in the bench after nginx,
    envoy, and apisix. Both prior FM cells closed by
    landing the `jwt_hs256` Yaegi plugin (no community
    dependency, stdlib-only Go, ~250 LoC).
  - `apisix / p01..p12` — **ready**, parity 36/36 green on
    `apache/apisix:3.15.0-debian` in standalone mode (shared
    `docker-compose.yaml` + `apisix.standalone.yaml` +
    `_shared/lualib/` + `_shared/bench-start.sh` + per-profile
    `{apisix.yaml,setup.sh,NOTES.md}`).
    * `p01-vanilla` — one route on `uris: ["/", "/*"]` with an
      explicit `methods: [GET, POST, PUT, DELETE, PATCH, HEAD,
      OPTIONS]` list (standalone defaults to `GET`-only when
      methods is unset, and probe 3 of the fixture is a POST).
      Upstream `roundrobin` to `backend:8080`. 4/4 PASS.
    * `p02-jwt` — `serverless-pre-function` (access phase) calling
      into shared `_shared/lualib/jwt_hs256.lua` (ported from the
      nginx column; OpenResty ABI is compatible, no modifications
      needed). Rejects with `ngx.status = 401`,
      `WWW-Authenticate: Bearer realm="bench", charset="UTF-8"`,
      and a `{"error":"unauthorized", "reason":"jwt_validation_failed"}`
      body, matching the canonical shape from the nginx column.
      The native `jwt-auth` plugin is explicitly not used — it
      requires a pre-registered `consumer` / `key-auth`-style
      issuer per token, which is incompatible with the fixture's
      one-shared-HS256-secret model. 6/6 PASS.
    * `p04-rl-static` — `limit-count` service-wide, `count: 1000,
      time_window: 1, key_type: constant, key: bench_p04,
      policy: local, rejected_code: 429`. 2/2 PASS.
    * `p05-rl-endpoint` — two routes with disjoint `uris:` matchers;
      `limit-count` (100 rps, `key_type: constant`) attached only
      to `/anything/limited`. 4/4 PASS.
    * `p06-rl-dynamic-low` / `p07-rl-dynamic-high` — `limit-count`,
      `key_type: var`, `key: http_x_real_ip`, `count: 10 / 100`,
      `time_window: 1`. APISIX doesn't need a `forwardedHeaders`
      knob analogous to traefik's — the raw `http_x_real_ip`
      variable is readable without extra trust config. 2/2 + 3/3
      PASS.
    * `p08-req-headers` — `proxy-rewrite.headers.set.X-Bench-In:
      "1"` for inject. XFF drop goes through a **custom entrypoint
      wrapper** (`_shared/bench-start.sh`) that `sed`s the
      APISIX-generated `nginx.conf` in-place to reroute
      `X-Forwarded-For` through a writable `$bench_xff` variable;
      a `serverless-pre-function` (access phase) then sets
      `ngx.var.bench_xff = ""` to fully suppress the header.
      APISIX's stock `nginx.conf` hard-codes `proxy_set_header
      X-Forwarded-For $proxy_add_x_forwarded_for;` and
      `$proxy_add_x_forwarded_for` is read-only from Lua, so
      neither `proxy-rewrite.headers.remove` nor a serverless
      `ngx.var.*` write suffices on its own. See the deviation
      block
      [`[gw=apisix, p=p08-req-headers/p12-full-pipeline,
      infra=nginx-conf-xff-patch]`](#gwapisix-pp08-req-headers--p12-full-pipeline-infranginx-conf-xff-patch).
      3/3 PASS.
    * `p09-resp-headers` — `response-rewrite.headers.set.X-Bench-Out:
      "1"` for inject. Server drop goes through a
      `serverless-post-function` (header_filter phase) with
      `ngx.header["Server"] = nil`, because `response-rewrite.
      headers.remove: [Server]` on its own does not reliably
      suppress OpenResty's late Server stamp (same escape hatch as
      nginx's `more_clear_headers "Server"`). See the deviation
      block
      [`[gw=apisix, p=p09-resp-headers/p12-full-pipeline,
      infra=ngx-header-server-nil]`](#gwapisix-pp09-resp-headers--p12-full-pipeline-infrangx-header-server-nil).
      2/2 PASS.
    * `p10-req-body` — `serverless-pre-function` (access) +
      `require("body_rewrite")`. Reads the request body via
      `ngx.req.read_body()` / `ngx.req.get_body_data()`, applies
      inject + drop through the shared JSON-walker lua module,
      rewrites with `ngx.req.set_body_data(new)` + forces
      `Content-Type: application/json`. `_shared/lualib/body_rewrite.lua`
      is a byte-for-byte port of the nginx column. 3/3 PASS.
    * `p11-resp-body` — `serverless-post-function` (body_filter)
      with a chunk accumulator in `ngx.ctx.bench_buf`: on EOF, the
      accumulated buffer is JSON-rewritten through
      `body_rewrite.rewrite_response_if_json` and re-emitted in a
      single chunk with `ngx.arg[1] = new; ngx.arg[2] = true`. 3/3
      PASS.
    * `p12-full-pipeline` — composite route that **fuses** every
      custom-Lua concern into exactly two serverless hooks, because
      APISIX allows at most one instance per plugin per route and
      each `serverless-pre-function` / `serverless-post-function`
      resolves exactly one phase per instance (see
      `/usr/local/apisix/apisix/plugins/serverless/init.lua`,
      `call_funcs`). Layering:
      `limit-count` (`p04-rl-static`, rewrite phase, priority 1002
      fires before any Lua work)
      → `serverless-pre-function.phase: access` — JWT verify
      (`p02-jwt`) + request-body rewrite (`p10-req-body`) +
      `ngx.var.bench_xff = ""` (`p08-req-headers` XFF drop)
      → `proxy-rewrite.headers.set.X-Bench-In: "1"`
      (`p08-req-headers` inject)
      → `proxy_pass` to `backend:8080`
      → `response-rewrite.headers.set.X-Bench-Out: "1"` +
      `headers.remove: [Server, Content-Length]`
      (`p09-resp-headers` inject + Server drop prep)
      → `serverless-post-function.phase: body_filter`
      (`p11-resp-body` response body rewrite).
      Server drop in this profile relies on
      `response-rewrite.headers.remove: [Server]` alone rather than
      the `ngx.header["Server"] = nil` hook used in
      `p09-resp-headers`, because the `header_filter` phase is
      already "taken" by the single `serverless-post-function`
      slot (spent on body_filter). With `apisix.server_tokens:
      false` in the shared baseline and `/anything` not carrying
      a go-httpbin-sourced Server header, the plain
      `headers.remove` is sufficient in practice — empirically
      verified against `/anything`, `/get`, and
      `/response-headers?Server=foo` on `p12-full-pipeline`.
      4/4 PASS.
  - apisix roster on `apache/apisix:3.15.0-debian`: **12 PASS,
    0 FAIL, 0 other, 39/39 probes** across all profiles.
    Fourth full-green column (after nginx 12/12, envoy 12/12,
    wallarm 12/12), plus the pre-existing p03-jwks-rs256-basic
    `p03-jwks-rs256-basic` PASS 3/3 — APISIX now carries the most
    complete coverage in the bench alongside wallarm / nginx /
    envoy.
  - `kong / p01..p12` — **ready**, parity 36/36 green on
    `kong/kong:3.9.1` in DB-less declarative mode (shared
    `docker-compose.yaml` + `_shared/lualib/body_rewrite.lua` +
    `_shared/bench-start.sh` + per-profile `kong.yml` +
    `setup.sh`).
    * `p01-vanilla` — single `services[bench]` on
      `http://backend:8080`, single `routes[bench-route]` with
      `paths: [/]`, `strip_path: false`, `preserve_host: true`.
      No plugins. 4/4 PASS.
    * `p02-jwt` — Kong's native `jwt` plugin keyed on the
      `iss` claim (`key_claim_name: iss`,
      `claims_to_verify: [exp]`,
      `run_on_preflight: false`). One `consumers[bench]` carries
      a `jwt_secrets` entry with `key: gateway-benchmarks` (matches
      the canonical fixture's `iss`), `algorithm: HS256`, and
      the shared `bench-jwt-hs256-secret-2026` secret. The
      one-consumer-per-issuer model maps cleanly onto the fixture's
      single-shared-HS256-secret shape (vs APISIX's `jwt-auth`,
      which is one-consumer-per-token). 6/6 PASS.
    * `p04-rl-static` — `rate-limiting` plugin service-wide,
      `second: 1000, limit_by: service, policy: local,
      fault_tolerant: true`. 2/2 PASS.
    * `p05-rl-endpoint` — two routes with disjoint `paths:`
      matchers; `rate-limiting` (100 rps, `limit_by: service`)
      attached only to the `routes[bench-limited]` entry on
      `/anything/limited`. 4/4 PASS.
    * `p06-rl-dynamic-low` / `p07-rl-dynamic-high` — `rate-limiting`
      with `limit_by: header, header_name: X-Real-IP`,
      `second: 10 / 100`. `KONG_TRUSTED_IPS: 0.0.0.0/0,::/0` +
      `KONG_REAL_IP_HEADER: X-Real-IP` make the header readable
      across the docker-compose bench-net (Kong defaults to
      trusting nothing, which would zero-out X-Real-IP before
      the rate-limit plugin sees it). 2/2 + 3/3 PASS.
    * `p08-req-headers` — `request-transformer.add.headers:
      [X-Bench-In:1]` for inject. XFF drop goes through a
      **custom entrypoint shim** (`_shared/bench-start.sh`) that
      pre-patches Kong's nginx template at container start to
      re-route every `proxy_set_header X-Forwarded-For` directive
      through a writable `$bench_xff` variable; a `pre-function`
      (access phase) then sets `ngx.var.bench_xff = ""` to drop
      the header entirely. The native `request-transformer.remove`
      cannot reach the header because Kong's
      `runloop.access.after()` re-stamps `$upstream_x_forwarded_for`
      AFTER all access-phase plugins finish (lifecycle ordering
      bug from the plugin author's POV). See the deviation block
      [`[gw=kong, p=p08-req-headers/p12-full-pipeline,
      infra=nginx-template-xff-patch]`](#gwkong-pp08-req-headers--p12-full-pipeline-infranginx-template-xff-patch).
      3/3 PASS.
    * `p09-resp-headers` — `response-transformer.add.headers:
      [X-Bench-Out:1]` for inject + `remove.headers: [Server]`
      for the upstream Server header. Kong's own Server stamp
      is suppressed globally at the compose layer via
      `KONG_HEADERS: off`, so `response-transformer.remove`
      against the upstream's Server is sufficient — no
      `header_filter` Lua hook needed (unlike APISIX, where
      OpenResty's late stamp requires a `serverless-post-function`
      hook in `p09-resp-headers`). 2/2 PASS.
    * `p10-req-body` — `pre-function` (access phase) +
      `require("body_rewrite")`. Reads the request body via
      `ngx.req.read_body()` / `ngx.req.get_body_data()`, applies
      inject + drop through the shared JSON-walker lua module
      (`gateways/kong/_shared/lualib/body_rewrite.lua`,
      byte-for-byte port of nginx and APISIX columns), rewrites
      with `ngx.req.set_body_data(new)` + forces `Content-Type:
      application/json`. The shared module is allowed inside
      Kong's Lua sandbox via the
      `KONG_UNTRUSTED_LUA_SANDBOX_REQUIRES: body_rewrite`
      whitelist (sandbox stays on; only this single audited
      module is requirable). See the deviation block
      [`[gw=kong, p=p10-req-body/p11-resp-body/p12-full-pipeline,
      infra=untrusted-lua-sandbox-whitelist]`](#gwkong-pp10-req-body--p11-resp-body--p12-full-pipeline-infrauntrusted-lua-sandbox-whitelist).
      3/3 PASS.
    * `p11-resp-body` — `post-function` with two phases:
      `header_filter` clears `Content-Length` (Kong's PDK does
      not auto-strip it on body changes the way vanilla nginx
      does — see deviation
      [`[gw=kong, p=p11-resp-body/p12-full-pipeline,
      infra=post-function-content-length-drop]`](#gwkong-pp11-resp-body--p12-full-pipeline-infrapost-function-content-length-drop));
      `body_filter` accumulates chunks in `ngx.ctx.bench_buf`
      and on EOF rewrites with
      `body_rewrite.rewrite_response_if_json` and emits a single
      chunk via `ngx.arg[1] = new; ngx.arg[2] = true`. nginx then
      falls back to `Transfer-Encoding: chunked`, identical to
      apisix and nginx columns. 3/3 PASS.
    * `p12-full-pipeline` — composite route stacking every
      primitive: `jwt` (`p02-jwt`) →
      `rate-limiting` (`p04-rl-static`, `second: 1000`) →
      `request-transformer.add.headers: [X-Bench-In:1]`
      (`p08-req-headers` inject) →
      `response-transformer.add.headers: [X-Bench-Out:1]` +
      `remove.headers: [Server]` (`p09-resp-headers`) →
      `pre-function.access` fused for `ngx.var.bench_xff = ""`
      (`p08-req-headers` XFF drop) + conditional request-body
      rewrite on POST/PUT/PATCH (`p10-req-body`) →
      `post-function` with `header_filter` (Content-Length drop)
      + `body_filter` (response body rewrite, `p11-resp-body`).
      Kong's plugin priority ordering (`jwt > rate-limiting >
      request-transformer > response-transformer > pre-function
      > post-function`) lines up with the canonical pipeline
      shape from `docs/POLICIES.md` — RL fires first, JWT
      second, then transforms — without us needing to override
      priorities. 4/4 PASS.
  - kong roster on `kong/kong:3.9.1`: **12 PASS, 0 FAIL,
    0 other, 39/39 probes** across all profiles. Fifth
    full-green column (after nginx 12/12, envoy 12/12,
    wallarm 12/12, apisix 12/12).
  - `kong / p03-jwks-rs256-basic` (supplemental — RS256 JWT via
    JWKS axis, sits outside the 11-profile ranking matrix) — **ready**, parity 3/3 green on
    `kong/kong:3.9.1`. Native primitive: the built-in `jwt`
    plugin with `key_claim_name: kid` plus one `jwt_secret`
    credential on the `bench` consumer carrying
    `{algorithm: RS256, rsa_public_key: <PEM from
    _reference/jwks-rs256/public.pem>, key: bench-rs256-2026}`.
    Kong hashes credentials by `key` in-memory, so setting
    `key_claim_name: kid` wires the JWT's `kid` claim to the
    credential lookup — kid→key dispatch and RS256 signature
    verify both happen inside the native plugin, zero custom Lua.
    Missing auth and unknown-kid both reject with the canonical
    `401` (Kong's default error strings `"Unauthorized"` /
    `"No credentials found for given 'iss'"` are cosmetic; the
    fixture asserts status codes only). Drift guard in
    `setup.sh` compares the `rsa_public_key` value embedded in
    `kong.yml` against `_reference/jwks-rs256/public.pem` and
    blocks boot on any mismatch. See
    [`gateways/kong/p03-jwks-rs256-basic/NOTES.md`](../gateways/kong/p03-jwks-rs256-basic/NOTES.md)
    and
    [`docs/POLICIES.md § p03-jwks-rs256-basic`](./POLICIES.md#p03-jwks-rs256-basic).
  - `traefik / p02-jwt + p12-full-pipeline` — **closed**, FM →
    PASS via the new `jwt_hs256` Yaegi plugin under
    `_shared/plugins-local/src/github.com/wallarm/jwt_hs256/`
    (~250 LoC of stdlib-only Go: `crypto/hmac`,
    `crypto/sha256`, `encoding/base64`, `encoding/json`,
    `time`, `net/http`, `strings`, `context`). `p02-jwt` closes
    cleanly 6/6; `p12-full-pipeline` composes the new JWT step
    on top of the already-green
    `p04-rl-static + p08-req-headers + p10-req-body +
    p09-resp-headers + p11-resp-body` chain in canonical order
    and lands 4/4 including the burst (2xx=270, 429=930, well
    past `status_429_min: 150`). Falsifies the earlier Phase 3b
    assumption that traefik `p02-jwt` / `p12-full-pipeline` were
    architecturally FM on the OSS baseline: Yaegi's stdlib
    allowlist exposes everything an HMAC-SHA-256 verifier needs,
    the gap was just an unwillingness to vendor a community
    plugin we couldn't audit. Sixth full-green core column
    (after nginx, envoy, wallarm, apisix, kong).
  - `nginx / p03-jwks-rs256-basic` (supplemental — RS256 JWT via
    JWKS axis, sits outside the 11-profile ranking matrix) — **ready**, parity 3/3 green on
    `openresty/openresty:1.27.1.2-alpine`. Native primitive
    doesn't exist (vanilla nginx has no JWT module); we ship a
    two-layer pure-LuaJIT-FFI verifier against the
    `libcrypto.so.3` OpenResty itself links against
    (`/usr/local/openresty/openssl3/lib/libcrypto.so.3`), zero
    third-party `lua-resty-*` dependency and no Dockerfile layer
    bump. `gateways/nginx/_shared/lualib/jwt_rs256_verify.lua`
    owns the low-level `EVP_DigestVerify*` verify primitive;
    `gateways/nginx/_shared/lualib/jwt_rs256_jwks.lua` owns the
    JWT-layer semantics (`kid` lookup against an in-memory
    `{kid → EVP_PKEY*}` map, `exp` freshness, segment-count
    shape check, canonical `401` on every reject). The other
    eleven nginx profiles keep their existing image pins; the
    p03 profile pins OpenResty via a per-directory `.env`, and
    the shared `gateways/nginx/docker-compose.yaml`
    bind-mounts `_reference/jwks-rs256/` onto
    `/etc/nginx/jwks-rs256/` (inert for every other profile —
    no nginx.conf outside this one references the path). Drift
    guards in `setup.sh` reject boot on any divergence between
    the mounted JWKS / PEM / kid and the canonical reference. See
    [`gateways/nginx/p03-jwks-rs256-basic/NOTES.md`](../gateways/nginx/p03-jwks-rs256-basic/NOTES.md)
    and
    [`docs/POLICIES.md § p03-jwks-rs256-basic`](./POLICIES.md#p03-jwks-rs256-basic).
  - `traefik / p03-jwks-rs256-basic` (supplemental — RS256 JWT
    via JWKS axis, sits outside the 11-profile ranking matrix) —
    **ready**, parity 3/3 green on
    `traefik:v3.3.4`. Native primitive: the `forwardAuth`
    middleware pointed at an OpenResty sidecar that reuses the
    nginx-column Lua modules verbatim (column-local copies under
    `gateways/traefik/p03-jwks-rs256-basic/jwks-auth/lualib/`, drift
    guard in `setup.sh` diffs against the nginx canonical on
    every boot so a bugfix on the nginx column can't silently
    drift). Yaegi's stdlib allowlist excludes `crypto/rsa` /
    `crypto/x509`, so an in-process plugin for asymmetric verify
    is architecturally off the table (unlike HS256, which the
    in-repo `jwt_hs256` Yaegi plugin closes cleanly). The
    sidecar service `jwks-auth` in
    `gateways/traefik/docker-compose.yaml` is gated by
    `profiles: [p03-jwks-rs256-basic]` so it only starts when the
    p03 profile is selected; `scripts/parity-gateway.sh`
    exports     `COMPOSE_PROFILES="${PROFILE}"` generically so the other
    eleven traefik profile runs (and every other gateway)
    see zero containers change. See
    [`gateways/traefik/p03-jwks-rs256-basic/NOTES.md`](../gateways/traefik/p03-jwks-rs256-basic/NOTES.md)
    and
    [`docs/POLICIES.md § p03-jwks-rs256-basic`](./POLICIES.md#p03-jwks-rs256-basic).
  - `tyk` (11 ranking profiles `p01–p02 + p04–p12`) —
    **landed**. **9 PASS, 2 PARTIAL PASS, 27/32 probes** on
    `tykio/tyk-gateway:v5.11.1` in standalone (file-based apps +
    policies) mode. `p01-vanilla` + `p04-rl-static` +
    `p05-rl-endpoint` + `p06-rl-dynamic-low` + `p07-rl-dynamic-high` +
    `p08-req-headers` + `p09-resp-headers` + `p10-req-body` +
    `p11-resp-body` land cleanly on native Tyk Classic
    primitives (`global_rate_limit`, `extended_paths.rate_limit`,
    JSVM `pre` per-IP session synth for `p06-rl-dynamic-low` /
    `p07-rl-dynamic-high`, `transform_headers` /
    `transform_response_headers`, native `transform` /
    `transform_response` + Sprig templates for the body axes);
    `p02-jwt` and `p12-full-pipeline` are PARTIAL PASS, each
    tripping on the same hard-coded literal in
    `gateway/mw_jwt.go` v5.11.1 (`http.StatusBadRequest` for
    missing-`Authorization`, `http.StatusForbidden` for any other
    rejection — neither overridable in OSS without a custom build).
    The JWT capability itself is fully native and works on every
    signed token. Architectural note: `p10-req-body` /
    `p12-full-pipeline` use Tyk's NATIVE `transform` middleware
    (Go template + Sprig) NOT the JSVM `pre` middleware Tyk's
    docs reach for first — the JSVM caps Tyk at ~830 rps via
    per-request `MiniRequestObject` (un)marshal + VM context
    switch, below the 1000 rps `global_rate_limit` threshold,
    so `p12-full-pipeline`'s burst probe could never trigger any
    429s with the JSVM in the chain. Native template lands the
    canonical `2xx≈999, 429≈201` split. Full investigation in
    [`gateways/tyk/p12-full-pipeline/NOTES.md`](../gateways/tyk/p12-full-pipeline/NOTES.md).
  - **Engineer rosters:** nginx **12/12** + envoy **12/12** +
    wallarm **12/12** + apisix **12/12** + kong **12/12** +
    traefik **12/12** + tyk **9/12 + 3 PARTIAL PASS**. Six
    full-green columns plus traefik's now-closed 12/12
    column (FM cells unblocked by the in-repo `jwt_hs256`
    Yaegi plugin), with tyk's honest 9+2 baseline as the lone
    PARTIAL — every cosmetic FAIL traced to one fixed `mw_jwt.go`
    literal that no config knob in Tyk Classic OSS can override.
- Burst parity runner (`p04-rl-static` / `p06-rl-dynamic-low` /
  `p07-rl-dynamic-high`) — **ready**, now uses
  `curl --parallel --parallel-max N -K <config>` so a 1200-rps burst
  actually fits inside its 1 s window. Validated end-to-end against
  `wallarm / p04-rl-static` → `2xx=998, 429=202, 5xx=0`.
- Deviations rollup table (this document) — **Phase 8 DONE**; one
  row per active cell, categorised and linked to the detailed entry.
- Quality gate that exercises this table — `bench compare-runs`
  (Phase 8 DONE, see [docs/REPRODUCIBILITY.md §
  bench compare-runs](./REPRODUCIBILITY.md#verifying-reproducibility--bench-compare-runs)).
