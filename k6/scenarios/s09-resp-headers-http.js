// k6/scenarios/s09-resp-headers-http.js
//
// Scenario s09-resp-headers-http (TASK §4 / docs/POLICIES.md § p09-resp-headers):
//
//   Drives the `p09-resp-headers` policy — the gateway adds
//   `X-Bench-Out: 1` to the response on its way back to the client
//   and strips `Server` from the upstream's response. Measures the
//   cost of an in-band response-header rewrite (one add, one drop)
//   layered on top of the pure-proxy baseline established by s01.
//
// HTTP path: GET /response-headers?Server=should-be-dropped.
// go-httpbin's `/response-headers` endpoint reflects query-string
// values into real response headers, which is how we get a
// guaranteed `Server` header on every upstream response — the
// gateway must strip it on the way out and the client must never
// see it.
// Body: none.
// Auth: none.
// Tags: bench_gateway / bench_policy / bench_scenario / bench_load /
// bench_run_id are auto-attached by `lib/options.js`; the scenario
// pins `url=/response-headers` so per-URL drilldowns in the raw
// stream JSON (when STREAM=1) stay trivially groupable.
//
// Expected signal:
//   - 100% of responses should be 2xx. The header rewrite is an
//     in-band transform, not a rejection — the gateway never fails
//     a request because of it, and go-httpbin's /response-headers
//     always answers 200.
//   - The correctness check verifies CORRECT ECHO SHAPE only
//     (client sees `X-Bench-Out: 1`, client does not see
//     `Server`). It does not assert anything about latency tails;
//     p95 / p99 / p99.9 fall out of the summary export
//     automatically and the report generator plots them
//     per-gateway side by side.
//   - The 5xx counter must stay at 0 on p1/p2/p3; p4 may surface
//     non-zero 5xx as the gateway saturates (TASK §8 expects this).

import http from 'k6/http';
import { check } from 'k6';

import { options as resolvedOptions } from '../lib/options.js';
import { targetUrl } from '../lib/env.js';
import { classify } from '../lib/metrics.js';

export const options = resolvedOptions;

const BASE_URL = targetUrl();

export default function () {
    const res = http.get(`${BASE_URL}/response-headers?Server=should-be-dropped`, {
        tags: { url: '/response-headers' },
    });

    classify(res);

    check(res, {
        'status is 200': (r) => r.status === 200,
        'client sees X-Bench-Out: 1': (r) => {
            // k6's `res.headers` is a plain object keyed by the
            // canonical-cased header name (e.g. `X-Bench-Out`),
            // but we also probe the lower-case key to stay robust
            // against k6-build differences in how incoming header
            // names are normalized.
            const val = r.headers['X-Bench-Out'] || r.headers['x-bench-out'];
            return val === '1';
        },
        'client does not see Server': (r) =>
            r.headers['Server'] === undefined
            && r.headers['server'] === undefined,
    });
}
