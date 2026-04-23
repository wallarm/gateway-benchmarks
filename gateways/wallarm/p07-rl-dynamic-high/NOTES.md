# wallarm / p07-rl-dynamic-high — notes

Canonical policy — [`docs/POLICIES.md` §
p06](../../../docs/POLICIES.md):

```
100 req/s per client IP, rolling 1-second window, key = X-Real-IP
IP pool size (at the load side): 50 000
```

## What we ship

Same vehicle as [p05](../p06-rl-dynamic-low/NOTES.md) — the built-in
`ratelimit` policy with a `${request.headers.x-real-ip}` context
expression — only the `rate` parameter changes.

- `policy_id:      "ratelimit"`
- `policy_name:    "bench-p07-rl-dynamic-high"`
- `flow:           request_flow` (service level)
- `config.ratelimit_key: "${request.headers.x-real-ip}"`
- `config.rate:           100`
- `config.window:         1`
- `config.window_type:    "sliding"`
- `config.scope:          "service"`

See [`p06-rl-dynamic-low/NOTES.md`](../p06-rl-dynamic-low/NOTES.md)
for the rationale behind `scope: "service"` and
`window_type: "sliding"` on the current build — both are identical here.

## Parity result

Against the Wallarm API Gateway (native arch):

```
==> parity: gateway=wallarm profile=p07-rl-dynamic-high target=http://localhost:9080
    fixture: fixtures/p07-rl-dynamic-high.jsonl
  ✓ PASS   single request with single IP below limit -> 200
  ✓ PASS   10 distinct IPs x 200 rps -> all 200   [burst: 200x, 2xx=200 429=0 5xx=0]
  ✓ PASS   single IP x 500 rps -> at least 300 x 429  [burst: 500x, 2xx=100 429=400 5xx=0]
verdict: PASS  (3/3)
```

Sanity checks:

- Probe 2 (10 IPs × 20 rps each, 100/IP limit): every IP stays
  under its own bucket, so the burst is expected to be
  **all 2xx**. Observed: `200 × 2xx, 0 × 429` — exact.
- Probe 3 (1 IP × 500 rps, 100/IP limit): the single bucket admits
  the first 100 requests and 429s the rest. Observed:
  `100 × 2xx, 400 × 429` — to-the-request accuracy from the
  sliding counter.

## IP pool size in parity vs. load

POLICIES.md calls out `50 000 distinct IPs` at the load side. In
parity we use the much smaller `10.5.0.1..10.5.0.10` (and a single
saturating IP) to keep the runner portable — the functional
invariants ("bucket per key", "≥ 300 × 429 when one IP saturates")
hold for any pool size. The full 50 000-IP pool ships with the Phase
4 k6 load profile and is what produces the *actual* steady-state
RPS numbers in the report.

## Deviation: burst runner ignores `duration_s`

Same caveat as [p05](../p06-rl-dynamic-low/NOTES.md) — the parity
harness fires requests ASAP rather than pacing them over
`duration_s`. The stricter burst reading is still a valid pass
condition for the per-window invariant.
