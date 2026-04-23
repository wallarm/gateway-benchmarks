# envoy / p10-req-body

Request-body transform: inject `$.bench.injected = true`, drop
`$.secret`. Landed via the `envoy.filters.http.buffer` filter in
front of `envoy.filters.http.lua`. First envoy cell in the core
matrix to need our pure-Lua shared library.

## Canonical contract

* `docs/POLICIES.md § p09` — request-body transforms.
* `fixtures/p10-req-body.jsonl`:

  | Probe | Expect |
  | --- | --- |
  | `POST /anything` with `{msg, secret, bench.from_client}` | 200 + backend sees `bench.injected=true` + `bench.from_client=true` + `msg=hello`, but NOT `secret` |
  | `POST /anything` with `{}` | 200 + backend sees `bench.injected=true` (rewrite works on empty body) |
  | `POST /anything` with `{secret,msg}` | 200 + no `secret`, correct Content-Length (envoy recomputes) |

Verdict: **PASS (3/3)**.

## Envoy primitive

Filter chain order matters. The HCM ingests:

```
envoy.filters.http.buffer    (buffers the full request body in RAM)
envoy.filters.http.lua       (envoy_on_request: read body, rewrite, setBytes)
envoy.filters.http.router    (forwards to backend_cluster)
```

### Why the Buffer filter

Envoy streams request bodies by default. If the Lua filter runs
first and calls `request_handle:body()`, it gets `nil` (or only the
first chunk the HCM had when `envoy_on_request` fired). Inserting
`envoy.filters.http.buffer` with `max_request_bytes: 1048576`
forces the HCM to accumulate the full body before the Lua filter's
`envoy_on_request` is called. This is the documented pattern for
request-body manipulation — see the "Body manipulation" paragraph
in the Lua filter docs.

The 1 MiB cap matches nginx's `client_max_body_size 1m;` on the
sibling column so both cells reject the same "too large" requests
with the same 413 semantics (envoy emits
`PayloadTooLarge` / 413 when the limit is exceeded).

### How `setBytes` recomputes Content-Length

Calling `request_handle:body():setBytes(new)` replaces the buffered
request body with `new`. Envoy then updates `Content-Length` on the
upstream-bound request automatically — the Lua filter does NOT need
to touch the header. This matches the nginx column's
`ngx.req.set_body_data()` behaviour (nginx patches the length the
same way).

### Lua source layout

```
/etc/envoy/lualib/
├── base64.lua        (unused here, loaded for parity with p02/p11)
├── sha256.lua        (unused here, loaded for parity with p02/p11)
├── json.lua          (pure-Lua JSON; decode request body, encode back)
├── jwt_hs256.lua     (unused here, loaded for parity with p02/p11)
└── body_rewrite.lua  (top-level entry for this profile)
```

The docker-compose `_shared/lualib` bind-mount is shared across
every envoy profile, so future profiles can reuse the same path.
Only this profile's `require("body_rewrite")` is needed at runtime;
the others ride along silently on disk.

The inline code adjusts `package.path` once at filter load time,
then calls `require`. We verified empirically that Envoy's Lua
filter supports `require` + `package.path` — there is no
special-purpose sandbox disabling those primitives.

## Parity delta vs sibling columns

| Cell | Primitive |
| --- | --- |
| `nginx/p10-req-body` | `access_by_lua_block` + `ngx.req.read_body()` + `ngx.req.set_body_data(new)` (OpenResty bundles cjson; body_rewrite uses it directly) |
| `envoy/p10-req-body` | `envoy.filters.http.buffer` + `envoy.filters.http.lua` + pure-Lua `json` + `body_rewrite`  (Envoy does not bundle cjson; we ship our own) |
| `wallarm/p10-req-body` | `request_flow` with `lua_runner` directive on the request body |

The three cells produce byte-identical echoed bodies on the
canonical fixture.

## Deviations

None. The Content-Type normalisation (`content-type: application/json`
on the upstream-bound request) matches what the nginx column does
via `ngx.req.set_header("Content-Type", "application/json")`. Go-
httpbin uses this header to decide whether to echo the body under
`$.json` (parsed) or `$.data` (raw); the canonical fixture asserts
on `$.json.*` paths, so we force the type explicitly on both columns.

## Files

* `envoy.yaml` — p01-vanilla base + buffer + Lua filter (inline
  source calls `body_rewrite.rewrite_request`).
* `setup.sh` — two POST probes exercising the inject + drop path
  and the empty-body path.
* `NOTES.md` — this file.
