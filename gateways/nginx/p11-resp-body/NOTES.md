# `nginx / p11-resp-body` — notes

Canonical spec — [`docs/POLICIES.md § p10`](../../../docs/POLICIES.md):

```
add:    $.bench.injected = true
remove: $.origin
```

## Image

**OpenResty** — same pin as p02/p08/p09/p11 (see [`./.env`](./.env)).
Response-body rewrite needs `header_filter_by_lua_block` +
`body_filter_by_lua_block` + `cjson.safe` from
`ngx_http_lua_module`.

## What we ship

The canonical two-phase OpenResty pattern (documented in the
`lua-nginx-module` README, and used by every OpenResty-based API
gateway we could find: Kong, APISIX, 3scale, …):

1. `header_filter_by_lua_block` clears `Content-Length`. Upstream
   just handed us N bytes, but the rewrite is about to change N.
   Clearing the length makes nginx emit `Transfer-Encoding: chunked`
   automatically on HTTP/1.1, which is the only framing that lets
   us stream a different length downstream.
2. `body_filter_by_lua_block` accumulates chunks into
   `ngx.ctx.bench_buf`. On `ngx.arg[2] == true` (the EOF signal),
   the buffer is concatenated, handed to
   [`body_rewrite.rewrite_response_if_json`](../_shared/lualib/body_rewrite.lua),
   and the transformed JSON replaces the final chunk. Intermediate
   chunks are suppressed with `ngx.arg[1] = nil`.

Non-JSON upstream responses (HTML error pages, streamed binary)
pass through untouched — `rewrite_response_if_json` short-circuits
on anything that doesn't decode. That matches the wallarm cell
behaviour
([`gateways/wallarm/p11-resp-body/NOTES.md`](../../wallarm/p11-resp-body/NOTES.md))
and is important for the eventual 5xx probes in later phases: a
gateway that corrupts HTML error pages is a bug, not a feature.

## Deviation — go-httpbin query-arg echo shape

Probe 2 of
[`fixtures/p11-resp-body.jsonl`](../../../fixtures/p11-resp-body.jsonl)
asserts `$.args.q == "hello"`. go-httpbin encodes single-value
query args as one-element arrays (`"args": {"q": ["hello"]}`),
so the harness's `assert_json_contains_value` accepts both scalars
and one-element arrays at the asserted path. This is a
**backend-echo** shape, not an nginx shape — it would surface
identically on every gateway we proxy through go-httpbin.

## Parity result

```
==> parity: gateway=nginx profile=p11-resp-body target=http://localhost:9080
    fixture: fixtures/p11-resp-body.jsonl
  ✓ PASS   gateway adds $.bench.injected and drops $.origin
  ✓ PASS   response-body rewrite preserves other top-level fields
  ✓ PASS   works for POST responses too
verdict: PASS  (3/3)
```
