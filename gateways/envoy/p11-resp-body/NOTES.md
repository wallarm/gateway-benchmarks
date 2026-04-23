# envoy / p11-resp-body

Response-body transform: inject `$.bench.injected = true`, drop
`$.origin`. Single `envoy.filters.http.lua` filter. Unlike the
request-body profile (p09), response-body buffering is implicit —
calling `response_handle:body()` triggers envoy's buffering
automatically, so no Buffer filter is needed.

## Canonical contract

* `docs/POLICIES.md § p10` — response-body transforms.
* `fixtures/p11-resp-body.jsonl`:

  | Probe | Expect |
  | --- | --- |
  | `GET /anything` | 200 + `$.bench.injected=true`, `$.method=GET`, no `$.origin` |
  | `GET /anything?q=hello` | 200 + `$.bench.injected=true`, `$.args.q=hello`, no `$.origin` |
  | `POST /anything` with `{msg:bench}` | 200 + `$.bench.injected=true`, `$.json.msg=bench`, no `$.origin` |

Verdict: **PASS (3/3)**.

## Envoy primitive

Simple filter chain:

```
envoy.filters.http.lua       (envoy_on_response: read body, rewrite, setBytes)
envoy.filters.http.router    (no-op; runs upstream fetch)
```

### Why no Buffer filter on the response side

The envoy Lua filter's `response_handle:body()` has a different
semantics from `request_handle:body()`:

* **Request side** — returns `nil` unless an upstream filter
  buffered the body in advance. Requires an explicit
  `envoy.filters.http.buffer` before the Lua filter (see p09).
* **Response side** — the Lua filter buffers automatically the
  first time `body()` is called in `envoy_on_response`. No
  extra filter is needed.

This asymmetry is documented in the envoy v1.32 Lua filter config
reference ("response body manipulation" section). It simplifies
p10 vs p09 by one filter.

### How `setBytes` recomputes Content-Length

On the response side, `buf:setBytes(new)` replaces the buffered
body, and envoy recomputes Content-Length on the downstream-bound
response before it hits the wire. The Lua filter does NOT need to
touch the `content-length` header (compare with the nginx column,
which must explicitly `ngx.header.content_length = nil` in
`header_filter_by_lua_block` and then emit chunks — OpenResty's
API does not patch the length when the body is rewritten).

### `rewrite_response_if_json` passthrough

`body_rewrite.rewrite_response_if_json` returns the original body
verbatim whenever the upstream response is not well-formed JSON
(HTML error pages, streamed binary, empty bodies). In that case
our inline filter compares the new value against the original and
skips the `setBytes` call entirely so the buffer is not touched.
This matches the wallarm cell's behaviour and the nginx
column's `rewrite_response_if_json` early-return.

## Parity delta vs sibling columns

| Cell | Primitive |
| --- | --- |
| `nginx/p11-resp-body` | `header_filter_by_lua_block` (clear Content-Length) + `body_filter_by_lua_block` (accumulate chunks, rewrite on EOF) |
| `envoy/p11-resp-body` | `envoy.filters.http.lua` single `envoy_on_response` (body() auto-buffers; setBytes recomputes Content-Length) |
| `wallarm/p11-resp-body` | `response_flow` with `lua_runner` on the response body |

Envoy's API is the most compact of the three — one callback, one
`setBytes`, no header plumbing. The nginx column's two-phase
`header_filter` + `body_filter` pattern exists because OpenResty
exposes the raw chunk/EOF primitives and does not buffer by
default; envoy's Lua filter wraps the same mechanics behind a
synchronous `body()` call.

## Deviations

None. Direct mapping of the canonical policy.

## Files

* `envoy.yaml` — p01-vanilla base + Lua filter (inline source
  calls `body_rewrite.rewrite_response_if_json`).
* `setup.sh` — GET and POST probes asserting `bench.injected`
  added + `origin` dropped on both paths.
* `NOTES.md` — this file.
