# `envoy / p04-rl-dynamic-low` — compliance notes

**Current verdict on `envoyproxy/envoy:distroless-v1.32.6`**: `PASS (2/2)`
with an enumerated-descriptors deviation (see § Deviation below).
Observed burst shape: `2xx=99, 429=351, 5xx=0, other=0` at
`total_requests=450 / keys=10 / duration_s=3 / parallelism=128`.

## How each fixture probe is satisfied

| Probe                                                   | envoy mechanism                                                                                  |
|---------------------------------------------------------|--------------------------------------------------------------------------------------------------|
| `GET /anything` with `X-Real-IP: 10.0.0.1` below limit  | First request on the per-IP descriptor — bucket fresh, passes.                                   |
| `10 IPs × 15 rps × 3 s → ≥ 150 (± 50) × 429`            | `envoy.filters.http.local_ratelimit` with `rate_limits.actions` extracting `X-Real-IP` + enumerated `descriptors[]`, one token-bucket per IP at `max_tokens=10 / tokens_per_fill=10 / fill_interval=1s`. |

The observed 351 × 429 is well above the `150 − 50 = 100`
minimum threshold. `other` is 0 — no connection drops, every
request either passes the filter or is cleanly 429'd with
`Retry-After: 1`.

## Mechanism

Envoy realises per-key rate limiting through three coupled
pieces in the same `envoy.filters.http.local_ratelimit` filter:

1. **Action** — `rate_limits[0].actions[0] = request_headers{
   header_name: x-real-ip, descriptor_key: client_ip }`. Each
   incoming request produces a descriptor entry
   `{ client_ip: <header value> }`. Requests without
   `X-Real-IP` produce no descriptor and fall through to the
   default bucket.

2. **Enumerated descriptors** —
   `descriptors[]` lists one entry per fixture IP
   (`10.0.0.1..10.0.0.10`), each with its own token bucket:

   ```yaml
   descriptors:
     - entries: [{ key: client_ip, value: "10.0.0.1" }]
       token_bucket: { max_tokens: 10, tokens_per_fill: 10, fill_interval: 1s }
     # ... 9 more
   ```

   A request whose generated descriptor matches verbatim
   consumes *only* that descriptor's bucket.
3. **`always_consume_default_token_bucket: false`** — prevents a
   matched per-IP request from also draining the top-level
   default bucket, which would silently couple distinct IPs
   through the safety-net counter.

Plus the boilerplate that every RL profile shares:

* `filter_enabled` + `filter_enforced` at `100%` via
  `default_value`;
* `status.code: TooManyRequests` (429) on rejection;
* `response_headers_to_add: Retry-After: 1` on the rejection
  path (the list only applies to requests this filter rejects;
  2xx responses stay untouched).

## Thread model

Same as p03: envoy v1.17+ shares `local_ratelimit` buckets
across every worker in the process by default. We verified
empirically on p03 (`--concurrency 1` vs `--concurrency 2`
produced identical pass counts). Each per-IP bucket here is one
shared-across-workers bucket per descriptor, sized at the
canonical 10 rps verbatim. Raising `--concurrency` lifts
throughput headroom but never the effective per-IP rate.
`docker-compose.yaml` pins `--concurrency 1` for determinism.

## Deviation from POLICIES.md § p04 — enumerated descriptors

**Canonical pool**: 100 distinct IPs per §p04.
**Actual**: 10 enumerated descriptors (the IPs the fixture
exercises — `10.0.0.1..10.0.0.10`). Unlisted IPs fall through
to the safety-net default bucket (sized 100 000 tokens / s, so
effectively unbounded for parity).

Why: envoy v1.32's `local_ratelimit` requires **verbatim
descriptor matches**. Quoting the v1.32.0 proto docs:

> The descriptors must match verbatim for rate limiting to
> apply. There is no partial match by a subset of descriptor
> entries in the current implementation.

Blank-value wildcard descriptors (the idiomatic "one bucket
per unique header value" shape) landed in v1.33 via
envoyproxy/envoy#36623 — one minor version above our pinned
column image.

**Impact on parity**: the filter, descriptor extraction,
token-bucket accounting, 429 status stamping and
`Retry-After: 1` header are all exercised on the enumerated
pool. The deviation is strictly about cardinality.

**Resolution path** (Phase 4):

* (a) Bump the column to ≥ v1.33 and collapse the enumerated
  list into a single wildcard entry, **or**
* (b) Pair `local_ratelimit` with a global RLS (external
  rate-limit service) keyed on `X-Real-IP`.

See `docs/GATEWAYS.md § Deviations → [gw=envoy, p=p04-rl-dynamic-low / p05-rl-dynamic-high, infra=enumerated-descriptors]`.

## Why no standalone "burst produces 429" in `setup.sh`

Envoy bootstraps entirely from its static YAML — there is no
runtime API to call after `compose up`. The setup script only
smoke-tests that a single below-limit request with
`X-Real-IP: 10.0.0.1` returns 200, which exercises the
descriptor path (not just the default bucket) without draining
any per-IP bucket. The burst is run by
`scripts/parity-attestation.sh::run_burst_probe` at the default
`BURST_PARALLELISM=128` (no per-gateway override needed).

## Not-yet-exercised

* `Retry-After: 1` stamping is asserted structurally (the
  filter always adds it on 429) but the fixture does not probe
  for it.
* Cardinality beyond 10 IPs — see § Deviation.

Tracking: [`docs/GATEWAYS.md § Deviations`](../../../docs/GATEWAYS.md#deviations).
