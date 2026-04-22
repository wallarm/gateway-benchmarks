# `wallarm / p10-full-pipeline` — deviation notes

**Current verdict on `wallarm/api-gateway:0.2.0`**: `FEATURE-MISSING`
(cascade from `p02-jwt`).

## Why

`p10` is defined in [`docs/POLICIES.md § p10`](../../../docs/POLICIES.md#p10--full-pipeline)
as the composition of six policies in strict order:

```
request:  p02 (jwt) → p03 (rl) → p06 (req-headers) → p08 (req-body)
response: p09 (resp-body) → p07 (resp-headers)
```

[`fixtures/p10-full-pipeline.jsonl`](../../../fixtures/p10-full-pipeline.jsonl)
exercises that chain with four probes:

| # | Probe                     | Hard JWT dependency?                           |
|---|---------------------------|------------------------------------------------|
| 1 | valid-JWT happy path      | yes — expects `status=200` + all 5 transforms  |
| 2 | missing JWT               | **yes — expects `status=401`**                 |
| 3 | expired JWT               | **yes — expects `status=401`**                 |
| 4 | burst (valid JWT, 1200 rps) | yes — needs valid JWT to reach the RL bucket |

Probes 2 and 3 are the blockers: without a gateway-side JWT validator,
Wallarm happily forwards the requests and returns `200`, which is a
functional failure of the profile.

Since `p02-jwt` is itself [`FEATURE-MISSING` on this
image](../p02-jwt/NOTES.md), `p10` inherits the marker.

## What *is* already working (as standalone PASSes)

Every other building block of the pipeline is green in its own cell on
this very image, proving the orchestration, the Admin API, the
`lua_runner` sandbox, the `ratelimit` policy, and the burst runner are
sound:

| Building block | Cell             | Status |
|----------------|------------------|:------:|
| rl static      | `p03-rl-static`  |   ✓    |
| req headers    | `p06-req-headers`|   ✓    |
| resp headers   | `p07-resp-headers`|  ✓    |
| req body       | `p08-req-body`   |   ✓    |
| resp body      | `p09-resp-body`  |   ✓    |

The composition step itself does **not** expose anything new we
haven't already exercised — both `request_flow` and `response_flow` are
plain arrays in Wallarm's Admin API, so stacking policies is a pure
configuration join.

## Forward-compatible `setup.sh` sketch

The moment a public Wallarm release exposes the `jwt_validation`
policy (source evidence:
[`wallarm-api-gateway/tests/integration/jwt_validation_test.sh`](../../../../wallarm-api-gateway/tests/integration/jwt_validation_test.sh)),
the script below should make this cell flip to `PASS` without any
changes to the fixture, the parity runner, or any other cell:

```bash
#!/usr/bin/env bash
set -euo pipefail

ADMIN_URL="${ADMIN_URL:-http://localhost:9081}"
BACKEND_URL="${BACKEND_URL:-http://backend:8080}"

SERVICE_NAME="bench-p10"
SERVICE_PATH="/anything"

# Lua for req-headers (p06) — add X-Bench-In, drop X-Forwarded-For
read -r -d '' LUA_REQ_HEADERS <<'LUA' || true
function execute(ctx)
  ctx.request.headers["x-bench-in"] = "1"
  ctx.request.headers["x-forwarded-for"] = nil
  return { action = "continue" }
end
LUA

# Lua for req-body (p08) — add $.bench.injected=true, drop $.secret
read -r -d '' LUA_REQ_BODY <<'LUA' || true
function execute(ctx)
  local cjson = require("cjson.safe")
  local data  = cjson.decode(ctx.request.body or "") or {}
  if type(data) ~= "table" then data = {} end
  if type(data.bench) ~= "table" then data.bench = {} end
  data.bench.injected = true
  data.secret = nil
  local new_body = cjson.encode(data)
  ctx.request.body = new_body
  ctx.request.headers["content-length"] = tostring(#new_body)
  return { action = "continue" }
end
LUA

# Lua for resp-body (p09) — add $.bench.injected=true, drop $.origin
read -r -d '' LUA_RESP_BODY <<'LUA' || true
function execute(ctx)
  local cjson = require("cjson.safe")
  local data  = cjson.decode(ctx.response.body or "")
  if type(data) ~= "table" then return { action = "continue" } end
  if type(data.bench) ~= "table" then data.bench = {} end
  data.bench.injected = true
  data.origin = nil
  local new_body = cjson.encode(data)
  ctx.response.body = new_body
  ctx.response.headers["content-length"] = tostring(#new_body)
  return { action = "continue" }
end
LUA

# Lua for resp-headers (p07) — add X-Bench-Out, drop Server
read -r -d '' LUA_RESP_HEADERS <<'LUA' || true
function execute(ctx)
  ctx.response.headers["x-bench-out"] = "1"
  ctx.response.headers["server"] = nil
  return { action = "continue" }
end
LUA

# 1. Service — /anything routed through go-httpbin's /anything catch-all
curl -fsS -X POST "${ADMIN_URL}/services" \
  -H "Content-Type: application/json" \
  -d "$(jq -cn \
        --arg name "${SERVICE_NAME}" \
        --arg bp   "${SERVICE_PATH}" \
        --arg be   "${BACKEND_URL}/anything" \
        '{name:$name, base_path:$bp, target:{endpoint:{url:$be}}}')"

curl -fsS -X POST "${ADMIN_URL}/services/${SERVICE_NAME}/routes" \
  -H "Content-Type: application/json" \
  -d '{"id":"catchall","condition":{"path":["/**"]}}'

# 2. Compose the full flow in canonical order
flow=$(jq -cn \
  --arg   lua_req_h "${LUA_REQ_HEADERS}" \
  --arg   lua_req_b "${LUA_REQ_BODY}" \
  --arg   lua_res_h "${LUA_RESP_HEADERS}" \
  --arg   lua_res_b "${LUA_RESP_BODY}" \
  '{
     request_flow: [
       { policy_id:"jwt_validation", policy_name:"bench-p10-jwt",
         config:{ algorithm:"HS256",
                  secret_key:"bench-jwt-hs256-secret-2026" } },
       { policy_id:"ratelimit",      policy_name:"bench-p10-rl",
         config:{ ratelimit_key:"bench-p10", rate:1000, window:1,
                  window_type:"sliding", scope:"service" } },
       { policy_id:"lua_runner",     policy_name:"bench-p10-req-h",
         config:{ code:$lua_req_h } },
       { policy_id:"lua_runner",     policy_name:"bench-p10-req-b",
         config:{ code:$lua_req_b } }
     ],
     response_flow: [
       { policy_id:"lua_runner",     policy_name:"bench-p10-res-b",
         config:{ code:$lua_res_b } },
       { policy_id:"lua_runner",     policy_name:"bench-p10-res-h",
         config:{ code:$lua_res_h } }
     ]
   }')

curl -fsS -X POST "${ADMIN_URL}/services/${SERVICE_NAME}/flow" \
  -H "Content-Type: application/json" \
  -d "${flow}"
```

The parity runner generates `JWT_VALID` / `JWT_EXPIRED` on the fly
through [`scripts/gen-jwt.sh`](../../../scripts/gen-jwt.sh), using the
shared reference assets in
[`gateways/_reference/jwt/`](../../_reference/jwt/) — specifically
[`secret.txt`](../../_reference/jwt/secret.txt) and
[`payload-template.json`](../../_reference/jwt/payload-template.json).
Both tokens are HS256-signed with `bench-jwt-hs256-secret-2026`
(the same secret the sketch configures on the `jwt_validation`
policy), so no further setup is needed on the client side.

## Expected follow-up

1. Track `jwt_validation` visibility in future public Wallarm releases.
2. When it lands: drop this `FEATURE-MISSING` file, paste the sketch
   above into `setup.sh`, run `make parity-gateway GATEWAY=wallarm
   PROFILE=p10-full-pipeline`, and the 4 fixture probes should go
   green without any fixture or harness change.

Tracking: [`docs/GATEWAYS.md § deviations`](../../../docs/GATEWAYS.md#deviations).
