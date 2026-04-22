# `nginx / p10-full-pipeline` — notes

Canonical spec — [`docs/POLICIES.md § p10`](../../../docs/POLICIES.md).

p10 is the chained composition of six previously-independent
profiles in a single request flow:

```
[p03 rate-limit]  (preaccess)      1000 rps, $server_name key, burst=200
[p02 JWT verify]  (access_by_lua)  HS256 Bearer, constant-time compare
[p08 req body]    (access_by_lua)  inject $.bench.injected, drop $.secret
[p06 req headers] (content)        set X-Bench-In=1, drop X-Forwarded-For
[   upstream   ]
[p07 resp hdrs]   (header_filter)  clear Server, add X-Bench-Out
[p09 resp body]   (body_filter)    inject $.bench.injected, drop $.origin
```

## Image

**OpenResty** (same pin as every p0{2,7,8,9}). Mainline nginx
would satisfy p03/p06 but has no Lua and no `ngx_headers_more`,
so p10 inherits OpenResty wholesale. The image is pinned by
digest via [`./.env`](./.env) and mounted into
[`docker-compose.yaml`](../docker-compose.yaml) through the
`${GATEWAY_IMAGE:-<mainline>}` override.

## Phase ordering is the magic

nginx's request-processing phases encode the semantics of the
fixture for free:

| Fixture expectation                              | nginx phase       | Directive / Lua hook         |
|--------------------------------------------------|-------------------|------------------------------|
| `missing JWT → 401`                              | `ACCESS`          | `access_by_lua_block` L1     |
| `expired JWT → 401`                              | `ACCESS`          | `access_by_lua_block` L1     |
| `valid JWT below limit → 200 with transforms`    | `ACCESS` + later  | whole chain                  |
| `1200 rps valid-JWT burst → ≥150 × 429`          | `PREACCESS`       | `limit_req` runs before Lua  |

Specifically: `PREACCESS` fires **before** `ACCESS`, so a flood
of valid tokens still hits rate-limit 429s — the fixture's probe 4
(`burst: 1200x, 0s → 945 × 429`) confirms it on the production
bench. A hand-rolled "verify JWT, then counter" pipeline that
gets the ordering wrong would spend CPU verifying 1200 tokens
for nothing.

## What's *not* here

- **TLS termination** lives in a separate `p10-full-pipeline-tls`
  profile (see [`docs/POLICIES.md § protocol matrix`](../../../docs/POLICIES.md))
  and is not implemented yet — that is the explicit follow-up
  after every gateway's plaintext column closes.
- **Dynamic rate limit keys** (`$http_x_real_ip`, as in
  p04/p05) are deliberately not used here. p10 composes the
  *static* RL profile (`$server_name` key) because that is what
  `docs/POLICIES.md § p10` specifies. A separate
  `p10-dynamic-pipeline` profile can extend this later without
  disturbing the current parity matrix.

## Comparison with `gateways/wallarm/p10-full-pipeline`

The wallarm cell is tagged `FEATURE-MISSING` because
`wallarm/api-gateway:0.2.0` lacks a `jwt_validation` policy
(see [`gateways/wallarm/p10-full-pipeline/NOTES.md`](../../wallarm/p10-full-pipeline/NOTES.md)).
nginx is the **first** gateway in the bench with a complete,
green p10. When the wallarm `jwt_validation` policy ships in a
public release, their p10 will flip to PASS in the same commit
that flips p02.

## Parity result

```
==> parity: gateway=nginx profile=p10-full-pipeline target=http://localhost:9080
    fixture: fixtures/p10-full-pipeline.jsonl
  ✓ PASS   full pipeline: JWT valid, RL below limit, all transforms applied
  ✓ PASS   full pipeline: missing JWT still 401
  ✓ PASS   full pipeline: expired JWT still 401
  ✓ PASS   full pipeline: rate limit kicks in above 1000 rps  [burst: 1200x, 0s, 2xx=0 429=945 5xx=0]
verdict: PASS  (4/4)
```
