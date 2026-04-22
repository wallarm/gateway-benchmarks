# `nginx / p08-req-body` — notes

Canonical spec — [`docs/POLICIES.md § p08`](../../../docs/POLICIES.md):

```
add:    $.bench.injected = true
remove: $.secret
```

## Image

**OpenResty** — same pin as p02/p07/p09/p10 (see [`./.env`](./.env)).
Request-body rewrite needs `ngx.req.read_body` +
`ngx.req.set_body_data` + `cjson.safe`, all of which live in
`ngx_http_lua_module` (OpenResty only; mainline has neither).

## What we ship

The transform runs in `access_by_lua_block` just after the client
finishes uploading:

```lua
ngx.req.read_body()
local raw = ngx.req.get_body_data()
local new_body = bench_body.rewrite_request(
    raw or "",
    { "bench", "injected" }, true,
    { "secret" }
)
ngx.req.set_body_data(new_body)
ngx.req.set_header("Content-Type", "application/json")
```

Three invariants to point out:

- `ngx.req.set_body_data()` **automatically recomputes
  `Content-Length`** on the upstream-bound request — per the
  openresty/lua-nginx-module README (§ngx.req.set_body_data). That
  is why the fixture's "Content-Length is correct after rewrite"
  probe passes without us touching headers explicitly.
- An empty / non-JSON client body is coerced to `{}` inside
  `body_rewrite.lua` so the `inject` invariant
  (`$.bench.injected == true`) still holds. Probe 2 of
  [`fixtures/p08-req-body.jsonl`](../../../fixtures/p08-req-body.jsonl)
  (empty body) exercises this path.
- `Content-Type` is stamped as `application/json` after rewrite
  because the re-encoded body is always JSON; a client that
  forgot the header would otherwise confuse go-httpbin's
  `$.json` vs `$.data` echo split.

Shared helper: [`gateways/nginx/_shared/lualib/body_rewrite.lua`](../_shared/lualib/body_rewrite.lua).
The same module backs p09-resp-body and p10-full-pipeline, which
keeps the "add $.bench.injected" wording aligned across the three
body-transform profiles.

## Parity result

```
==> parity: gateway=nginx profile=p08-req-body target=http://localhost:9080
    fixture: fixtures/p08-req-body.jsonl
  ✓ PASS   gateway injects $.bench.injected and drops $.secret
  ✓ PASS   rewrite works with empty body object
  ✓ PASS   Content-Length is correct after rewrite
verdict: PASS  (3/3)
```
