# wallarm / p06-req-headers — notes

Canonical policy — [`docs/POLICIES.md` §
p06](../../../docs/POLICIES.md):

```
add:    X-Bench-In: 1
remove: X-Forwarded-For
```

## What we ship

Wallarm `0.2.0` (public image) does not expose a dedicated
`header_transform` policy. The built-in policy registry on this tag
is `lua_runner` + `ratelimit` (see
[`admin-api-openapi.yaml` `PolicyBinding.policy_id`](../../../../wallarm-api-gateway/docs/admin-api-openapi.yaml)).

For request-header rewrite `lua_runner` is the idiomatic vehicle: a
table write + a `nil` delete, no crypto or heavy runtime needed.

- `policy_id:   "lua_runner"`
- `policy_name: "bench-p06-req-headers"`
- `flow:        request_flow` (service level, so every route of the
  service — there is only one — gets the same policy)
- `config.code:`

  ```lua
  function execute(ctx)
    ctx.request.headers["x-bench-in"] = "1"
    ctx.request.headers["x-forwarded-for"] = nil
    return { action = "continue" }
  end
  ```

  Lower-case keys are the canonical form for the
  case-insensitive `ctx.request.headers` table (see
  [`policy-development-guide.md` §3](../../../../wallarm-api-gateway/docs/policy-development-guide.md)).

## Deviation: base-path strip forces a backend-path trick

`wallarm 0.2.0` strips `base_path` and prepends `target.endpoint.url`,
**always** leaving a trailing `/` between the two halves:

    GET /anything/foo   → upstream sees /anything/foo
    GET /anything       → upstream sees /anything/        (trailing /)
    GET /headers        → upstream sees /headers/         (404 on httpbin)

`go-httpbin` 404s on `/headers/` / `/response-headers/` / `/get/`, so
we cannot point `bench-p06-headers` directly at those endpoints.

Workaround: point the service at `go-httpbin`'s permissive
`/anything/headers` slug —

    base_path:          /headers
    target.endpoint.url: http://backend:8080/anything/headers

The client still calls `GET /headers`; the strip+prepend produces
`GET /anything/headers/` on the backend, which is a 200-echo in
`go-httpbin`. The echo shape (`.headers."X-Foo": ["v"]`) is exactly
what the fixture's `backend_saw_header` probe asserts against.

This deviation is **gateway-local** — fixtures in
`fixtures/p06-req-headers.jsonl` remain target-agnostic. Other gateways
(nginx, envoy, kong, apisix, traefik, tyk) will route `/headers`
directly to `go-httpbin`'s `/headers`.

## Deviation: fixture backend echoes headers as arrays

`go-httpbin` returns each request header as a JSON array of strings
(`"X-Bench-In": ["1"]`). A proxy-echo backend might emit a scalar
(`"X-Bench-In": "1"`). `scripts/parity-attestation.sh::assert_json_has_string`
accepts both shapes so the same fixture works regardless of which echo
backend a gateway uses.

## Parity result

Against `wallarm/api-gateway:0.2.0` (arm64 or amd64 native — **not**
under qemu emulation, see below):

```
==> parity: gateway=wallarm profile=p06-req-headers target=http://localhost:9080
    fixture: fixtures/p06-req-headers.jsonl
  ✓ PASS   gateway injects X-Bench-In and drops X-Forwarded-For
  ✓ PASS   X-Forwarded-For drop is unconditional
  ✓ PASS   other client headers pass through unchanged
verdict: PASS  (3/3)
```

### Gotcha: `lua_runner` under qemu segfaults

On Apple Silicon, `docker pull --platform linux/amd64 wallarm/api-gateway:0.2.0`
lands an amd64 image that Docker Desktop runs under qemu. Activating
**any** `lua_runner` config in that environment aborts with a
`qemu: uncaught target signal 11 (Segmentation fault) - core dumped`.
This is **not** a wallarm bug — it is qemu's x86-on-arm JIT dying on
LuaJIT-style tracing. The image tag ships a multi-arch manifest index,
so a plain `docker pull wallarm/api-gateway:0.2.0` (no `--platform`)
lands the **native** arm64 build and the policy works.

Symptom:

```
INFO epoch: Activated epoch 4
qemu: uncaught target signal 11 (Segmentation fault) - core dumped
```

Workaround: do not force `--platform linux/amd64` on Apple Silicon.
The pinned digest (`sha256:a3d4d2f7…`) is the multi-arch index, so
native resolution is automatic.
