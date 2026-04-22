# wallarm / p04-rl-dynamic-low — notes

Canonical policy — [`docs/POLICIES.md` §
p04](../../../docs/POLICIES.md):

```
10 req/s per client IP, rolling 1-second window, key = X-Real-IP
```

## What we ship

Wallarm `0.2.0` supports dynamic rate-limit keys via **context
expressions** in the `ratelimit` policy config
(`admin-api-openapi.yaml` → `PolicyBinding.config`, example
`ratelimit_key: "${request.headers.x-api-key}"`). The same idiom
is exercised end-to-end by
[`single_node_ratelimit_accuracy_test.sh`](../../../../wallarm-api-gateway/tests/integration/single_node_ratelimit_accuracy_test.sh)
in the upstream suite, so the path is known-good.

- `policy_id:      "ratelimit"`
- `policy_name:    "bench-p04-rl-dynamic-low"`
- `flow:           request_flow` (service level)
- `config.ratelimit_key: "${request.headers.x-real-ip}"`
- `config.rate:           10`
- `config.window:         1`
- `config.window_type:    "sliding"`
- `config.scope:          "service"`

### Why `scope: "service"`

`scope` controls the *namespace* of the buckets, not the bucket
partition itself. Buckets inside that namespace are always
partitioned by the resolved `ratelimit_key` value. Choosing
`service` keeps the per-IP buckets isolated to this profile's
service (so p03/p05 cannot bleed counters in) while still giving
every distinct `X-Real-IP` its own bucket — which is exactly the
"per-IP 10 rps" semantics from POLICIES.md.

### Why `window_type: "sliding"`

Same reason as [p03](../p03-rl-static/NOTES.md): on the pinned
`0.2.0` image, `fixed` + `window=1` is effectively a no-op (the
accuracy-test suite only exercises `fixed` with `window ≥ 10`).
`sliding` with `window=1` produces the textbook rolling-window
behaviour and lines up perfectly with the math — see below.

## Parity result

Against `wallarm/api-gateway:0.2.0` (native arch):

```
==> parity: gateway=wallarm profile=p04-rl-dynamic-low target=http://localhost:9080
    fixture: fixtures/p04-rl-dynamic-low.jsonl
  ✓ PASS   single request with single IP below limit -> 200
  ✓ PASS   10 IPs x 15 rps x 3s -> ~150 total 429  [burst: 450x, 2xx=99 429=351 5xx=0]
verdict: PASS  (2/2)
```

Sanity check: 10 IPs × limit 10 rps = **100 × 2xx** in the best
case. The harness fires the burst as fast as its 128 concurrent
workers can manage (`elapsed_s ≈ 0`, so all 450 reqs hit the
gateway inside a single sliding window), which means every IP
has ~45 in-flight requests, the first 10 get 200 and the next 35
get 429. Cross-IP total: `100 × 2xx, 350 × 429`. Observed:
`99 × 2xx, 351 × 429` — a one-request drift that is well within
the accuracy of a sliding-window counter.

## Deviation: burst runner ignores `duration_s`

The fixture says "10 IPs × 15 rps × 3 s", but
[`scripts/parity-attestation.sh::run_burst_probe`](../../../scripts/parity-attestation.sh)
fires every request as fast as curl can open connections — it does
**not** pace them across `duration_s`. The parity check is still
sound because the **per-window** invariant ("≤ 10 × 2xx per IP
within any 1 s sliding window") is stricter under an ASAP burst
than under a paced 3 s trickle.

This is a property of the parity harness, not of wallarm. Phase 4
load profiles (`k6`) will use paced arrivals when the real benchmark
numbers are produced — parity only certifies correctness, not the
RPS you would get at steady state.
