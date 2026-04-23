// k6/scenarios/s01-vanilla-http.js
//
// Scenario s01-vanilla-http (TASK §4 / docs/POLICIES.md § p01):
//
//   Drives the `p01-vanilla` policy — pure proxy, no policies
//   applied. Measures the *baseline* overhead of every gateway:
//   the cost of the proxy hop itself, with no JWT, no rate-limit,
//   no body or header rewrite in the way.
//
// HTTP path: GET /anything (the canonical go-httpbin echo endpoint).
// Body: none.
// Auth: none.
// Tags: bench_gateway / bench_policy / bench_scenario / bench_load /
// bench_run_id are auto-attached by `lib/options.js`; nothing extra
// needs to be set here.
//
// Expected signal:
//   - 100% of responses should be 2xx (the gateway has nothing to
//     reject and the backend's /anything always answers 200).
//   - The 5xx counter must stay at 0 on p1/p2/p3; p4 may surface
//     non-zero 5xx as the gateway saturates (TASK §8 expects this).
//   - Tail-latency interest: p95 / p99 / p99.9 (the report generator
//     plots these per-gateway side by side).

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
    const res = http.get(`${BASE_URL}/anything`, {
        // Tag every request with the scenario slug too. `bench_scenario`
        // is already on every metric via `lib/options.js`, but keeping
        // it on the request as well makes per-URL drilldowns in the
        // raw stream JSON (when STREAM=1) trivially groupable.
        tags: { url: '/anything' },
    });

    classify(res);

    check(res, {
        'status is 200':                       (r) => r.status === 200,
        'response_body has json.method=GET':   (r) => {
            try { return JSON.parse(r.body).method === 'GET'; }
            catch { return false; }
        },
    });
}
