# `wallarm / p10-full-pipeline` — deviation notes

**Pinned public verdict on `wallarm/api-gateway:0.2.0`**:
`FEATURE-MISSING` (cascade from `p02-jwt`).

**Local override verdict on `wallarm/api-gateway:main-5f1ab30`**:
`PASS (4/4)`.

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
image](../p02-jwt/NOTES.md), `p10` inherits the marker on the pinned
public image.

`setup.sh` now does the same runtime `/policies` detection as `p02`:
on public `0.2.0` it returns `FEATURE-MISSING`, while a local main-branch
override can bind the full flow and run parity for real.

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

## Local main override

With:

```bash
WALLARM_IMAGE=wallarm/api-gateway:main-5f1ab30 \
    make parity-gateway PARITY_GATEWAY=wallarm PARITY_PROFILE=p10-full-pipeline
```

the full pipeline is green:

- valid JWT happy-path -> `200` + all five transforms
- missing JWT -> `401`
- expired JWT -> `401`
- burst with valid JWT -> `2xx=998, 429=202, 5xx=0`

Two implementation details matter for that green burst:

1. The benchmark harness must forward `.burst.headers`, otherwise the
   p10 rate-limit probe silently fires without `Authorization` and all
   1200 requests land in `401 other`.
2. The p10-local `req-body` Lua path is a no-op on empty request bodies.
   That keeps the happy-path POST exercising body rewrite while letting
   the burst probe's bodyless `GET /anything` reach the JWT+RL stages
   without a synthetic-body 500.

The live binding installed by `setup.sh` is still the same canonical
composition the old forward-compatible sketch described:

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

Track `jwt_validation` visibility in future public Wallarm releases.
The benchmark repo no longer needs a separate `FEATURE-MISSING` marker
file for `p10`: the runtime `setup.sh` already handles both cases
honestly. The public `0.2.0` image still resolves to `FEATURE-MISSING`;
the local override is now fully green.

Tracking: [`docs/GATEWAYS.md § deviations`](../../../docs/GATEWAYS.md#deviations).
