// k6/scenarios/s07-rl-dynamic-high-http.js
//
// Scenario s07-rl-dynamic-high-http (TASK §4 / docs/POLICIES.md § p07-rl-dynamic-high):
//
//   Drives the `p07-rl-dynamic-high` policy — a dynamic rate limit
//   of 100 req/s keyed by client IP, with a large pool of 50 000
//   distinct IPs. The gateway's trust source is the `X-Real-IP`
//   header because a single k6 container cannot rotate physical
//   source addresses; see docs/POLICIES.md § "p05 / p06 — Dynamic
//   rate limit" (the doc still carries the pre-renumber slugs — the
//   canonical directory names today are
//   `gateways/*/p06-rl-dynamic-low/` and
//   `gateways/*/p07-rl-dynamic-high/`, which s06 and this scenario
//   drive respectively).
//
// HTTP path: GET /anything (the canonical go-httpbin echo endpoint).
// Body: none.
// Auth: none.
// Tags: bench_gateway / bench_policy / bench_scenario / bench_load /
// bench_run_id are auto-attached by `lib/options.js`; nothing extra
// needs to be set here.
//
// IP pool convention:
//   50 000 deterministic addresses in the `10.7.0.0/16` space,
//   indexed `0 .. 49999` and mapped as `10.7.<b>.<c>` where
//   `b = floor(idx / 256)` and `c = idx % 256`. The pool therefore
//   spans `10.7.0.0 .. 10.7.195.79` (50000 = 195 × 256 + 80) — 50k
//   distinct IPs, which satisfies the "50 000 distinct IPs" spec.
//   Generated on the fly by `pickIp(__ITER)` per iteration rather
//   than materialised: 50 000 short strings × one k6 init per VU
//   would be ~1 MB × VU wasted when a `Math.floor` + modulo pair
//   gives the same determinism for free.
//
// Expected signal:
//   - With a 50 000-IP pool and a 100-req/s per-IP bucket, the load
//     profiles stay BELOW the per-IP cap on `p1/p2/p3` (aggregate
//     rate ÷ 50000 ≪ 100), so this scenario measures throughput
//     overhead of a 50k-key counter table, not rejection. 429 on
//     `p4-stress` is expected as the gateway saturates.
//   - `classify(res)` folds 429 into `policy_4xx_expected`, so the
//     report generator can plot the (mostly zero on p1/p2/p3)
//     rejection curve separately from unexpected 4xx / 5xx.
//   - The 5xx counter must stay at 0 on p1/p2/p3; p4 may surface
//     non-zero 5xx as the gateway saturates (TASK §8 expects this).
//   - Tail-latency interest: p95 / p99 / p99.9 on the 2xx subset —
//     the counter-table lookup cost is exactly what this cell
//     surfaces.

import http from 'k6/http';
import { check } from 'k6';

import { options as resolvedOptions } from '../lib/options.js';
import { targetUrl } from '../lib/env.js';
import { classify } from '../lib/metrics.js';

export const options = resolvedOptions;

// Resolved once at init (k6 init phase), not per-iteration — same
// treatment as every other scenario gives its base URL.
const BASE_URL = targetUrl();

// 50 000-entry IP generator. 50000 / 256 = 195 remainder 80, so the
// pool spans `10.7.0.0 .. 10.7.195.79`. A generator instead of a
// materialised array keeps VU init cheap (the array alternative is
// ~50k strings × N VUs — trivial for small N, wasteful at stress).
function pickIp(iter) {
    const idx = iter % 50000;
    const b = Math.floor(idx / 256);   // 0 .. 195
    const c = idx % 256;               // 0 .. 255
    return `10.7.${b}.${c}`;
}

export default function () {
    // Deterministic rotation over the 50 000-entry generator.
    // `__ITER` is the per-VU iteration counter; each VU walks the
    // generator at its own phase but the union across VUs is still
    // the bounded 50 000-IP set that the parity attestation fires
    // its probes against.
    const ip = pickIp(__ITER);

    const res = http.get(`${BASE_URL}/anything`, {
        headers: { 'X-Real-IP': ip },
        // Tag every request with the URL too. `bench_scenario` is
        // already on every metric via `lib/options.js`, but keeping
        // the URL tag on the request makes per-URL drilldowns in
        // the raw stream JSON (when STREAM=1) trivially groupable.
        tags:    { url: '/anything' },
    });

    classify(res);

    check(res, {
        'status is 200 or 429': (r) => r.status === 200 || r.status === 429,
    });
}
