# `nginx / p05-rl-endpoint` — parity compliance

**Verdict**: `PASS` on `nginx:1.27.3-alpine`.

## Canonical policy

From [`docs/POLICIES.md § p04`](../../../docs/POLICIES.md#p04--per-endpoint-static-rate-limit):

- Limit: **100 req/s**, rolling 1 s window.
- Scope: ONE client-visible endpoint path (`/anything/limited`).
- Every other path on the same gateway must stay unrestricted.
- Over-limit: `429 Too Many Requests` + `Retry-After: 1`.

## How nginx encodes the scoping

The `limit_req` directive is lexically scoped to its enclosing
`location` block. Placing it inside `/anything/limited` while the
catch-all `/` has no `limit_req` reference means:

1. `GET /anything/limited` → nginx selects the longest-prefix
   match (`/anything/limited`) → `limit_req` runs → bucket
   decrements.
2. `GET /anything/free`, `GET /anything/whatever`, `GET /` → nginx
   falls through to `location /` → no `limit_req` clause → no
   bucket lookup at all.

```nginx
limit_req_zone $server_name zone=bench_p05:1m rate=100r/s;

server {
    location /anything/limited {
        limit_req zone=bench_p05 burst=100 nodelay;
        error_page 429 @retry_after;
        proxy_pass http://backend_pool;
    }
    location / {
        proxy_pass http://backend_pool;      # no limit_req
    }
    location @retry_after {
        internal;
        add_header Retry-After "1" always;
        return 429 '{"error":"rate_limit_exceeded","limit":"100r/s","scope":"endpoint:/anything/limited"}';
    }
}
```

## Bucket shape

- `rate=100r/s` → 100 tokens/second steady leak.
- `burst=100 nodelay` → absorb the first `(1 + 100) = 101` requests
  immediately, reject the rest with 429 until the leak drains the
  bucket.

Under the fixture's ASAP 1200-request burst (fits in ~100 ms with
`curl --parallel --parallel-max 32`):

- ~110 × 2xx  (101 burst + ~10 refill over the burst window)
- ~1090 × 429
- 0 × 5xx

Well above the `status_429_min=150 ± 50` threshold.

## Scoping check (probe 4)

The fixture's fourth probe fires the identical 1200-request ASAP
burst on `/anything/free`. Expected: `2xx >= 1100`, `429 == 0`,
`5xx == 0`. A single 429 here would mean the `limit_req` clause
leaked into the catch-all location — the fixture's
`status_429_max: 0` assertion catches that class of regression.

## Deviations

None. This is the canonical shape envoy / kong / apisix / tyk will
mirror with their own route-scoping primitives.

## Why a dedicated profile (not a modification of p03 / p05 / p06)

See [`docs/POLICIES.md § p04`](../../../docs/POLICIES.md#p04--per-endpoint-static-rate-limit).
Briefly: `p03` tests "service-wide bucket", `p05`/`p06` test
"per-source-IP bucket", `p04` tests "one-route bucket". These are
three distinct axes of a rate-limit primitive and all three have to
stay in the matrix for the benchmark to tell gateways apart.
