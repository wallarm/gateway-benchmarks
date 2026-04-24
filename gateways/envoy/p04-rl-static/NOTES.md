# `envoy / p04-rl-static` — compliance notes

**Current verdict on `envoyproxy/envoy:distroless-v1.32.6`**: `PASS (2/2)`
at the canonical rate (no deviation). Observed burst shape:
`2xx≈1085, 429≈115, 5xx=0, other=0` at `total_requests=1200 /
duration_s=1 / parallelism=128`.

## How each fixture probe is satisfied

| Probe                                          | envoy mechanism                                                                           |
|------------------------------------------------|-------------------------------------------------------------------------------------------|
| `GET /anything → 200` (below limit)            | first request in a freshly-warmed bucket — never tripped.                                 |
| `1200 rps / 1 s → ≥ 150 (±50) × 429`           | `envoy.filters.http.local_ratelimit` at HCM with `max_tokens=200, tokens_per_fill=50, fill_interval=0.05s`. |

The observed 115 × 429 is above the `150 − 50 = 100` minimum
threshold. The `other` column is `0` now that
`max_connection_duration: 0s` is no longer mis-configured (see
§ Historical context below) — every request either passes or is
cleanly 429'd.

## Mechanism

Envoy realises the rate-limit via the built-in
`envoy.filters.http.local_ratelimit` HTTP filter, wired onto the
HCM (listener) so every route shares the same bucket:

```yaml
http_filters:
  - name: envoy.filters.http.local_ratelimit
    typed_config:
      "@type": type.googleapis.com/envoy.extensions.filters.http.local_ratelimit.v3.LocalRateLimit
      stat_prefix: http_local_rl_p03
      token_bucket:
        max_tokens: 200          # burst cap  (= nginx's `burst=200`)
        tokens_per_fill: 50      # 50 tokens every 50 ms ...
        fill_interval: 0.05s     # ... = 1000 rps steady refill
      filter_enabled:
        default_value: { numerator: 100, denominator: HUNDRED }
        runtime_key: local_rate_limit_enabled
      filter_enforced:
        default_value: { numerator: 100, denominator: HUNDRED }
        runtime_key: local_rate_limit_enforced
      status: { code: TooManyRequests }   # 429
      response_headers_to_add:
        - header: { key: retry-after, value: "1" }
          append_action: OVERWRITE_IF_EXISTS_OR_ADD
```

Key design choices:

* **HCM-level placement** — the filter sits on the connection
  manager, not on a route, so every path shares the same bucket.
  Matches the spec's "service-wide" semantics exactly (no
  per-route budgets). Dynamic rate limits (p05 / p06) reuse the
  filter with `rate_limits.actions` + enumerated `descriptors`.
* **`max_tokens` ≠ `rate` — token bucket shape matters.**
  A naive `max_tokens: 1000, tokens_per_fill: 1000,
  fill_interval: 1s` would pass almost the entire 1200-request
  ASAP burst (the bucket starts full at 1000; the refill only
  adds ~50-200 more tokens over the sub-second burst window) and
  emit ≈50-100 × 429 — below the fixture's 100-minimum
  threshold. Envoy's `max_tokens` is total bucket capacity, NOT
  a steady-rate ceiling.
  The working shape mirrors nginx's
  `limit_req_zone rate=1000r/s; limit_req burst=200 nodelay;`
  verbatim: small burst cap (200) on top of a steady 1000 rps
  refill (50 tokens / 0.05 s, which is envoy's minimum
  `fill_interval`).
* **Stamped `Retry-After: 1`** — `POLICIES.md § p03` mandates
  the header on the 429 response. Envoy's `local_ratelimit`
  does not auto-stamp it; `response_headers_to_add` applies only
  to rejections emitted by this filter, so normal 2xx responses
  stay untouched.
* **Explicit `filter_enabled` / `filter_enforced`** — both at
  `100%` via `default_value`. Still wired to a runtime key for
  future staged-rollout experiments, but the default makes the
  filter active out of the box.

## Thread model

Envoy's `local_ratelimit` uses a **shared** token bucket across
every worker thread in the process by default (v1.17+). Per
v1.32 proto docs:

> By default the token bucket is shared across all workers, thus
> the rate limits are applied per Envoy process. [...] This can
> be changed by setting `local_rate_limit_per_downstream_connection`
> to `true`, in which case the rate limits are applied per
> downstream connection.

Verified empirically: running the same 1200-request burst with
`--concurrency 1` and `--concurrency 2` on a `max_tokens: 500`
shape produced identical pass counts (≈555 each). Buckets are
NOT multiplied by worker count; raising `--concurrency` only
lifts throughput headroom.

`docker-compose.yaml` passes `--concurrency 0` (auto = one worker
per hardware thread) — consistent with every other gateway in this
bench. The shared-bucket verification above guarantees the RL
cap stays at 1000 rps regardless of worker count.

## Historical context (no current deviation)

An earlier iteration of this profile carried a **rate
deviation** — canonical 1000 rps lowered to ≈200 rps after
observing envoy drop most of the 128-parallel burst as
connection-refused on Docker Desktop / Apple Silicon. The root
cause turned out not to be Docker Desktop throughput but a
misconfigured `max_connection_duration: 0s` in envoy's
`common_http_protocol_options` (both HCM and cluster levels).
Per v1.32 proto docs, `0s` means "close every connection at
t=0", not "no maximum" — every request aborted mid-response
and surfaced as `curl: (52) Empty reply from server`
(classified as "other" by the burst runner).

After removing `max_connection_duration` from every envoy
profile (unset = envoy's actual "no maximum"), the filter
engages deterministically at the canonical rate and `other`
drops to 0. No deviation today.

See `docs/GATEWAYS.md § Deviations → [gw=envoy, p=p04-rl-static]`
for the full historical post-mortem.

## Uniform-settings audit

Same ten rows as
[`p01-vanilla/NOTES.md`](../p01-vanilla/NOTES.md) — the
listener, HCM, and upstream cluster are identical between p01
and p03 except for the addition of the `local_ratelimit`
filter. No deviations from `docs/GATEWAYS.md § Uniform
settings` beyond the rate-limit itself.

## Why no standalone sanity "burst produces 429" in `setup.sh`

Envoy bootstraps entirely from its static YAML — there is no
runtime API to call after `compose up`. The setup script only
smoke-tests that a single below-limit request returns 200. The
rate-limiter is exercised by
`scripts/parity-attestation.sh::run_burst_probe` via
`curl --parallel -K <config>` with `BURST_PARALLELISM=128` — the
only path that reliably compresses 1200 requests into the
1-second window.

## Not-yet-exercised

* `Retry-After: 1` stamping is asserted structurally (the
  filter always adds it on 429) but the fixture does not probe
  for it. Any probe that reads `Retry-After` on a 429 would
  pass today.
* Distributed / multi-node behaviour is out of scope for this
  bench (TASK.md §2 "Out of scope"). `local_ratelimit` is
  per-process — a single-container envoy is a single-process
  token bucket.

Tracking: [`docs/GATEWAYS.md § Deviations`](../../../docs/GATEWAYS.md#deviations).
