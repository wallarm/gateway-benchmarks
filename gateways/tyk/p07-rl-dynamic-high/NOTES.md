# tyk · p07-rl-dynamic-high

## Verdict

**PASS 3/3** on tyk 5.11.1 OSS.

| # | Probe                                                                | Expected            | Verdict |
| - | -------------------------------------------------------------------- | ------------------- | ------- |
| 1 | single request with single IP, below limit                           | `200`               | **PASS** |
| 2 | 10 distinct IPs × 200 rps total burst (limit 100/IP, 2× over)        | ≥200×2xx            | **PASS** |
| 3 | single IP × 500 rps burst (limit 100/IP, ~400 expected 429)          | ≥300×429 ±40        | **PASS** |

Identical mechanism to p05 — JSVM `pre` middleware
(`../_shared/middleware/per_ip_session.js`) synthesises one Tyk
session per `X-Real-IP` value with `rate: 100, per: 1` and re-stamps
the `Authorization` header. Tyk's session-level rate-limit then
enforces 100 rps per key (i.e. per IP).

The only diff against p05 is `BENCH_RL_RATE: "100"` in
`apis/bench.json#config_data` — the JS file is unchanged.

See [`../p06-rl-dynamic-low/NOTES.md`](../p06-rl-dynamic-low/NOTES.md)
for the full mechanism narrative, alternative shapes considered, and
the JSVM gotchas (`TykMakeHttpRequest` casing, mandatory `Domain`,
no `Bearer ` prefix).

## Files in this profile

| Path                  | Role                                                              |
| --------------------- | ----------------------------------------------------------------- |
| `apis/bench.json`     | Tyk Classic API def, identical to p05 except `BENCH_RL_RATE=100`  |
| `setup.sh`            | Readiness + API-loaded check + per-IP smoke probe                 |
| `NOTES.md`            | This document                                                     |
