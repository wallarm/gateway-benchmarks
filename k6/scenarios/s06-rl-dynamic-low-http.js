// k6/scenarios/s06-rl-dynamic-low-http.js
//
// Scenario s06-rl-dynamic-low-http (TASK §4 / docs/POLICIES.md § p06-rl-dynamic-low):
//
//   Drives the `p06-rl-dynamic-low` policy — a dynamic rate limit of
//   10 req/s keyed by client IP, with a small pool of 100 distinct
//   IPs. The gateway's trust source is the `X-Real-IP` header because
//   a single k6 container cannot rotate physical source addresses;
//   see docs/POLICIES.md § "p05 / p06 — Dynamic rate limit" (the doc
//   still carries the pre-renumber slugs — the canonical directory
//   names today are `gateways/*/p06-rl-dynamic-low/` and
//   `gateways/*/p07-rl-dynamic-high/`, which this scenario and s07
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
//   100 deterministic addresses `10.6.0.0 .. 10.6.0.99`, materialised
//   once at init into `IP_POOL` and rotated by `__ITER % 100` per
//   iteration. 100 short strings × one init per VU is trivial, and
//   holding the pool concrete lets per-iteration rotation stay a
//   single array index lookup. The rotation is deterministic given
//   the iteration order — that is the reproducibility contract (see
//   docs/REPRODUCIBILITY.md).
//
// Expected signal:
//   - 429 saturates once any single IP's 10-req/s bucket fills. On
//     `p2-sustained` (100 VUs × 5m) every IP in the 100-entry pool
//     crosses 10 rps within the first second, so 2xx:429 ratio
//     reflects the gateway's bucket accounting accuracy.
//   - `classify(res)` folds 429 into `policy_4xx_expected` — that
//     counter is the one the report generator plots for this cell;
//     a non-zero `policy_4xx_unexpected` or `policy_5xx_unexpected`
//     is a deviation.
//   - The 5xx counter must stay at 0 on p1/p2/p3; p4 may surface
//     non-zero 5xx as the gateway saturates (TASK §8 expects this).
//   - Tail-latency interest: p95 / p99 / p99.9 on the 2xx subset
//     (the report generator filters by status before plotting).

import http from 'k6/http';
import { check } from 'k6';

import { options as resolvedOptions } from '../lib/options.js';
import { targetUrl } from '../lib/env.js';
import { classify } from '../lib/metrics.js';

export const options = resolvedOptions;

// Resolved once at init (k6 init phase), not per-iteration — same
// treatment as every other scenario gives its base URL.
const BASE_URL = targetUrl();

// 100-entry IP pool materialised once at init. k6's init phase runs
// per VU, but 100 short strings is negligible and keeping the pool
// concrete turns per-iteration rotation into a single array index.
const IP_POOL = (() => {
    const pool = [];
    for (let i = 0; i < 100; i++) {
        pool.push(`10.6.0.${i}`);
    }
    return pool;
})();

export default function () {
    // Deterministic rotation over the 100-entry pool. `__ITER` is
    // the per-VU iteration counter; each VU walks the pool at its
    // own phase but the union across VUs is still a bounded 100-IP
    // set — which is the parity-attestation invariant.
    const ip = IP_POOL[__ITER % IP_POOL.length];

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
