// k6/scenarios/s04-rl-static-http.js
//
// Scenario s04-rl-static-http (TASK §4 / docs/POLICIES.md § p04-rl-static):
//
//   Drives the `p04-rl-static` policy — a single 1000 req/s
//   service-wide bucket over a rolling 1 s window. Every path on
//   the gateway shares the same bucket; above the threshold the
//   gateway is required to respond with HTTP 429 + `Retry-After: 1`.
//   This scenario measures how cleanly that limiter engages under
//   load, not whether it exists (that's what parity attestation
//   against `fixtures/p04-rl-static.jsonl` already proved).
//
// HTTP path: GET /anything (same canonical go-httpbin echo endpoint
// as s01; the limiter is attached at the service level, so the exact
// path does not matter — any path shares the one bucket).
// Body: none.
// Auth: none.
// Tags: bench_gateway / bench_policy / bench_scenario / bench_load /
// bench_run_id are auto-attached by `lib/options.js`; nothing extra
// needs to be set here.
//
// Expected signal:
//   - On `p1-baseline` (10 VUs × 60s) total rate stays well below
//     1000 rps and ~100% of responses should be 2xx.
//   - On `p2-sustained` (100 VUs × 5m) and above, the limiter is
//     expected to engage and return 429 for the overflow. The
//     4-bucket classifier in `lib/metrics.js` already counts 429
//     as `policy_4xx_expected`, so no custom accounting is needed
//     here.
//   - 429 is the by-design rejection — we measure how cleanly the
//     limiter engages above 1000 rps; the orchestrator reports the
//     2xx:429 split and the p95 latency of the 2xx slice alone.
//   - The 5xx counter must stay at 0 on p1/p2/p3; p4 may surface
//     non-zero 5xx as the gateway saturates (TASK §8 expects this).

import http from 'k6/http';
import { check } from 'k6';

import { options as resolvedOptions } from '../lib/options.js';
import { targetUrl } from '../lib/env.js';
import { classify } from '../lib/metrics.js';

export const options = resolvedOptions;

// Resolved once at init (k6 init phase), not per-iteration — saves a
// trivial amount of work per request and matches how every other
// scenario will treat its base URL.
const BASE_URL = targetUrl();

export default function () {
    // One request per iteration. No local bursts, no pacing — the
    // active load profile (`p1-baseline` / `p2-sustained` / `p3-ramp`
    // / `p4-stress`) controls concurrency, and the gateway's 1000
    // rps service-wide bucket is what we are probing. Letting the
    // profile drive rps keeps this scenario symmetric with s01 so
    // p04-rl-static latency is directly comparable to p01-vanilla
    // latency on the 2xx slice.
    const res = http.get(`${BASE_URL}/anything`, {
        // Tag every request with the scenario slug too. `bench_scenario`
        // is already on every metric via `lib/options.js`, but keeping
        // it on the request as well makes per-URL drilldowns in the
        // raw stream JSON (when STREAM=1) trivially groupable.
        tags: { url: '/anything' },
    });

    classify(res);

    check(res, {
        // 429 is a by-design outcome for this policy, not a failure.
        // The check passes on either 200 (served under the limit) or
        // 429 (rejected above the limit); anything else — 5xx, 0,
        // other 4xx — fails loudly.
        'status is 200 or 429':                (r) => r.status === 200 || r.status === 429,
        // Happy-path body check: only assert the echoed method on
        // 2xx responses. The 429 body shape is gateway-defined
        // (nginx, envoy, kong, ... all phrase their throttle
        // response differently) and is not the axis we are measuring
        // here, so a 429 short-circuits the check to true.
        'response_body has json.method=GET OR status was 429': (r) => {
            if (r.status === 429) return true;
            try { return JSON.parse(r.body).method === 'GET'; }
            catch { return false; }
        },
    });
}
