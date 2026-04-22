# `nginx / p05-rl-dynamic-high` — compliance notes

**Current verdict on `nginx:1.27.3-alpine`**: `PASS (3/3)`.

Observed burst shapes:
* burst #1 (10 IPs × 20 rps / 1 s, limit 100/IP):
  `2xx=200, 429=0, 5xx=0` — every request below limit, as expected.
* burst #2 (1 IP × 500 rps / 1 s, limit 100/IP):
  `2xx=24, 429=476, 5xx=0` — well above the fixture's
  `status_429_min=300 ± 40` minimum threshold of 260.

## How each fixture probe is satisfied

| Probe                                              | nginx mechanism                                                          |
|----------------------------------------------------|--------------------------------------------------------------------------|
| `GET /anything` with `X-Real-IP: 10.5.0.1` → 200   | first request in a freshly-warmed per-IP bucket — never tripped.          |
| 10 distinct IPs × 200 rps → all 200 × 2xx          | `rate=100r/s` per `$http_x_real_ip` + `burst=20 nodelay` — each IP sends 20 req, 1 rate-free + 20 burst slots = 21 ≥ 20 so every IP's bucket absorbs the entire burst. |
| Single IP × 500 rps → ≥ 300 (±40) × 429            | Same zone/limit. 1 IP shoots 500 requests ASAP; ~21 pass (1+burst), the rest (~479) reject with 429.                                |

Observed `476 × 429` on the second burst is almost exactly the
`500 − 21 = 479` expected shape — the tiny three-request delta
reflects micro-pacing of `curl --parallel` across the 128 worker
slots (a few requests happen a millisecond apart and catch a newly
leaked token).

## Mechanism

```nginx
limit_req_zone $http_x_real_ip zone=bench_p05:10m rate=100r/s;
limit_req_status 429;

server {
    location / {
        limit_req zone=bench_p05 burst=20 nodelay;
        error_page 429 @retry_after;
        proxy_pass http://backend_pool;
    }

    location @retry_after {
        internal;
        add_header Retry-After "1" always;
        return 429 '{"error":"rate_limit_exceeded","limit":"100r/s","scope":"per-ip"}';
    }
}
```

Key design choices:

* **Zone = `10m`.** This is the only non-trivial difference from
  p04's `1m` zone: p05's POLICIES-mandated pool is **50 000
  distinct IPs**. nginx reserves ~128 bytes per key; 50 000 × 128 B
  ≈ 6.4 MB, so 10 MB leaves ~35 % slack to avoid LRU thrashing as
  the key-set rotates under the Phase-4 k6 flood. This is the
  "✓†" footnote in `docs/POLICIES.md § Feature availability` —
  the nginx column meets p05 spec, but only with explicit zone
  sizing (the 1 MB floor of p03/p04 would evict keys and distort
  the per-IP accounting).
* **`rate=100r/s` + `burst=20 nodelay`.** 100r/s = 1 token per
  10 ms. `burst=20` is just large enough to pass the 20-per-IP
  sub-limit probe in one piece (burst #1) while still producing a
  decisive 429 storm on the over-limit probe (burst #2).
* **Same key + 429 handler + uniform settings as p04.** The only
  per-profile knobs are `rate=`, `zone=`, `burst=`.

## Uniform-settings audit

Identical to `p01-vanilla` / `p03-rl-static` / `p04-rl-dynamic-low`.
No deviations from `docs/GATEWAYS.md § Uniform settings`.

## Why no setup-time burst sanity

Same rationale as
[`p03-rl-static/NOTES.md § Why no standalone sanity`](../p03-rl-static/NOTES.md#why-no-standalone-sanity-burst-produces-429-in-setupsh):
xargs-based sanity is unreliable because curl fork/TLS costs stretch
the burst over a wall-clock second, which fits inside
`rate=100r/s + burst=20` per-IP and never triggers limit_req. The
reliable path is `scripts/parity-attestation.sh::run_burst_probe`
with `curl --parallel -K <config>`, `BURST_PARALLELISM=128`.

## Not-yet-exercised

* The canonical 50 000-IP pool from POLICIES.md. The fixture only
  rotates through a handful of addresses (`10.5.0.1..10` and
  `10.5.9.9`). The zone is already sized for the full pool; Phase-4
  k6 will flood it.
* `Retry-After: 1` stamping — structural but not asserted.
* Per-worker zone sharding — this config runs a single container,
  so the zone is a single shared-memory region. Multi-container /
  multi-node RL is out of scope per TASK.md §2.

Tracking: [`docs/GATEWAYS.md § Deviations`](../../../docs/GATEWAYS.md#deviations).
