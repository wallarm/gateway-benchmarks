# wallarm / p09-resp-headers — notes

Canonical policy — [`docs/POLICIES.md` §
p08](../../../docs/POLICIES.md):

```
add:    X-Bench-Out: 1    (to the response)
remove: Server            (from the response)
```

## What we ship

The Wallarm API Gateway does not expose a dedicated
`header_transform` policy. The built-in registry is `lua_runner` +
`ratelimit`. Response-header rewrite is done through `lua_runner`
bound to the service's **`response_flow`** (same idiom as p07, but on
the response side).

- `policy_id:   "lua_runner"`
- `policy_name: "<service>-resp-headers"`  (unique per service)
- `flow:        response_flow`  (service level)
- `config.code:`

  ```lua
  function execute(ctx)
    ctx.response.headers["x-bench-out"] = "1"
    ctx.response.headers["server"]      = nil
    return { action = "continue" }
  end
  ```

Lower-case keys for the case-insensitive `ctx.response.headers` table,
per [`policy-development-guide.md`
§3](../../../../wallarm-api-gateway/docs/policy-development-guide.md).

## Deviation: two services, because the fixture covers two paths

`fixtures/p09-resp-headers.jsonl` exercises two client-facing paths
(`/response-headers` and `/get`). Due to the same base-path strip
quirk documented in `gateways/wallarm/p08-req-headers/NOTES.md`, we
cannot point a single catch-all service at both. The setup script
registers two services:

| client path          | backend target                                   |
|----------------------|--------------------------------------------------|
| `/response-headers`  | `http://backend:8080/anything/response-headers`  |
| `/get`               | `http://backend:8080/anything/get`               |

Both bind the same `lua_runner` code on `response_flow`. Other
gateways (nginx, envoy, kong, apisix, traefik, tyk) that can route
directly to `/response-headers` / `/get` will register a single
listener, not two.

## Deviation: the `Server` removal half is tautological on this backend

`go-httpbin`'s `/anything/*` catch-all does **not** emit a `Server:`
header on responses; only the first-class `/response-headers` endpoint
does, and we cannot reach that one through the Wallarm gateway without
hitting the trailing-slash 404.

That means on this profile:

- the **add** side (`X-Bench-Out: 1`) is verified end-to-end — the
  header only reaches the client if the `response_flow` binding
  actually fired; and
- the **drop** side (`Server:`) is structurally present (the Lua code
  is bound and executed) but the upstream never sets `Server:`, so the
  fixture's `response_header_absent: ["Server"]` probe does not
  exercise the drop logic in anger.

Gateways that can route `/response-headers?Server=dropme` straight to
`go-httpbin` (i.e. every other gateway in this bench) **will** observe
a real upstream `Server: dropme` header and will exercise the drop.
For those, the same fixture is a tight test.

We accept this trade-off because the alternative — routing path
rewriting — would itself require a Lua shim that is harder to audit
than the trivial response-header policy it would support.

## Parity result

Against native the Wallarm API Gateway (see
[`p08-req-headers/NOTES.md`](../p08-req-headers/NOTES.md) for the
qemu-segfault gotcha on x86-under-arm):

```
==> parity: gateway=wallarm profile=p09-resp-headers target=http://localhost:9080
    fixture: fixtures/p09-resp-headers.jsonl
  ✓ PASS   client sees X-Bench-Out, does not see Server
  ✓ PASS   response-header drop is unconditional
verdict: PASS  (2/2)
```
