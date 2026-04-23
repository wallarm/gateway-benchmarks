# kong

Configurations for [Kong Gateway][kong] (OSS, DB-less declarative)
covering the 12 policy profiles defined in [TASK.md §4](../../TASK.md).
Same fixtures, same reference values, same parity-attestation harness
as every other gateway under `gateways/<gw>/`.

## Roster

| Profile              | Status        | Mechanism                                                                                       |
|----------------------|---------------|-------------------------------------------------------------------------------------------------|
| `p01-vanilla`        | **PASS 4/4**  | Single `service` + catch-all `route`, no plugins                                                |
| `p02-jwt`            | **PASS 6/6**  | Native `jwt` plugin, Consumer credential keyed by `iss`, `claims_to_verify: [exp]`              |
| `p04-rl-static`      | **PASS 2/2**  | Native `rate-limiting`, `limit_by: service`, `second: 1000`, `policy: local`                    |
| `p05-rl-endpoint`    | **PASS 4/4**  | Two routes; `rate-limiting` attached to `/anything/limited` only, `second: 100`                 |
| `p06-rl-dynamic-low` | **PASS 2/2**  | `rate-limiting`, `limit_by: header`, `header_name: X-Real-IP`, `second: 10`                     |
| `p07-rl-dynamic-high`| **PASS 3/3**  | Same primitive as p05 at `second: 100`                                                          |
| `p08-req-headers`    | **PASS 3/3**  | `request-transformer.add` inject + `pre-function.access` XFF drop via `$bench_xff` (see below)  |
| `p09-resp-headers`   | **PASS 2/2**  | `response-transformer.add` inject + `response-transformer.remove` Server drop                   |
| `p10-req-body`       | **PASS 3/3**  | `pre-function.access` + shared `_shared/lualib/body_rewrite.lua` (sandbox-whitelisted)          |
| `p11-resp-body`      | **PASS 3/3**  | `post-function.body_filter` chunk accumulator + `header_filter` Content-Length drop             |
| `p12-full-pipeline`  | **PASS 4/4**  | `jwt` + `rate-limiting` + `request-transformer` + `response-transformer` + `pre-function` + `post-function` |

Full sweep verdict: **12 PASS, 0 FAIL, 39/39 probes** on
`kong/kong:3.9.1`.

## Pinned image

```
kong/kong:3.9.1
└── sha256:6addf50e6bd8d578314cb9ce4f2d2d1e3781d2edecef59f707e00c6e05d384f5
```

The digest is reproduced in [`docs/GATEWAYS.md § Canonical roster`](../../docs/GATEWAYS.md)
and re-verified on every parity run.

## Shared topology

Kong runs in **DB-less declarative mode** (`KONG_DATABASE: off`,
`KONG_DECLARATIVE_CONFIG: /kong/kong.yml`), so no Postgres / Cassandra
is required. Three things are mounted into the gateway container at
boot:

- `./${GATEWAY_PROFILE}/kong.yml`
  → `/kong/kong.yml`
  (per-profile declarative config: `_format_version`, services,
  routes, plugins, optional `consumers` / `jwt_secrets`).
- [`_shared/lualib/`](./_shared/lualib/)
  → `/usr/local/kong/custom:ro`
  (shared Lua modules; `body_rewrite.lua` powers p09 / p10 / p11.
  Picked up via `KONG_LUA_PACKAGE_PATH=/usr/local/kong/custom/?.lua;;`).
- [`_shared/bench-start.sh`](./_shared/bench-start.sh)
  → `/bench/bench-start.sh:ro`
  (custom entrypoint shim; pre-patches Kong's nginx template — see
  next section).

Other Kong defaults that matter for the matrix
(set in [`docker-compose.yaml`](./docker-compose.yaml)):

- `KONG_PROXY_LISTEN: 0.0.0.0:9080 reuseport backlog=16384` — bench
  standard data-plane port.
- `KONG_ADMIN_LISTEN: off`, `KONG_STATUS_LISTEN: off` — parity is
  100% declarative; the Admin API is never touched.
- `KONG_HEADERS: off` — silences kong's own `Server: kong/3.9.1` and
  `Via: 1.1 kong/3.9.1` stamps. The upstream `Server` (from go-httpbin)
  still survives and is the one p08/p11 strip via `response-transformer`.
- `KONG_TRUSTED_IPS: 0.0.0.0/0,::/0`, `KONG_REAL_IP_HEADER: X-Real-IP`,
  `KONG_REAL_IP_RECURSIVE: on` — p05/p06 key on the `X-Real-IP` header
  the loadgen sends; same trust posture as the apisix and traefik
  columns.
- `KONG_UNTRUSTED_LUA: sandbox`,
  `KONG_UNTRUSTED_LUA_SANDBOX_REQUIRES: body_rewrite` — keeps the
  `pre-function` / `post-function` Lua sandbox engaged, but
  whitelists exactly one shared module
  (`_shared/lualib/body_rewrite.lua`). We deliberately do NOT use
  `KONG_UNTRUSTED_LUA: on` (which removes the sandbox entirely).

Swapping a profile is a container restart away — no Admin API call.

## Shared custom entrypoint (`_shared/bench-start.sh`)

Kong's nginx template
(`/usr/local/share/lua/5.1/kong/templates/nginx_kong.lua`) hard-codes
the upstream X-Forwarded-For source:

```nginx
proxy_set_header X-Forwarded-For $upstream_x_forwarded_for;
```

…and `runloop.access.after()` writes `$upstream_x_forwarded_for` AFTER
all access-phase plugins have run. That means a plugin trying to drop
the header via `request-transformer.remove`,
`kong.service.request.clear_header()`, or `ngx.req.clear_header()`
**always loses** to Kong's later write. p08-req-headers and the
composed p12-full-pipeline both need the header gone.

Fix: [`_shared/bench-start.sh`](./_shared/bench-start.sh) wraps the
stock `/entrypoint.sh`. Before delegating, it `sed`s the kong template
in three minimal, idempotent steps:

1. Adds `set $bench_xff '__BENCH_XFF_DEFAULT__';` next to every
   existing `set $upstream_x_forwarded_for ''` initializer (in both
   the `location /` and `@unbuffered` blocks, plus `@grpc` for
   symmetry).
2. Re-routes the six `proxy_set_header X-Forwarded-For` (and one
   `grpc_set_header`) directives from `$upstream_x_forwarded_for` to
   our writable `$bench_xff`.
3. Adds a one-line shim inside `access_by_lua_block`:

   ```lua
   Kong.access()
   if ngx.var.bench_xff == "__BENCH_XFF_DEFAULT__" then
     ngx.var.bench_xff = ngx.var.upstream_x_forwarded_for or ""
   end
   ```

   The sentinel lets us tell apart "profile didn't touch the
   variable" (=> mirror Kong's default XFF; observable behaviour
   unchanged) from "profile explicitly set it to empty string"
   (=> drop the header). Empty `proxy_set_header` value tells nginx
   not to send the header at all.

Any `pre-function.access` chunk can then opt in with
`ngx.var.bench_xff = ""`. The sed is guarded by needle-presence
checks and is safe to re-run on the same image (no-op on second
invocation).

This is the Kong analogue of the APISIX `bench-start.sh` shim
(see [`gateways/apisix/_shared/bench-start.sh`](../apisix/_shared/bench-start.sh)) —
both columns hit the same architectural limitation (the gateway's
own runloop stamps XFF after plugins run) and both fix it by
re-routing the proxy header through a plugin-controllable variable.

## Lua sandbox whitelist (`KONG_UNTRUSTED_LUA_SANDBOX_REQUIRES`)

Kong's `pre-function` / `post-function` plugins run user Lua inside
a sandbox derived from `kong/tools/kong-lua-sandbox.lua`. The sandbox
blocks arbitrary `require()` by default ("require 'X' not allowed
within sandbox"). p09 / p10 / p11 need `require("body_rewrite")` to
pull in the shared JSON-shape-aware editor from
`_shared/lualib/body_rewrite.lua`.

We keep the sandbox engaged (`KONG_UNTRUSTED_LUA: sandbox`) and
whitelist exactly one module:

```yaml
KONG_UNTRUSTED_LUA: "sandbox"
KONG_UNTRUSTED_LUA_SANDBOX_REQUIRES: "body_rewrite"
```

Trade-off: the alternative `KONG_UNTRUSTED_LUA: on` removes the
sandbox entirely. The whitelist option preserves "principle of least
privilege" — only the single, audited 80-line module under
`_shared/lualib/` can be `require`d from a `kong.yml`.

## Running a profile

```bash
# One profile, end-to-end:
make parity-gateway PARITY_GATEWAY=kong PARITY_PROFILE=p01-vanilla

# All profiles, end-to-end:
make parity-gateway-all PARITY_GATEWAY=kong
```

Both commands bring the stack up, run the profile's `setup.sh` smoke,
then drive `scripts/parity-attestation.sh` against the canonical
fixture; the stack is torn down regardless of pass/fail. Reports land
under `reports/<UTC-timestamp>/parity/kong-<profile>.json`.

## Landed deviations

See [`docs/GATEWAYS.md § Deviations`](../../docs/GATEWAYS.md#deviations):

- `[gw=kong, p=p08-req-headers / p12-full-pipeline,
  infra=nginx-template-xff-patch]` — pre-prepare `sed` patch in
  `_shared/bench-start.sh` re-routes `X-Forwarded-For` through a
  writable `$bench_xff` (sentinel-gated default) so a `pre-function`
  plugin can suppress it. Required because Kong's runloop stamps
  `$upstream_x_forwarded_for` AFTER all access-phase plugins run.
- `[gw=kong, p=p10-req-body / p11-resp-body / p12-full-pipeline,
  infra=untrusted-lua-sandbox-whitelist]` — `KONG_UNTRUSTED_LUA: sandbox`
  is preserved; the shared `body_rewrite` module is added to
  `KONG_UNTRUSTED_LUA_SANDBOX_REQUIRES` instead of disabling the
  sandbox wholesale.
- `[gw=kong, p=p11-resp-body / p12-full-pipeline,
  infra=post-function-content-length-drop]` — `post-function.body_filter`
  changes the response payload length but Kong's PDK does NOT
  auto-strip Content-Length the way vanilla nginx's `body_filter` does.
  We add a `post-function.header_filter` chunk that does
  `ngx.header["Content-Length"] = nil`, which makes nginx fall back to
  `Transfer-Encoding: chunked`.

## Plugin budget under Kong DB-less

Kong allows multiple plugins per route/service, with deterministic
priority-based ordering. Higher priority runs first within each
phase; `pre-function` (priority `+1000000`) runs first,
`post-function` (priority `-1000`) runs last. Stock plugin priorities
that matter for `p11`:

| Plugin                  | Priority | Phase used in `p11`              |
|-------------------------|----------|----------------------------------|
| `pre-function`          | +1000000 | `access` (XFF drop + body rewrite) |
| `jwt`                   | 1450     | `access` (validate)              |
| `rate-limiting`         | 901      | `access` (count)                 |
| `request-transformer`   | 800      | `access` (add X-Bench-In)        |
| `response-transformer`  | 800      | `header_filter` (X-Bench-Out, drop Server) |
| `post-function`         | -1000    | `header_filter`+`body_filter` (Content-Length, body) |

Within `p11` the chain is therefore:

```
[access]        pre-function -> jwt -> rate-limiting -> request-transformer
[upstream]      proxy_pass to backend:8080
[header_filter] response-transformer -> post-function (Content-Length nil)
[body_filter]   post-function (rewrite_response_if_json)
```

Ordering note: `pre-function` running BEFORE `jwt` means a rejected
request still gets its body rewritten in the gateway (no extra
upstream traffic, just wasted CPU on the gateway side). The bench
`p11.setup.sh` smoke verifies the 401 paths still 401; the bursts
in the fixture verify rate-limiting and parity for the chained 200
path.

[kong]: https://konghq.com/kong/
