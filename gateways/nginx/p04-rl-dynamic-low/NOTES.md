# `nginx / p04-rl-dynamic-low` — compliance notes

**Current verdict on `nginx:1.27.3-alpine`**: `PASS (2/2)`.
Observed burst shape: `2xx=109, 429=341, 5xx=0` at
`total_requests=450 / duration_s=3 / keys=10 / parallelism=128`.

## How each fixture probe is satisfied

| Probe                                    | nginx mechanism                                                      |
|------------------------------------------|----------------------------------------------------------------------|
| `GET /anything` with `X-Real-IP: 10.0.0.1` → 200 | first request in a freshly-warmed per-IP bucket — never tripped. |
| `10 IPs × 15 rps × 3 s → ≥ 120 (±30) × 429` | `limit_req_zone $http_x_real_ip zone=bench_p04:1m rate=10r/s;` + `limit_req zone=bench_p04 burst=10 nodelay;` |

Observed `341 × 429` is far above the `120 − 30 = 90` minimum
threshold, so the cell has comfortable headroom even on cold Docker
Desktop / CI runners.

Cross-gateway symmetry with `wallarm/p04` (`99 × 2xx + 351 × 429`):
nginx's leaky-bucket under `burst=10 nodelay` admits `1 + burst = 11`
requests per IP before rejecting the rest, which lines up with
wallarm's observed per-IP admission of ~10 during the atomic-read
window. This is why burst=10 was chosen over 0 or 20 — it minimises
the shape delta between the two gateways for the same fixture.

## Mechanism

```nginx
limit_req_zone $http_x_real_ip zone=bench_p04:1m rate=10r/s;
limit_req_status 429;

server {
    location / {
        limit_req zone=bench_p04 burst=10 nodelay;
        error_page 429 @retry_after;
        proxy_pass http://backend_pool;
    }

    location @retry_after {
        internal;
        add_header Retry-After "1" always;
        return 429 '{"error":"rate_limit_exceeded","limit":"10r/s","scope":"per-ip"}';
    }
}
```

Key design choices:

* **Key = `$http_x_real_ip`.** The fixture sets `X-Real-IP` on every
  burst request; nginx maps that header straight into a variable
  without needing Lua or any module beyond `ngx_http_limit_req_module`.
* **`rate=10r/s`.** Matches POLICIES.md exactly. nginx's internal
  granularity is per-millisecond, so 10r/s = 1 token per 100 ms per
  key.
* **`burst=10 nodelay`.** Absorbs a one-second burst per IP without
  queuing. Under the fixture's ASAP shot this admits ~11 req/IP
  (1 rate-free + 10 burst) before the leaky bucket empties, then
  rejects the rest with 429. This matches wallarm's observed shape
  inside ~1 request.
* **`zone=bench_p04:1m`.** 1 MB ≈ >= 8 000 keys — two orders of
  magnitude over p04's 100-IP pool. We keep the floor at 1 MB to
  make the config diffable against p03 (same zone size, different
  key) and p05 (same key, ten times the zone).

## Uniform-settings audit

Same ten rows as
[`p01-vanilla/NOTES.md`](../p01-vanilla/NOTES.md#uniform-settings-audit)
— the `http {}` block is identical between p01, p03 and p04 except
for the `limit_req_zone` / `limit_req` pair and the 429 handler.
No deviations from `docs/GATEWAYS.md § Uniform settings`.

## Not-yet-exercised

* The canonical 100-IP pool from POLICIES.md — the fixture probes
  only 10 IPs. Phase-4 k6 will flood the full 100-IP space; the
  zone is already sized for it (1 MB fits 8 000+ keys).
* `Retry-After: 1` stamping is structural (the 429 handler always
  sets it) but not asserted in the fixture.

Tracking: [`docs/GATEWAYS.md § Deviations`](../../../docs/GATEWAYS.md#deviations).
