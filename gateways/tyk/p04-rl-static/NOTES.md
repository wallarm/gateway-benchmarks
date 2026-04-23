# tyk · p04-rl-static

## Verdict

**PASS 2/2** on tyk 5.11.1 OSS.

| # | Probe                                  | Expected         | Observed         | Verdict |
| - | -------------------------------------- | ---------------- | ---------------- | ------- |
| 1 | single GET below limit                 | `200`            | `200`            | **PASS** |
| 2 | 1200 req in ~1 s burst on `/anything`  | ≥150×429 ±50     | 203×429 / 997×2xx| **PASS** |

## Native primitive

`global_rate_limit` on the API definition — a single bucket shared by
every path served by `listen_path: /`, evaluated by Tyk's
**Distributed Rate Limiter** (DRL) which is a Redis-backed sliding
window:

```jsonc
{
  "global_rate_limit": { "rate": 1000, "per": 1 }
}
```

`per: 1` is the canonical 1-second window. The DRL coalesces token
hits across Tyk worker goroutines via Redis pipelining, so the limit
is gateway-wide, not per-worker. With 1000 tokens / 1 s and a
~1100 ms burst of 1200 requests, ~200 rejections is the expected
shape and lands inside the 150 ±50 envelope.

Tyk has three rate-limit backends, set in `tyk.standalone.conf`:

* `enable_non_transactional_rate_limiter: true`  → DRL pipeline (our pick)
* `enable_sentinel_rate_limiter: true`           → Redis Sentinel-aware backend
* `enable_redis_rolling_limiter: true`           → strict per-key Redis sliding window

We use the first because it is the upstream default, has the lowest
per-request Redis chatter, and gives the same shape as the rate-limit
benchmarks every other gateway runs.

## Files in this profile

| Path                         | Role                                                 |
| ---------------------------- | ---------------------------------------------------- |
| `apis/bench.json`            | Tyk Classic API def with `global_rate_limit: 1000/1s`|
| `setup.sh`                   | Readiness + API-loaded check + smoke probe           |
| `NOTES.md`                   | This document                                        |
