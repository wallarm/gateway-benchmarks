# `nginx / p12-full-pipeline` — notes

Canonical spec — [`docs/POLICIES.md § p11`](../../../docs/POLICIES.md).

p11 is the chained composition of six previously-independent
profiles in a single request flow:

```
[p03 rate-limit]  (preaccess)      1000 rps, $server_name key, burst=200
[p02 JWT verify]  (access_by_lua)  HS256 Bearer, constant-time compare
[p09 req body]    (access_by_lua)  inject $.bench.injected, drop $.secret
[p07 req headers] (content)        set X-Bench-In=1, drop X-Forwarded-For
[   upstream   ]
[p08 resp hdrs]   (header_filter)  clear Server, add X-Bench-Out
[p10 resp body]   (body_filter)    inject $.bench.injected, drop $.origin
```

## Image

**OpenResty** (same pin as every p02/p08/p09/p10). Mainline nginx
would satisfy p03/p07 but has no Lua and no `ngx_headers_more`,
so p11 inherits OpenResty wholesale. The image is pinned by
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

- **TLS termination** lives in a separate `p12-full-pipeline-tls`
  profile (see [`docs/POLICIES.md § protocol matrix`](../../../docs/POLICIES.md))
  and is not implemented yet — that is the explicit follow-up
  after every gateway's plaintext column closes.
- **Dynamic rate limit keys** (`$http_x_real_ip`, as in
  p05/p06) are deliberately not used here. p11 composes the
  *static* RL profile (`$server_name` key) because that is what
  `docs/POLICIES.md § p11` specifies. A separate
  `p10-dynamic-pipeline` profile can extend this later without
  disturbing the current parity matrix.

## Comparison with `gateways/wallarm/p12-full-pipeline`

The wallarm cell closes p11 natively through `jwt_validation +
ratelimit + 4 × lua_runner`, but only against a from-source
`WALLARM_IMAGE` (see
[`gateways/wallarm/p12-full-pipeline/NOTES.md`](../../wallarm/p12-full-pipeline/NOTES.md)).
nginx is the **first** gateway in the bench that closes p11 end
to end on an off-the-shelf public image — a complete,
green p11. Reviewers running wallarm with a compliant
`WALLARM_IMAGE` will see a symmetric 4/4 PASS there too.

## Parity result

```
==> parity: gateway=nginx profile=p12-full-pipeline target=http://localhost:9080
    fixture: fixtures/p12-full-pipeline.jsonl
  ✓ PASS   full pipeline: JWT valid, RL below limit, all transforms applied
  ✓ PASS   full pipeline: missing JWT still 401
  ✓ PASS   full pipeline: expired JWT still 401
  ✓ PASS   full pipeline: rate limit kicks in above 1000 rps  [burst: 1200x, 0s, 2xx=0 429=945 5xx=0]
verdict: PASS  (4/4)
```
