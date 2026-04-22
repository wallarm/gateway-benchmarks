# `nginx / p01-vanilla` — compliance notes

**Current verdict on `nginx:1.27.3-alpine`**: `PASS (4/4)`.

## Scope

Plain reverse proxy with no policy in front. The profile is intended
as the baseline comparison point for every other nginx cell — if p01
does something weird, every downstream profile inherits the drift.

## How each fixture probe is satisfied

| Probe                                         | nginx mechanism                                             |
|-----------------------------------------------|-------------------------------------------------------------|
| `GET /status/200 → 200`                       | `proxy_pass http://backend_pool;` — backend's `/status/200` handler returns 200. |
| `GET /anything → 200 + $.method=GET`          | same catch-all pass-through; backend echoes the method.     |
| `POST /anything → 200 + $.json.hello=bench`   | `proxy_request_buffering off` + `proxy_set_header Content-Length` implicit. |
| `GET /bytes/1024 → 200 + Content-Length`      | backend sets `Content-Length`; `proxy_buffering off` forwards it verbatim. |

No path rewriting, no body manipulation, no header munging — the
profile is the empty gateway. That also means `proxy_pass
http://backend_pool;` is intentionally written **without** a trailing
URI, so nginx preserves the client URI unchanged (per
<http://nginx.org/en/docs/http/ngx_http_proxy_module.html#proxy_pass>).

## Uniform-settings audit

Cross-ref to [`docs/GATEWAYS.md § Uniform settings`](../../../docs/GATEWAYS.md#uniform-settings):

| Row                             | `nginx.conf` directive                                        |
|---------------------------------|---------------------------------------------------------------|
| HTTP/1.1 only downstream        | `listen 9080 reuseport;` — no `http2`, no `quic`              |
| HTTP/1.1 only upstream          | `proxy_http_version 1.1; proxy_set_header Connection "";`     |
| Request body buffering off      | `proxy_request_buffering off;`                                |
| Response body buffering off     | `proxy_buffering off;`                                        |
| Upstream pool 1024 idle         | `upstream backend_pool { keepalive 1024; keepalive_time 1h; }` |
| Downstream keep-alive on        | `keepalive_timeout 60s; keepalive_requests 100000;`           |
| Worker concurrency 1/core       | `worker_processes auto;`                                      |
| Access logging off              | `access_log off;` at `http {}` level                          |
| Admin / metrics off on :9080    | no `/nginx_status`, no `stub_status`, no `/metrics`           |
| Request timeout 10 s            | `proxy_connect_timeout / send_timeout / read_timeout 10s;`    |

All ten rows verbatim — no deviations for p01.

## Deliberate non-defaults

* `worker_connections 16384;` — the alpine image defaults to 1024 which
  is too tight for the 1200-rps burst probe that later profiles
  (`p03`, `p05`) fire; keep the same value across all nginx profiles
  to avoid "fixed in p01, broken in p05" surprises.
* `tcp_nodelay on; tcp_nopush off; sendfile on;` — nginx's own
  defaults for modern production use; called out explicitly so the
  `docs/GATEWAYS.md` audit is a simple grep.
* `error_log /dev/stderr warn;` — keep the signal : noise ratio
  reasonable in `docker compose logs`. `notice`-level would clutter
  the run log with "using the SO_REUSEPORT socket" banners on every
  worker.

## Not-yet-exercised

* HTTP/1.1 enforcement probe (see
  [`docs/GATEWAYS.md § HTTP/1.1 enforcement per gateway`](../../../docs/GATEWAYS.md#http11-enforcement-per-gateway))
  is planned for the parity harness but not yet part of `p01-vanilla`.
  The listener is already HTTP/1.1-only, so when that probe lands the
  cell will continue to pass without changes.
* `tcp_keepalive_time` on the downstream socket is not directly
  expressible in nginx; the kernel default (TCP keep-alive on, 2 h
  idle) applies. This is equivalent to every other gateway's
  "downstream keep-alive on" row and is noted here only for
  completeness.

Tracking: [`docs/GATEWAYS.md § Deviations`](../../../docs/GATEWAYS.md#deviations).
