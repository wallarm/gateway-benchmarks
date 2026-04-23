// k6/lib/metrics.js
//
// Custom metrics that mirror the four error categories from
// TASK.md §8. k6's built-in `http_req_failed` collapses every non-2xx
// into one boolean — that's not enough for our matrix, where a 429
// in the rate-limit profiles is *expected* signal (we measure how
// well the limiter kicks in, not how few errors there are).
//
// We therefore expose four explicit counters:
//
//   policy_2xx                 — 200/204/...   (the canonical "good" answer)
//   policy_4xx_expected        — 401/403/429   (policy-shaped responses)
//   policy_4xx_unexpected      — 4xx other than the above three
//   policy_5xx_unexpected      — every 5xx     (gateway/backend fault)
//
// The classification function `classify(res)` picks one bucket per
// response and increments the corresponding counter. The orchestrator
// (Phase 6) reads the summary export and produces the four columns
// shown in docs/REPORT.md.
//
// Keep this file additive. Adding a new category means: (a) define
// the new Counter here, (b) extend `classify(res)`, (c) document the
// rule in docs/REPORT.md § Error Breakdown.

import { Counter } from 'k6/metrics';

export const policy2xx            = new Counter('policy_2xx');
export const policy4xxExpected    = new Counter('policy_4xx_expected');
export const policy4xxUnexpected  = new Counter('policy_4xx_unexpected');
export const policy5xxUnexpected  = new Counter('policy_5xx_unexpected');

// Status codes that count as "expected" 4xx for *any* scenario. Each
// scenario can additionally treat one of these as the dominant signal
// (e.g. p04-rl-static expects 429 to dominate by design).
const EXPECTED_4XX = new Set([401, 403, 429]);

export function classify(res) {
    const s = res.status;
    if (s >= 200 && s < 300) {
        policy2xx.add(1);
    } else if (EXPECTED_4XX.has(s)) {
        policy4xxExpected.add(1);
    } else if (s >= 400 && s < 500) {
        policy4xxUnexpected.add(1);
    } else if (s >= 500) {
        policy5xxUnexpected.add(1);
    } else {
        // Status 0 (client-side: timeout, connection reset, dial fail)
        // is captured by k6's built-in `http_req_failed`; we don't
        // double-count it here. Phase 6 reports the union of the two
        // signals as the "client-side" column.
    }
}
