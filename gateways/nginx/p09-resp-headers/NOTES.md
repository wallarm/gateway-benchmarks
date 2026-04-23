# `nginx / p09-resp-headers` — compliance notes

**Current verdict on `openresty/openresty:1.27.1.2-alpine`** (see
[`.env`](./.env)): `PASS (2/2)`.

This is the **first nginx cell that does NOT run on
`nginx:1.27.3-alpine`**. The image override lives in `./.env`;
`scripts/parity-gateway.sh` sources it automatically before
`docker compose up`. Everything else about the profile — ports,
volumes, setup.sh contract, parity fixture — is identical to the
mainline cells.

## How each fixture probe is satisfied

| Probe                                                           | nginx/openresty mechanism                                           |
|-----------------------------------------------------------------|---------------------------------------------------------------------|
| `GET /response-headers?Server=should-be-dropped` → client sees `X-Bench-Out`, not `Server` | `add_header X-Bench-Out "1" always;` + `proxy_hide_header Server;` + `more_clear_headers "Server";` |
| `GET /get` → same invariants even though the upstream route differs | Same directives — both fire in `server {}` scope regardless of location. |

## Why OpenResty instead of mainline nginx

The `X-Bench-Out: 1` injection is trivial anywhere —
`add_header X-Bench-Out 1 always;` is mainline-compatible.

The **drop** side is where mainline falls short:

| Attempt                                           | Effect on `Server` header                                                                                |
|--------------------------------------------------|----------------------------------------------------------------------------------------------------------|
| *(do nothing)*                                    | nginx emits `Server: nginx/1.27.3` — the header is added by `ngx_http_header_filter_module`.              |
| `server_tokens off;`                              | Hides the version only; `Server: nginx` still leaks.                                                      |
| `proxy_hide_header Server;`                       | Strips `Server` emitted by the upstream; nginx then re-adds its own.                                      |
| `add_header Server "" always;`                    | Leaves an empty `Server:` header on the wire, which still makes `assert_header_absent "Server"` fail.     |
| `more_clear_headers "Server";` (ngx_headers_more) | **Deletes** the name/value pair from the outgoing response. This is what PASSes the fixture.              |

`ngx_headers_more` is a third-party module that is *not* bundled
with stock mainline nginx. OpenResty bundles it by default
(`nginx -V` → `--add-module=../headers-more-nginx-module-0.37`),
so the smallest-possible way to make nginx/p08 pass is to swap
the container image to OpenResty for this one cell. The alternative
— compiling a custom mainline with `ngx_headers_more` — would
defeat reproducibility since no such public pinned image exists.

This is the "Lua*" column that `docs/POLICIES.md § Feature
availability` anticipates for nginx/p08 (the original note said
"Lua\*" to hedge, but headers-more without Lua is a cleaner fit).

## Mechanism

```nginx
# Outermost belt-and-braces — strip whatever the upstream emits.
proxy_hide_header    Server;

# Backup for error paths that bypass the headers-more filter.
server_tokens        off;

server {
    listen 9080 reuseport;
    server_name bench-nginx;

    # Inject X-Bench-Out on every response code (including 4xx/5xx)
    add_header           X-Bench-Out "1" always;

    # Unconditionally delete Server from the outgoing response.
    more_clear_headers   "Server";

    location / {
        proxy_pass http://backend_pool;
    }
}
```

Three layers of defence, each covering a different failure mode:

1. `proxy_hide_header Server;` — strips `Server` from the upstream
   response before any filter runs. Necessary because
   `more_clear_headers` operates on the header table nginx is
   preparing to send, and certain upstream-emitted headers could
   otherwise leak through a conditional path.
2. `server_tokens off;` — suppresses the version substring in
   nginx-generated error pages (the headers-more filter does not
   run on nginx's own 4xx/5xx responses).
3. `more_clear_headers "Server";` — the primary directive that
   actually deletes the `Server` entry from the response header
   table on every served request.

## Uniform-settings audit

Same ten rows as
[`p01-vanilla/NOTES.md`](../p01-vanilla/NOTES.md#uniform-settings-audit).
OpenResty is a strict superset of mainline nginx for these
settings (it tracks the upstream release with extra modules
bundled), so every uniform-settings directive applies unchanged.

## Deliberate non-defaults

* **`user nobody;`** instead of `user nginx;`. OpenResty's alpine
  image does not create a `nginx` system user — only `nobody`
  exists. This is the only docker-image-aware line in the config.
* **`openresty/openresty:1.27.1.2-alpine@sha256:761047d6…`** is
  based on nginx 1.27.1; mainline bench cells run on nginx 1.27.3.
  That one-release delta is documented and accepted — both
  versions belong to the same 1.27 stable line and behave
  identically for every HTTP directive used by this bench.
  When OpenResty ships a 1.27.3-based tag, we update the pin.

## Not-yet-exercised

* `Via`, `X-Powered-By`, and other server-identifying headers —
  `more_clear_headers` takes a list, so `more_clear_headers
  "Server" "Via" "X-Powered-By";` extends trivially. The fixture
  asserts only against `Server` today.
* Error-path 4xx/5xx response shape. The fixture exercises only
  200 responses; the `server_tokens off;` defence-in-depth layer
  is there for symmetry with mainline but not covered by parity.

Tracking: [`docs/GATEWAYS.md § Deviations`](../../../docs/GATEWAYS.md#deviations).
