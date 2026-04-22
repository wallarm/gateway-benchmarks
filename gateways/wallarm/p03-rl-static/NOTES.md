# `wallarm / p03-rl-static` — implementation notes

**Status against `wallarm/api-gateway:0.2.0`**: `PASS` with a documented deviation.

## Canonical spec ([`docs/POLICIES.md § p03`](../../../docs/POLICIES.md#p03--static-rate-limit))

- Limit: **1000 req/s** per service, rolling window = 1 second.
- Key: the service itself (all requests share one bucket).
- Above-limit behaviour: HTTP **429** with `Retry-After: 1`.

## Wallarm binding

The built-in `ratelimit` policy is bound on the **service flow**
(`POST /services/bench-anything/flow`) — one bucket for every route
of the service:

```json
{
  "request_flow": [{
    "policy_id":   "ratelimit",
    "policy_name": "bench-p03-rl-static",
    "config": {
      "ratelimit_key": "bench-p03",
      "rate":          1000,
      "window":        1,
      "window_type":   "sliding",
      "scope":         "service"
    }
  }]
}
```

## Deviation: `window_type` = `sliding` instead of `fixed`

During Phase 3b bring-up we probed every `rate / window` combination
against the pinned image. `window_type: fixed` works reliably for
`window >= 10`, but for `window = 1` **no 429 is ever issued** on
`wallarm/api-gateway:0.2.0@sha256:a3d4d2f7…`, even at 1500 rps:

```bash
# fixed, window=1, rate=1000
seq 1 1500 | xargs -n1 -P 256 -I{} curl -so /dev/null -w '%{http_code}\n' \
    http://localhost:9080/anything | sort | uniq -c
#   1500 200       ← rate limit is effectively a no-op
```

Switching to `window_type: sliding` (same `rate=1000, window=1`)
produces the expected above-limit 429s:

```bash
# sliding, window=1, rate=1000
# 1239 200
#  261 429         ← rate limit engages as designed
```

The PRD wording is ["rolling 1-second window"](../../../docs/POLICIES.md#p03--static-rate-limit),
so `sliding` is arguably closer to the spec than `fixed` — we treat
this as a **behavioural deviation** worth recording, not as a
departure from intent. The same integration-test
[`tests/integration/single_node_ratelimit_accuracy_test.sh`](
https://github.com/wallarm/wallarm-api-gateway/blob/main/tests/integration/single_node_ratelimit_accuracy_test.sh)
never exercises `window=1` — the smallest window tested in the
upstream suite is 60 seconds.

Tracking: [docs/GATEWAYS.md § deviations](../../../docs/GATEWAYS.md#deviations).

## Layout

```
gateways/wallarm/p03-rl-static/
├── NOTES.md            ← this file
├── gateway.yaml        ← baseline settings (no policies here)
└── setup.sh            ← Admin-API bootstrap (service + route + ratelimit flow)
```

`setup.sh` also has env-var overrides: `RL_RATE`, `RL_WINDOW`,
`RL_WINDOW_TYPE`, `RL_KEY` — handy for diagnostics.

## Running

```bash
make parity-gateway PARITY_GATEWAY=wallarm PARITY_PROFILE=p03-rl-static
```

The parity script fires the two probes from
[`fixtures/p03-rl-static.jsonl`](../../../fixtures/p03-rl-static.jsonl):

1. `single request below limit → 200`
2. `burst 1200 rps within 1s → ≥ 150 × 429 (± 50)`

Both pass on the pinned image with `window_type: sliding`.
