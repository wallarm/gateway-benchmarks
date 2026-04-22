# nginx

Per-profile configurations for nginx (open-source), used as one of
the baseline gateways in the benchmark. nginx has **no admin API** —
every profile is expressed as a complete `nginx.conf` on disk,
mounted read-only by the compose stack.

## Pinned version

| Field          | Value |
|----------------|-------|
| Version        | `1.27.3` |
| Docker image   | `nginx:1.27.3-alpine` |
| Digest         | `sha256:814a8e88df978ade80e584cc5b333144b9372a8e3c98872d07137dbf3b44d0e4` |
| Architecture   | multi-arch (`linux/amd64`, `linux/arm64/v8`; resolves natively) |
| Language       | C |
| Source         | [`_/nginx`](https://hub.docker.com/_/nginx) (official Docker Hub) |
| Documentation  | [nginx.org](https://nginx.org/en/docs/) |

Refresh the digest with:

```bash
docker pull nginx:1.27.3-alpine
docker image inspect nginx:1.27.3-alpine \
    --format '{{index .RepoDigests 0}}'
```

## Image family rationale

* **`1.27.3`** — the most recent mainline release at the time of
  pinning. We use mainline (not `stable`) because newer RL /
  body-streaming behaviour matters for `p03..p09` and stable trails
  mainline by several months.
* **`-alpine`** — smaller image, faster container churn during the
  parity sweep. Every Linux-side benchmark run (Phase 4) will verify
  that the same digest runs under `--platform linux/amd64` on EC2.
* **Not `-perl`, not `-otel`** — we don't ship Perl modules or the
  OpenTelemetry bolt-on. Lua-based profiles (`p02-jwt`, `p08-req-body`,
  `p09-resp-body`, `p10-full-pipeline`) switch to
  `openresty/openresty:<pinned>` instead of bundling `ngx_http_lua`
  here, which is the
  [recommendation in docs/POLICIES.md](../../docs/POLICIES.md#feature-availability-matrix).

## Layout

```
gateways/nginx/
├── README.md                  (this file)
├── docker-compose.yaml        (nginx + backend on bench-net, image via ${GATEWAY_IMAGE})
├── _shared/
│   └── lualib/                (mounted read-only at /usr/local/openresty/lualib/bench/)
│       ├── jwt_hs256.lua      (~60-line pure-Lua HS256 verifier)
│       └── body_rewrite.lua   (cjson-based JSON inject/drop helpers)
├── p01-vanilla/               (mainline)
│   ├── nginx.conf             (full config, HTTP/1.1 only, catch-all proxy)
│   ├── setup.sh               (post-up smoke check; nginx has no admin API)
│   └── NOTES.md               (uniform-settings audit, deviations)
├── p02-jwt/                   (openresty — ngx_http_lua, resty.sha256, cjson.safe)
│   ├── .env                   (pin openresty:1.27.1.2-alpine)
│   ├── nginx.conf             (access_by_lua_block → jwt_hs256.verify)
│   ├── setup.sh               (smoke: missing-auth=401, fresh-token=200)
│   └── NOTES.md               (why no lua-resty-jwt; user nobody;)
├── p03-rl-static/             (mainline)
│   ├── nginx.conf             (+limit_req_zone $server_name / burst=200)
│   ├── setup.sh               (post-up smoke; burst handled by parity runner)
│   └── NOTES.md               (mechanism, burst shape, deviations)
├── p04-rl-dynamic-low/        (mainline)
│   ├── nginx.conf             (+limit_req_zone $http_x_real_ip / rate=10r/s)
│   ├── setup.sh               (post-up smoke with X-Real-IP header)
│   └── NOTES.md               (wallarm symmetry, burst tuning rationale)
├── p05-rl-dynamic-high/       (mainline)
│   ├── nginx.conf             (+zone=10m for 50k-IP pool / rate=100r/s)
│   ├── setup.sh               (post-up smoke with X-Real-IP header)
│   └── NOTES.md               (zone-sizing derivation, burst shape, deviations)
├── p06-req-headers/           (mainline)
│   ├── nginx.conf             (mainline: proxy_set_header X-Bench-In / X-Forwarded-For "")
│   ├── setup.sh               (post-up smoke: inject + drop side-effects)
│   └── NOTES.md               (mainline idioms, cross-gateway symmetry)
├── p07-resp-headers/          (openresty — ngx_headers_more)
│   ├── .env                   (pin openresty:1.27.1.2-alpine)
│   ├── nginx.conf             (openresty: add_header + more_clear_headers "Server")
│   ├── setup.sh               (post-up smoke: HEAD /get verifies headers)
│   └── NOTES.md               (why openresty, three-layer Server drop)
├── p08-req-body/              (openresty — ngx.req.read_body + set_body_data)
│   ├── .env                   (pin openresty:1.27.1.2-alpine)
│   ├── nginx.conf             (access_by_lua_block → body_rewrite.rewrite_request)
│   ├── setup.sh               (post-up smoke: $.json.bench.injected, $.secret dropped)
│   └── NOTES.md               (Content-Length auto-patch; wallarm symmetry)
├── p09-resp-body/             (openresty — header_filter_by_lua + body_filter_by_lua)
│   ├── .env                   (pin openresty:1.27.1.2-alpine)
│   ├── nginx.conf             (clear Content-Length, buffer chunks, rewrite on EOF)
│   ├── setup.sh               (post-up smoke: $.bench.injected, $.origin dropped)
│   └── NOTES.md               (two-phase pattern; non-JSON pass-through)
└── p10-full-pipeline/         (openresty — composes p02+p03+p06+p07+p08+p09)
    ├── .env                   (pin openresty:1.27.1.2-alpine)
    ├── nginx.conf             (chained: limit_req → jwt → req-body → proxy → resp-hdr/body)
    ├── setup.sh               (smoke: end-to-end transforms on a single POST)
    └── NOTES.md               (phase ordering; why it's the first green p10 in the matrix)
```

### Per-profile image overrides

`gateways/nginx/docker-compose.yaml` reads the gateway image from
the `GATEWAY_IMAGE` environment variable with the mainline alpine
digest as the default. A profile that needs a different image
drops a one-line `.env` file next to its `nginx.conf`:

```
GATEWAY_IMAGE=openresty/openresty:1.27.1.2-alpine@sha256:...
```

`scripts/parity-gateway.sh` passes that `.env` to `docker compose`
via `--env-file` so the override is strictly scoped to the compose
invocation and never leaks into the parent shell (important for
full sweeps that alternate between mainline and openresty profiles).
Profiles that rely on the OpenResty pin today: `p02-jwt`,
`p07-resp-headers`, `p08-req-body`, `p09-resp-body`,
`p10-full-pipeline`.

### Shared Lua library

`gateways/nginx/_shared/lualib/` is bind-mounted at
`/usr/local/openresty/lualib/bench/` by
[`docker-compose.yaml`](./docker-compose.yaml). OpenResty profiles
pick it up via `lua_package_path "/usr/local/openresty/lualib/bench/?.lua;;";`.
Mainline images (p01/p03/p04/p05/p06) ignore the mount — no
`lua_package_path`, no lua_module compiled in.

Two modules live there:

| Module             | Purpose                                                              | Consumers            |
|--------------------|----------------------------------------------------------------------|----------------------|
| `jwt_hs256.lua`    | ~60-line HS256 verifier — HMAC-SHA-256 via `resty.sha256`            | p02, p10             |
| `body_rewrite.lua` | `cjson.safe` inject/drop helpers for request & response bodies       | p08, p09, p10        |

## Feature matrix

| Profile                 | Primitive                                                | Parity            |
|-------------------------|----------------------------------------------------------|-------------------|
| `p01-vanilla`           | Catch-all `proxy_pass http://backend_pool`               | PASS (4/4)        |
| `p02-jwt`               | `access_by_lua_block` + inline HS256 on OpenResty        | PASS (6/6)        |
| `p03-rl-static`         | `limit_req_zone $server_name` + `burst=200 nodelay`      | PASS (2/2)        |
| `p04-rl-dynamic-low`    | `limit_req_zone $http_x_real_ip rate=10r/s` + `burst=10` | PASS (2/2)        |
| `p05-rl-dynamic-high`   | same + `zone=10m rate=100r/s` + `burst=20` (50k-IP pool) | PASS (3/3)        |
| `p06-req-headers`       | mainline `proxy_set_header` (inject) + empty-value drop  | PASS (3/3)        |
| `p07-resp-headers`      | openresty `add_header` + `more_clear_headers "Server"`   | PASS (2/2)        |
| `p08-req-body`          | openresty `ngx.req.set_body_data` + `cjson.safe`         | PASS (3/3)        |
| `p09-resp-body`         | openresty `body_filter_by_lua_block` + `cjson.safe`      | PASS (3/3)        |
| `p10-full-pipeline`     | openresty, composes p02+p03+p06+p07+p08+p09              | PASS (4/4)        |

`PASS` entries reflect the latest run of
`make parity-gateway-all PARITY_GATEWAY=nginx` — **10/10 PASS,
32/32 probes** against `nginx:1.27.3-alpine` (mainline) +
`openresty:1.27.1.2-alpine` (Lua profiles). See each profile's
`NOTES.md` and [`docs/GATEWAYS.md § Deviations`](../../docs/GATEWAYS.md#deviations)
for the per-cell rationale.

## Uniform settings enforcement

This gateway's declared settings versus the uniform values from
[`docs/GATEWAYS.md`](../../docs/GATEWAYS.md):

| Row                             | Uniform value                 | `nginx` setting                                      |
|---------------------------------|-------------------------------|------------------------------------------------------|
| HTTP/1.1 only downstream        | HTTP/1.1 only                 | `listen 9080 reuseport;` (no `http2`, no `quic`)     |
| HTTP/1.1 only upstream          | HTTP/1.1 only                 | `proxy_http_version 1.1; proxy_set_header Connection "";` |
| Upstream pool size              | 1024                          | `upstream backend_pool { keepalive 1024; }`          |
| Pool idle timeout               | 60 s                          | `keepalive_timeout 60s; keepalive_time 1h;`          |
| TCP keep-alive                  | on                            | kernel default on the downstream socket              |
| TCP nodelay                     | on                            | `tcp_nodelay on;`                                    |
| Downstream keep-alive           | on                            | `keepalive_timeout 60s;` + `keepalive_requests 100000;` |
| Access logging on hot path      | off                           | `access_log off;`                                    |
| Admin / data plane separation   | n/a                           | nginx has no admin API; only :9080 data plane        |
| Request buffering               | off                           | `proxy_request_buffering off;`                       |
| Response buffering              | off                           | `proxy_buffering off;`                               |
| Request timeout                 | 10 s                          | `proxy_connect/send/read_timeout 10s;`               |

Anything that later deviates goes into the matching profile's
`NOTES.md` and into
[`docs/GATEWAYS.md § Deviations`](../../docs/GATEWAYS.md#deviations).

## Running parity

```bash
# One profile end-to-end (bring up, smoke, parity, tear down):
make parity-gateway \
    PARITY_GATEWAY=nginx \
    PARITY_PROFILE=p01-vanilla

# All 10 profiles end-to-end (also runs the planned FEATURE-MISSING
# cells once those are landed):
make parity-gateway-all PARITY_GATEWAY=nginx
```

See [`../../Makefile`](../../Makefile) for the full list of targets
and variables.
