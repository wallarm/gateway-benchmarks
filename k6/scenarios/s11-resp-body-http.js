// k6/scenarios/s11-resp-body-http.js
//
// Scenario s11-resp-body-http (TASK §4 / docs/POLICIES.md § p11-resp-body):
//
//   Drives the `p11-resp-body` policy — the gateway parses the
//   upstream's JSON response body, adds `$.bench.injected = true`,
//   drops `$.origin`, then serves the rewritten body back to the
//   client. Measures the cost of an in-band response-body rewrite
//   (parse + mutate + re-serialize + recompute Content-Length)
//   layered on top of the pure-proxy baseline established by s01.
//
// HTTP path: GET /anything (go-httpbin's full-request echo
// endpoint; every response has top-level `.method`, `.url`,
// `.origin`, `.headers`, which means the gateway's drop rule is
// always exercised — `origin` is always present on the way out
// until the gateway removes it).
// Body: none (this is a response-body rewrite, so the client
// never sends a body).
// Auth: none.
// Tags: bench_gateway / bench_policy / bench_scenario / bench_load /
// bench_run_id are auto-attached by `lib/options.js`; the scenario
// pins `url=/anything` so per-URL drilldowns in the raw stream
// JSON (when STREAM=1) stay trivially groupable.
//
// Expected signal:
//   - 100% of responses should be 2xx. The body rewrite is an
//     in-band transform, not a rejection — the gateway never
//     fails a request because of it, and go-httpbin's /anything
//     always answers 200.
//   - The correctness check verifies CORRECT ECHO SHAPE only
//     (client sees `bench.injected = true`, client does not see
//     `origin`, and the untouched field `method = 'GET'` is
//     preserved). It does not assert anything about latency
//     tails; p95 / p99 / p99.9 fall out of the summary export
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
    const res = http.get(`${BASE_URL}/anything`, {
        tags: { url: '/anything' },
    });

    classify(res);

    check(res, {
        'status is 200': (r) => r.status === 200,
        'response body shows bench.injected=true and no origin': (r) => {
            try {
                const body = JSON.parse(r.body);
                return body.bench
                    && body.bench.injected === true
                    && body.origin === undefined
                    && body.method === 'GET';
            } catch { return false; }
        },
    });
}
