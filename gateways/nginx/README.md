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
├── docker-compose.yaml        (nginx + backend on bench-net)
└── p01-vanilla/
    ├── nginx.conf             (full config, HTTP/1.1 only, catch-all proxy)
    ├── setup.sh               (post-up smoke check; nginx has no admin API)
    └── NOTES.md               (uniform-settings audit, deviations)
```

(The remaining profiles `p02..p10` land in subsequent Phase 3b iterations.)

## Feature matrix

| Profile                 | Primitive                                         | Parity            |
|-------------------------|---------------------------------------------------|-------------------|
| `p01-vanilla`           | Catch-all `proxy_pass http://backend_pool`        | PASS (4/4)        |
| `p02-jwt`               | `ngx_http_auth_jwt_module` (commercial) or Lua    | planned (openresty) |
| `p03-rl-static`         | `limit_req_zone` — fixed bucket                   | planned           |
| `p04-rl-dynamic-low`    | `limit_req_zone $http_x_real_ip ...`              | planned           |
| `p05-rl-dynamic-high`   | same, higher rate (zone sizing per `docs/POLICIES.md †`) | planned  |
| `p06-req-headers`       | `proxy_set_header` / `more_clear_input_headers`   | planned           |
| `p07-resp-headers`      | `add_header` / `more_clear_headers`               | planned           |
| `p08-req-body`          | `ngx_http_lua_module` (openresty image)           | planned           |
| `p09-resp-body`         | `ngx_http_lua_module` (openresty image)           | planned           |
| `p10-full-pipeline`     | composition of p02…p09 on openresty               | planned           |

`PASS` entries reflect the latest run of
`make parity-gateway-all PARITY_GATEWAY=nginx`. See each profile's
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
