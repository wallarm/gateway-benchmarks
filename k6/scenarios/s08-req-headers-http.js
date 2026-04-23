// k6/scenarios/s08-req-headers-http.js
//
// Scenario s08-req-headers-http (TASK §4 / docs/POLICIES.md § p08-req-headers):
//
//   Drives the `p08-req-headers` policy — the gateway adds
//   `X-Bench-In: 1` to the request and strips `X-Forwarded-For`
//   before the request ever reaches the upstream. Measures the
//   cost of an in-band request-header rewrite (one add, one drop)
//   layered on top of the pure-proxy baseline established by s01.
//
// HTTP path: GET /headers (go-httpbin's request-header echo
// endpoint — the observed request headers are returned under
// `.headers` in the JSON response body, which is how we prove the
// rewrite actually fired at the gateway and not just at k6's
// checking code).
// Body: none.
// Auth: none.
// Tags: bench_gateway / bench_policy / bench_scenario / bench_load /
// bench_run_id are auto-attached by `lib/options.js`; the scenario
// pins `url=/headers` so per-URL drilldowns in the raw stream JSON
// (when STREAM=1) stay trivially groupable.
//
// Expected signal:
//   - 100% of responses should be 2xx. The header rewrite is an
//     in-band transform, not a rejection — the gateway never fails
//     a request because of it, and go-httpbin's /headers always
//     answers 200.
//   - The correctness check verifies CORRECT ECHO SHAPE only
//     (backend saw `X-Bench-In: 1`, backend did not see
//     `X-Forwarded-For`). It does not assert anything about
//     latency tails; p95 / p99 / p99.9 fall out of the summary
//     export automatically and the report generator plots them
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
    const res = http.get(`${BASE_URL}/headers`, {
        // `X-Forwarded-For` is the header the gateway MUST drop
        // before forwarding upstream. We send it on every request
        // so the backend's echo gives us a clean positive signal
        // if the drop rule fails — the header would reappear in
        // `body.headers` and the second check would flip to false.
        headers: { 'X-Forwarded-For': '198.51.100.7' },
        tags: { url: '/headers' },
    });

    classify(res);

    check(res, {
        'status is 200': (r) => r.status === 200,
        'backend saw X-Bench-In: 1': (r) => {
            try {
                const body = JSON.parse(r.body);
                const h = body.headers || {};
                // go-httpbin normalizes request-header keys to
                // canonical Title-Case-With-Dashes, but we also
                // probe the lower-case key so the scenario keeps
                // working if a future backend build flips that
                // convention.
                const val = h['X-Bench-In'] || h['x-bench-in'];
                return val === '1';
            } catch { return false; }
        },
        'backend did not see X-Forwarded-For': (r) => {
            try {
                const body = JSON.parse(r.body);
                const h = body.headers || {};
                return h['X-Forwarded-For'] === undefined
                    && h['x-forwarded-for'] === undefined;
            } catch { return false; }
        },
    });
}
