// k6/scenarios/s10-req-body-http.js
//
// Scenario s10-req-body-http (TASK §4 / docs/POLICIES.md § p10-req-body):
//
//   Drives the `p10-req-body` policy — the gateway parses the
//   client's JSON request body, adds `$.bench.injected = true`,
//   drops `$.secret`, then forwards the rewritten body upstream.
//   Measures the cost of an in-band request-body rewrite (parse +
//   mutate + re-serialize + recompute Content-Length) layered on
//   top of the pure-proxy baseline established by s01.
//
// HTTP path: POST /anything (go-httpbin's full-request echo
// endpoint; the raw JSON body the backend received is echoed
// under `.json` in the response, which is how we prove the
// rewrite actually fired at the gateway and not just at k6's
// checking code).
// Body: canonical `p09RequestBody` from `lib/payloads.js`. The
// symbol name is historical — it tracks an older policy ordinal;
// the current policy slug is `p10-req-body` and the frozen body
// shape there is the definitive wire format.
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
//     (backend saw `bench.injected = true`, backend did not see
//     `secret`, and the untouched field `msg = 'hello'` passed
//     through intact). It does not assert anything about latency
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
import { p09RequestBody } from '../lib/payloads.js';

export const options = resolvedOptions;

const BASE_URL = targetUrl();

// Serialize the canonical body once at init (k6 init phase), not
// per-iteration — the payload is frozen in `lib/payloads.js` so
// the wire shape is stable across every iteration and every VU,
// and stringifying once saves a trivial amount of work per
// request.
const REQUEST_BODY = JSON.stringify(p09RequestBody);

export default function () {
    const res = http.post(`${BASE_URL}/anything`, REQUEST_BODY, {
        headers: { 'Content-Type': 'application/json' },
        tags: { url: '/anything' },
    });

    classify(res);

    check(res, {
        'status is 200': (r) => r.status === 200,
        'backend echo shows bench.injected=true and no secret': (r) => {
            try {
                const body = JSON.parse(r.body);
                const j = body.json;
                if (!j || typeof j !== 'object') return false;
                return j.bench
                    && j.bench.injected === true
                    && j.secret === undefined
                    && j.msg === 'hello';
            } catch { return false; }
        },
    });
}
