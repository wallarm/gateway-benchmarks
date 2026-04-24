# `envoy / p05-rl-endpoint` — parity compliance

**Verdict**: `PASS` on `envoyproxy/envoy:distroless-v1.32.6`.

## Canonical policy

From [`docs/POLICIES.md § p04`](../../../docs/POLICIES.md#p04--per-endpoint-static-rate-limit):

- Limit: **100 req/s**, rolling 1 s window.
- Scope: ONE client-visible path (`/anything/limited`).
- Every other path on the same gateway must stay unrestricted.
- Over-limit: `429 Too Many Requests` + `Retry-After: 1`.

## How envoy encodes the scoping

Envoy installs `envoy.filters.http.local_ratelimit` at the HCM
(listener) level with the filter **globally disabled** — the HCM
`filter_enabled.default_value.numerator: 0 / HUNDRED`. Only the
`/anything/limited` route enables the filter via a `typed_per_filter_config`
override, which is a **full replacement** (not a merge) of the
HCM-level config — per the v1.32 LocalRateLimit proto reference.

```yaml
virtual_hosts:
  - routes:
    - match: { prefix: "/anything/limited" }
      route: { cluster: backend_cluster, timeout: 10s }
      typed_per_filter_config:
        envoy.filters.http.local_ratelimit:
          "@type": .../LocalRateLimit
          token_bucket:
            max_tokens: 100
            tokens_per_fill: 5
            fill_interval: 0.05s   # → 100 rps steady refill
          filter_enabled:
            default_value: { numerator: 100, denominator: HUNDRED }
          filter_enforced:
            default_value: { numerator: 100, denominator: HUNDRED }
    - match: { prefix: "/" }
      route: { cluster: backend_cluster, timeout: 10s }
      # No override → inherits HCM config (globally disabled).

http_filters:
  - name: envoy.filters.http.local_ratelimit
    typed_config:
      ...LocalRateLimit
      filter_enabled:
        default_value: { numerator: 0, denominator: HUNDRED }   # OFF
      ...
```

## Bucket shape

Matched to nginx/p04's leaky-bucket:

- `max_tokens: 100` — burst cap (= nginx `burst=100 nodelay`).
- `tokens_per_fill: 5`, `fill_interval: 0.05s` → 100 rps steady refill.

Envoy's smallest `fill_interval` is 50 ms, so 5 tokens per 50 ms
gives the canonical 100 rps at the finest granularity envoy supports.

A naive `max_tokens: 100, tokens_per_fill: 100, fill_interval: 1s`
would dump 100 tokens at the top of every second, inflating the 2xx
count on a sub-second burst that straddles a refill tick. Same
p03 trap as before.

## Observed shape

Under the fixture's ASAP 1200-request burst (`curl --parallel
--parallel-max 128`):

```
probe 3 (/anything/limited):  2xx=112, 429=1088, 5xx=0, other=0
probe 4 (/anything/free):     2xx=1200, 429=0,    5xx=0, other=0
```

Symmetric with nginx/p04 within 5 requests (`2xx=107, 429=1093`),
well above the `status_429_min=150 ± 50` threshold, and the
scoping invariant (probe 4: 0 × 429) holds exactly.

## Deviations

None. The `typed_per_filter_config` idiom fully captures envoy's
native per-route policy attachment primitive — no enumerated
descriptors (p05 / p06 trap), no wildcard-match limitation, no
external RLS dependency.

## Thread model

`--concurrency 0` (auto), same as every other envoy profile in
this bench. `local_ratelimit`'s token bucket is shared across
workers by default (v1.17+, confirmed on p03/p05/p06), so worker
count changes raw throughput but never the effective rate limit.
The 100 rps cap on `/anything/limited` is process-wide, not
per-worker.
