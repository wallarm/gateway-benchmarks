# `nginx / p03-rl-static` — compliance notes

**Current verdict on `nginx:1.27.3-alpine`**: `PASS (2/2)`.
Observed burst shape: `2xx=262, 429=938, 5xx=0` at
`total_requests=1200 / duration_s=1 / parallelism=128`.

## How each fixture probe is satisfied

| Probe                                          | nginx mechanism                                             |
|------------------------------------------------|-------------------------------------------------------------|
| `GET /anything → 200` (below limit)            | first request in a freshly-warmed bucket — never tripped.   |
| `1200 rps / 1 s → ≥ 150 (±50) × 429`           | `limit_req_zone $server_name zone=bench_p03:1m rate=1000r/s;` + `limit_req zone=bench_p03 burst=200 nodelay;` |

Observed `938 × 429` is far above the `150 − 50 = 100` minimum
threshold, so the cell has comfortable headroom for measurement
noise on slower hosts (CI runners, cold Docker Desktop on macOS).

## Mechanism

nginx realises "1000 rps service-wide, rolling 1-second window" with
its built-in `ngx_http_limit_req_module` — an in-memory leaky-bucket
implementation:

```nginx
limit_req_zone $server_name zone=bench_p03:1m rate=1000r/s;
limit_req_status 429;

server {
    location / {
        limit_req zone=bench_p03 burst=200 nodelay;
        error_page 429 @retry_after;
        proxy_pass http://backend_pool;
    }

    location @retry_after {
        internal;
        add_header Retry-After "1" always;
        return 429 '{"error":"rate_limit_exceeded","limit":"1000r/s"}';
    }
}
```

Key design choices:

* `$server_name` as the bucket key — `limit_req_zone` demands a
  variable (constants are rejected), and `$server_name` is a
  compile-time string that resolves to the same value on every
  request. Every request therefore collapses into one bucket — the
  "service-wide" semantics POLICIES.md mandates.
* `rate=1000r/s` — nginx's internal granularity is one token per
  millisecond, which matches the spec's rolling-second exactly.
* `burst=200 nodelay` — absorbs short-lived overshoots without
  queueing. Under the fixture's ASAP burst this lets ~201 requests
  (`1 + burst`) through immediately and rejects the rest with 429.
  Under paced 1000 rps traffic (Phase-4 k6) the 200-slot burst
  smooths out sub-millisecond clustering without inflating the
  observed rate.
* `limit_req_status 429` — the module defaults to 503; the canonical
  fixture asserts 429.
* `error_page 429 @retry_after` — nginx does **not** stamp
  `Retry-After` on `limit_req`'s 429 automatically. Bouncing through
  a named internal location is the idiomatic way to attach the
  header and a well-formed JSON body without touching every other
  response.

## Uniform-settings audit

Same ten rows as
[`p01-vanilla/NOTES.md`](../p01-vanilla/NOTES.md#uniform-settings-audit)
— the `http {}` block is identical between p01 and p03 except for
the addition of `limit_req_zone` / `limit_req`. No deviations from
`docs/GATEWAYS.md § Uniform settings`.

## Deliberate non-defaults (beyond p01)

* `zone=bench_p03:1m` — 1 MB shared memory. The module stores
  ~16 000 keys per MB and we need exactly 1; anything smaller would
  work but 1 MB is the conventional floor for a shared zone and
  keeps the config diffable against p04 / p05 which *will* need the
  capacity.
* `server_name bench-nginx;` — set explicitly so `$server_name` has
  a stable value (nginx's default is the hostname, which varies by
  container). The fixture never addresses the server by name, so
  this has no client-visible effect — it only keeps the bucket
  deterministic across runs.

## Why no standalone sanity "burst produces 429" in `setup.sh`

A brief sanity run was tried (`xargs -P 50 curl …` × 500) and did
*not* reliably surface 429s: curl fork / TLS setup costs stretch the
500-request burst over roughly one second on cold Docker Desktop,
which fits inside `rate=1000r/s + burst=200` without ever filling
the bucket. The reliable path is
`scripts/parity-attestation.sh::run_burst_probe`, which uses
`curl --parallel -K <config>` with `BURST_PARALLELISM=128` — that
compresses 1200 requests into the `elapsed_s=1` slot recorded in the
parity report and makes the 429 count deterministic.

## Not-yet-exercised

* `Retry-After: 1` stamping is asserted structurally (the 429
  handler always sets it) but the fixture does not probe for it.
  Any probe that reads `Retry-After` on a 429 would pass today.
* Distributed / multi-node behaviour is out of scope for this bench
  (TASK.md §2 "Out of scope"). `limit_req_zone` is per-worker in
  shared memory — a single-container deployment is single-zone.

Tracking: [`docs/GATEWAYS.md § Deviations`](../../../docs/GATEWAYS.md#deviations).
