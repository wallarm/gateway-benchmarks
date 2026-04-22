# wallarm / p08-req-body — notes

Canonical policy — [`docs/POLICIES.md` §
p08](../../../docs/POLICIES.md):

```
add:    $.bench.injected = true
remove: $.secret
```

## What we ship

Wallarm `0.2.0` (public image) does not expose a dedicated
`body_transform` policy. The built-in policy registry on this tag
is `lua_runner` + `ratelimit` (see
[`admin-api-openapi.yaml` `PolicyBinding.policy_id`](../../../../wallarm-api-gateway/docs/admin-api-openapi.yaml)).

The Lua sandbox provides `cjson.safe` (documented in
[`policy-development-guide.md` §2](../../../../wallarm-api-gateway/docs/policy-development-guide.md))
and read/write access to `ctx.request.body` — the two primitives a
JSON body rewrite needs.

- `policy_id:   "lua_runner"`
- `policy_name: "bench-p08-req-body"`
- `flow:        request_flow` (service level, applied to the
  single catch-all route)
- `config.code:`

  ```lua
  function execute(ctx)
    local cjson = require("cjson.safe")
    local body = ctx.request.body or ""
    local data = cjson.decode(body)
    if type(data) ~= "table" then
      data = {}
    end
    if type(data.bench) ~= "table" then
      data.bench = {}
    end
    data.bench.injected = true
    data.secret = nil
    local new_body = cjson.encode(data)
    ctx.request.body = new_body
    ctx.request.headers["content-length"] = tostring(#new_body)
    return { action = "continue" }
  end
  ```

  Robustness points:

  - Empty / non-JSON bodies are coerced to `{}` so the "add"
    invariant (`$.bench.injected == true`) still holds.
  - `data.bench` is coerced to a table before the field assignment,
    so a non-table upstream value (`"bench": "hi"`) cannot crash
    the policy.
  - `Content-Length` is recomputed; otherwise wallarm forwards the
    new body with the stale header and upstream truncates /
    mis-reads it.

## Deviation: no `Transfer-Encoding` manipulation

Wallarm does not surface chunked framing to Lua, and on this profile
the buffered service already materialised the full request body
before `lua_runner` fired. So the policy only touches
`Content-Length`. This is documented for the cross-gateway parity
matrix in [`docs/GATEWAYS.md`](../../../docs/GATEWAYS.md).

## Parity result

Against `wallarm/api-gateway:0.2.0` (native arch — see qemu gotcha
in [`p06-req-headers/NOTES.md`](../p06-req-headers/NOTES.md)):

```
==> parity: gateway=wallarm profile=p08-req-body target=http://localhost:9080
    fixture: fixtures/p08-req-body.jsonl
  ✓ PASS   gateway injects $.bench.injected and drops $.secret
  ✓ PASS   rewrite works with empty body object
  ✓ PASS   Content-Length is correct after rewrite
verdict: PASS  (3/3)
```
