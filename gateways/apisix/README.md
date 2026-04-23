# apisix

Configurations for [Apache APISIX][apisix] covering the 11 policy
profiles defined in [TASK.md §4](../../TASK.md) plus the p03
scenarios from [`docs/POLICIES.md § p03-jwks-rs256-basic`](../../docs/POLICIES.md).

## Roster

| Profile              | Status        | Mechanism                                                                                      |
|----------------------|---------------|------------------------------------------------------------------------------------------------|
| `p01-vanilla`        | **PASS 4/4**  | Single route `/` + `/*`, no plugins; `roundrobin` upstream to `backend:8080`                   |
| `p02-jwt`            | **PASS 6/6**  | `serverless-pre-function` (access) + shared `_shared/lualib/jwt_hs256.lua`                     |
| `p04-rl-static`      | **PASS 2/2**  | `limit-count` service-wide, `key_type: constant`, `count: 1000 / 1 s`, `policy: local`         |
| `p05-rl-endpoint`    | **PASS 4/4**  | Two routes; `limit-count` attached to `/anything/limited` only                                 |
| `p06-rl-dynamic-low` | **PASS 2/2**  | `limit-count`, `key_type: var`, `key: http_x_real_ip`, `count: 10 / 1 s`                       |
| `p07-rl-dynamic-high`| **PASS 3/3**  | Same primitive as p05 at `count: 100 / 1 s`                                                    |
| `p08-req-headers`    | **PASS 3/3**  | `proxy-rewrite.headers.set` inject + serverless XFF drop via `$bench_xff` hook (see below)     |
| `p09-resp-headers`   | **PASS 2/2**  | `response-rewrite.headers.set` inject + `serverless-post-function` (header_filter) Server drop |
| `p10-req-body`       | **PASS 3/3**  | `serverless-pre-function` (access) + shared `_shared/lualib/body_rewrite.lua`                  |
| `p11-resp-body`      | **PASS 3/3**  | `serverless-post-function` (body_filter) chunk accumulator + `body_rewrite.rewrite_response_if_json` |
| `p12-full-pipeline`  | **PASS 4/4**  | `limit-count` + fused `serverless-pre-function` (JWT + body rewrite + XFF) + `response-rewrite` + `serverless-post-function` |

Full sweep verdict: **12 PASS, 0 FAIL, 39/39 probes** on
`apache/apisix:3.15.0-debian`.

### p03-jwks-rs256-basic

| Profile              | Status       | Mechanism                                                                           |
|----------------------|--------------|-------------------------------------------------------------------------------------|
| `p03-jwks-rs256-basic`   | **PASS 3/3** | `openid-connect` plugin + static OIDC discovery sidecar (`nginx:1.27.3-alpine`)     |

## Pinned image

```
apache/apisix:3.15.0-debian
└── sha256:4c201af4f6887def17c22be19e38f64cedf507db8bcc43991089778ad1188b9c
```

The digest is reproduced in [`docs/GATEWAYS.md § Canonical roster`](../../docs/GATEWAYS.md)
and re-verified on every parity run.

## Shared topology

APISIX is deployed in **standalone mode**
(`deployment.role: data_plane` + `role_data_plane.config_provider: yaml`),
so no etcd / Admin API is required. Three files are mounted into the
gateway container at boot:

- [`apisix.standalone.yaml`](./apisix.standalone.yaml)
  → `/usr/local/apisix/conf/config.yaml`
  (shared bootstrap: data listener, plugin allow-list, deployment role,
  `extra_lua_path`, `server_tokens: false`).
- `./${GATEWAY_PROFILE}/apisix.yaml`
  → `/usr/local/apisix/conf/apisix.yaml`
  (per-profile declarative config: routes, upstreams, consumers, plugins).
- [`_shared/lualib/`](./_shared/lualib/)
  → `/usr/local/apisix/conf/bench:ro`
  (shared Lua library reused across profiles: `jwt_hs256.lua`,
  `body_rewrite.lua`; referenced via `apisix.extra_lua_path =
  "/usr/local/apisix/conf/bench/?.lua"`).

Swapping a profile is a container restart away — no Admin API call.

## Shared custom entrypoint (`_shared/bench-start.sh`)

APISIX generates its runtime `nginx.conf` at container start
(`apisix init` inside `/usr/local/apisix/bin/apisix`). The generated
config hard-codes

```nginx
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
```

…and `ngx.var.proxy_add_x_forwarded_for` is **read-only** in Lua,
so `serverless-pre-function` cannot directly suppress the XFF header
that nginx's own HTTP module stamps. We need that capability for
`p08-req-headers` and `p12-full-pipeline`, both of which assert
`backend_missed_header: X-Forwarded-For`.

Fix: [`_shared/bench-start.sh`](./_shared/bench-start.sh) wraps the
stock APISIX entrypoint. After `apisix init` it `sed`s the generated
`nginx.conf` in-place, rerouting `X-Forwarded-For` through a writable
NGINX variable (`$bench_xff`):

```nginx
set                $bench_xff             $proxy_add_x_forwarded_for;
proxy_set_header   X-Forwarded-For        $bench_xff;
```

Any `serverless-pre-function` (access phase) can then set
`ngx.var.bench_xff = ""` to fully suppress the header. The patch is
idempotent and no-ops if APISIX upstream changes the default shape
(guarded by a `grep` of the exact expected line).

This is the APISIX analogue of nginx's
`proxy_set_header X-Forwarded-For ""` idiom and the envoy Lua
`request_handle:headers():remove("x-forwarded-for")` idiom — we end up
at the same semantic through different machinery.

## Shared sidecar (`oidc-server`)

The `docker-compose.yaml` stack always includes a tiny
`nginx:1.27.3-alpine` sidecar bound to the private `bench-net`, which
serves two static endpoints:

- `/.well-known/openid-configuration`
- `/.well-known/jwks.json` (bind-mounted from
  [`gateways/_reference/jwks-rs256/jwks.json`](../_reference/jwks-rs256/README.md))

Motivation lives in the `p03-jwks-rs256-basic` profile:
`openid-connect` requires an OIDC discovery document, not a bare
JWKS URL. Other profiles simply do not send traffic to the sidecar;
it is cheap to keep always-on (~5 MiB) and avoids a bespoke
`docker compose --profile` codepath in `scripts/parity-gateway.sh`.

See [`p03-jwks-rs256-basic/NOTES.md`](./p03-jwks-rs256-basic/NOTES.md) for
the full rationale and the `prometheus`-in-plugin-allow-list quirk
that silences a transitive `syslog` → `prometheus/exporter.lua`
require chain at APISIX worker init.

## Running a profile

```bash
# One profile, end-to-end:
make parity-gateway PARITY_GATEWAY=apisix PARITY_PROFILE=p01-vanilla

# All profiles, end-to-end:
make parity-gateway-all PARITY_GATEWAY=apisix

# p03-jwks-rs256-basic (participates in parity-gateway-all):
make parity-gateway PARITY_GATEWAY=apisix PARITY_PROFILE=p03-jwks-rs256-basic
```

## Landed deviations

See [`docs/GATEWAYS.md § Deviations`](../../docs/GATEWAYS.md#deviations):

- `[gw=apisix, p=p08-req-headers / p12-full-pipeline,
  infra=nginx-conf-xff-patch]` — post-init `sed` patch in
  `_shared/bench-start.sh` reroutes `X-Forwarded-For` through a
  writable `$bench_xff` variable so a `serverless-pre-function` can
  suppress it. Required because APISIX's generated `nginx.conf`
  hard-codes `$proxy_add_x_forwarded_for`, which is read-only in Lua.
- `[gw=apisix, p=p09-resp-headers / p12-full-pipeline,
  infra=ngx-header-server-nil]` —
  `response-rewrite.headers.remove: [Server]` alone does not strip
  OpenResty's `Server` stamp; we pair it with a `serverless-post-function`
  in the `header_filter` phase that does `ngx.header["Server"] = nil`.

## Plugin budget under APISIX standalone

APISIX allows **one instance per plugin per route**, and
`serverless-pre-function` / `serverless-post-function` each resolves
one phase per instance (see
`/usr/local/apisix/apisix/plugins/serverless/init.lua`). `p11`
therefore folds every custom Lua concern into exactly two hooks:

- `serverless-pre-function.phase: access` — JWT verify (p02) + request
  body rewrite (p09) + `$bench_xff` drop (p07).
- `serverless-post-function.phase: body_filter` — response body rewrite (p10).

Header concerns ride on native plugins: `proxy-rewrite.headers.set`
(p07 inject) and `response-rewrite.headers.set / headers.remove` (p08
inject + Server drop prep). The chain is completed by a shared
`serverless-post-function` equivalent in `p08` (header_filter phase)
that's absorbed into p11 by relying on `response-rewrite.headers.remove`
only — see the profile's `apisix.yaml` for the exact layering
rationale.

[apisix]: https://apisix.apache.org/
