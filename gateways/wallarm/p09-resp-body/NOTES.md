# wallarm / p09-resp-body — notes

Canonical policy — [`docs/POLICIES.md` §
p09](../../../docs/POLICIES.md):

```
add:    $.bench.injected = true
remove: $.origin
```

## What we ship

Same vehicle as p08 — `lua_runner` + `cjson.safe` — but on
`response_flow`. The Lua sandbox exposes `ctx.response.body` /
`ctx.response.headers` exactly like it does for requests (verified
against
[`response_flow_gaps_test.sh`](../../../../wallarm-api-gateway/tests/integration/response_flow_gaps_test.sh)
L311–L378 in the upstream test suite).

- `policy_id:   "lua_runner"`
- `policy_name: "bench-p09-resp-body"`
- `flow:        response_flow` (service level)
- `config.code:`

  ```lua
  function execute(ctx)
    local cjson = require("cjson.safe")
    local body = ctx.response.body or ""
    local data = cjson.decode(body)
    if type(data) ~= "table" then
      return { action = "continue" }
    end
    if type(data.bench) ~= "table" then
      data.bench = {}
    end
    data.bench.injected = true
    data.origin = nil
    local new_body = cjson.encode(data)
    ctx.response.body = new_body
    ctx.response.headers["content-length"] = tostring(#new_body)
    return { action = "continue" }
  end
  ```

  Robustness points:

  - Non-JSON upstream bodies (e.g. a 5xx HTML page, a streamed
    file) are passed through untouched — we only rewrite
    well-formed JSON.
  - `data.bench` is coerced to a table before assignment.
  - `Content-Length` is recomputed; otherwise clients see a
    truncated body or hang on keep-alive (this is the same
    pattern as
    [`response_flow_gaps_test.sh` L378](../../../../wallarm-api-gateway/tests/integration/response_flow_gaps_test.sh)).

## Deviation: go-httpbin echoes query args as arrays

For fixture
[`fixtures/p09-resp-body.jsonl`](../../../fixtures/p09-resp-body.jsonl)
probe 2, the ideal backend would emit `"args": { "q": "hello" }`,
but go-httpbin encodes query args as possibly-multi-value arrays
(`"args": { "q": ["hello"] }`). The harness's
`assert_json_contains_value` helper accepts both a scalar string and
an array-of-strings at the asserted path, so fixtures stay
gateway-agnostic; this deviation is a **backend-echo shape**, not a
wallarm shape, and will surface identically on any gateway that
proxies to go-httpbin.

## Parity result

Against `wallarm/api-gateway:0.2.0` (native arch — see qemu gotcha
in [`p06-req-headers/NOTES.md`](../p06-req-headers/NOTES.md)):

```
==> parity: gateway=wallarm profile=p09-resp-body target=http://localhost:9080
    fixture: fixtures/p09-resp-body.jsonl
  ✓ PASS   gateway adds $.bench.injected and drops $.origin
  ✓ PASS   response-body rewrite preserves other top-level fields
  ✓ PASS   works for POST responses too
verdict: PASS  (3/3)
```
