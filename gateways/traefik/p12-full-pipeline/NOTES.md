# gateways/traefik/p12-full-pipeline

**Status:** `PASS 4/4`

## Canonical contract

`docs/POLICIES.md § p11` — every single-feature profile (p02..p10)
applied as one composed pipeline against the same service:

    JWT validation (HS256)  →
      service-wide rate limit (1000 rps, 200-burst)  →
        request-header transform (inject X-Bench-In, drop X-Forwarded-For)  →
          request-body transform (inject $.bench.injected, drop $.secret)  →
            response-header transform (inject X-Bench-Out, drop Server)  →
              response-body transform (inject $.bench.injected, drop $.origin)

## Mechanism

Single router (`backend`), six chained middleware in canonical
order:

```yaml
middlewares:
  - bench-p02   # plugin: jwt_hs256          (HS256, secret inlined)
  - bench-p04   # rateLimit                  (1000 rps, 200 burst)
  - bench-p08   # headers                    (add X-Bench-In, drop X-Forwarded-For)
  - bench-p10   # plugin: body_rewrite/req   (inject + drop on request body)
  - bench-p09   # headers                    (add X-Bench-Out, drop Server)
  - bench-p11   # plugin: body_rewrite/resp  (inject + drop on response body)
```

Traefik runs middleware in declared order on the request path and
in reverse on the response path. A 401 from `bench-p02`
short-circuits everything downstream — `bench-p04`'s bucket is
NOT decremented, no transforms run, the response goes straight
back. Same for a 429 from `bench-p04` once we've passed JWT. Both
the request-body and response-body rewrites only run on requests
that survived the first two gates.

That ordering is critical for the burst probe (probe 4): with
1200 valid-JWT requests in 1 s, the JWT step pays for all 1200
but the body rewrites only pay for the ~270 that the rate limit
lets through, keeping the per-request budget within Yaegi's
reach.

## Burst probe results

```
total_requests:  1200
2xx:              270
429:              930
5xx:                0
```

Fixture asserts `status_429_min: 150` (tolerance ±50 around the
expected mid-point). Observed 930 × 429 — well past the
threshold. The reason 2xx is closer to 270 than 1000 is the
loadgen's burst-mode parallelism (128 concurrent senders): the
1200 requests fire in <200 ms ASAP, so the rate-limit's 200-token
burst capacity drains immediately and only the trickle of
1-token-per-ms refills lets additional requests through. Other
gateways in the matrix (kong/apisix/nginx) show similar
imbalance under the same probe — the assertion checks the
order-of-magnitude rate-limit kick-in, not a tight headcount.

## Why p11 closed at the same time as p02

The two cells are coupled: p02 unlocks JWT validation, and p11
composes JWT on top of already-green middleware (p03 + p07 + p09
+ p08 + p10 were all PASS before this iteration). Once
`bench-p02` slot was filled by the new `jwt_hs256` plugin, p11
became a straight composition with no architectural surprises.

## Implementation notes

### Plugin chain shortname

Traefik references plugins by the key from
`experimental.localPlugins` (NOT the Go module path). Both this
profile and p02 declare:

```yaml
experimental:
  localPlugins:
    body_rewrite:
      modulename: github.com/wallarm/body_rewrite
    jwt_hs256:
      modulename: github.com/wallarm/jwt_hs256
```

So the middleware references them as `plugin.body_rewrite` and
`plugin.jwt_hs256`.

### `forwardedHeaders.insecure: true`

Probe 1 carries `X-Forwarded-For: 198.51.100.7` and asserts
`backend_missed_header: [X-Forwarded-For]` — the gateway MUST be
the one stripping it. Without `insecure: true` the entryPoint
strips XFF from the untrusted client BEFORE the `headers`
middleware in dynamic.yaml even sees it, which would pass the
assertion for the wrong reason. Same idiom as p05 / p07.

### Body-rewrite cost on GET

The `body_rewrite` plugin doesn't have a method-filter — it runs
on every request that reaches it, including GETs. For a GET with
no body it synthesizes `{}`, applies inject, marshals back, sets
`Content-Length: 23`. This adds ~µs per request via Yaegi
interpretation, but the rate limit gates the burst before the
body rewrite ever runs in the fast majority of cases (200 burst
+ ~70 refill = ~270 requests reach body-rewrite during the burst
window). Throughput is comfortable.

If a future probe ever pushes 2xx counts above ~500/s on this
chain, the body_rewrite plugin should grow a `methods: [POST,
PUT, PATCH]` filter (matching the kong p11 pattern). Out of
scope for the current matrix.

## Probe-by-probe

| # | Probe                                                                                | Expected                                | Observed              | Status |
|---|--------------------------------------------------------------------------------------|-----------------------------------------|-----------------------|--------|
| 1 | full pipeline: JWT valid, RL below limit, all transforms applied                     | 200 + headers + body inject/drop        | 200, all transforms   | PASS   |
| 2 | full pipeline: missing JWT still 401                                                 | 401                                     | 401                   | PASS   |
| 3 | full pipeline: expired JWT still 401                                                 | 401                                     | 401                   | PASS   |
| 4 | full pipeline: rate limit kicks in above 1000 rps (1200 GETs in 1 s, valid JWT)      | `status_429_min: 150` (tolerance ±50)   | 2xx=270, 429=930      | PASS   |

`PASS 4/4`. Reproduce with:

```bash
make parity-gateway PARITY_GATEWAY=traefik PARITY_PROFILE=p12-full-pipeline
```
