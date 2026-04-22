# `envoy / p05-rl-dynamic-high` — compliance notes

**Current verdict on `envoyproxy/envoy:distroless-v1.32.6`**: `PASS (3/3)`
with an enumerated-descriptors deviation (shared with p04; see
§ Deviation below).

## How each fixture probe is satisfied

| Probe                                                        | envoy mechanism                                                                                   |
|--------------------------------------------------------------|---------------------------------------------------------------------------------------------------|
| `GET /anything` with `X-Real-IP: 10.5.0.1` below limit       | First request on the per-IP descriptor — bucket fresh, passes.                                    |
| `10 IPs × 20 req below limit → 200 × 10 × 20 = 2xx all`      | Each IP's `max_tokens: 100` bucket absorbs 20 below-limit requests comfortably.                   |
| `10 IPs × 150 rps × 1 s → ~500 × 429` + `10.5.9.9 × 10 × 2xx`| `envoy.filters.http.local_ratelimit` with enumerated `descriptors[]` for all 11 IPs, per-IP `max_tokens=100`. |

`other` is 0 on every run — every request either passes the
filter or is cleanly 429'd with `Retry-After: 1`.

## Mechanism

Identical to p04, different per-IP bucket size. Three pieces in
the same `envoy.filters.http.local_ratelimit` filter:

1. **Action** — `rate_limits[0].actions[0] = request_headers{
   header_name: x-real-ip, descriptor_key: client_ip }`.
2. **Enumerated descriptors** — one entry per fixture IP
   (`10.5.0.1..10.5.0.10` + the singleton `10.5.9.9` probe),
   each with its own token bucket:

   ```yaml
   descriptors:
     - entries: [{ key: client_ip, value: "10.5.0.1" }]
       token_bucket: { max_tokens: 100, tokens_per_fill: 100, fill_interval: 1s }
     # ... 10 more
   ```

   `10.5.9.9`'s bucket is sized the same as the `10.5.0.x`
   pool (100 rps), so the fixture's 10-request probe for that
   IP stays well below the limit.
3. **`always_consume_default_token_bucket: false`** — isolates
   per-IP buckets from the safety-net default.

## Thread model

Same as p03 / p04: shared token bucket across workers (v1.17+
default). `docker-compose.yaml` pins `--concurrency 1`.

## Deviation from POLICIES.md § p05 — enumerated descriptors

**Canonical pool**: 50 000 distinct IPs per §p05.
**Actual**: 11 enumerated descriptors
(`10.5.0.1..10.5.0.10 + 10.5.9.9`). Same root cause as p04 —
envoy v1.32's `local_ratelimit` requires verbatim descriptor
matches; wildcard-value descriptors land in v1.33 via
envoyproxy/envoy#36623.

**Impact on parity**: the filter mechanism, descriptor
extraction, per-IP bucket accounting, 429 stamping and
`Retry-After: 1` header are all exercised. Cardinality is the
only axis the deviation touches.

**Resolution path** (Phase 4): bump the column to ≥ v1.33 and
collapse the list into a wildcard entry, or pair
`local_ratelimit` with a global RLS keyed on `X-Real-IP`.

See `docs/GATEWAYS.md § Deviations → [gw=envoy, p=p04-rl-dynamic-low / p05-rl-dynamic-high, infra=enumerated-descriptors]`
for the full post-mortem (shared with p04).

## Why no standalone "burst produces 429" in `setup.sh`

Same rationale as p03 / p04: envoy bootstraps entirely from
static YAML. The setup script only smoke-tests that a single
below-limit request with `X-Real-IP: 10.5.0.1` returns 200
(exercising the descriptor path, not the default bucket). The
burst probe runs at the default `BURST_PARALLELISM=128`; no
per-gateway override needed.

## Not-yet-exercised

* `Retry-After: 1` stamping is asserted structurally.
* Cardinality beyond 11 IPs — see § Deviation.

Tracking: [`docs/GATEWAYS.md § Deviations`](../../../docs/GATEWAYS.md#deviations).
