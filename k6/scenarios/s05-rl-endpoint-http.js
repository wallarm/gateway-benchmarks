// k6/scenarios/s05-rl-endpoint-http.js
//
// Scenario s05-rl-endpoint-http (TASK §4 / docs/POLICIES.md § p05-rl-endpoint):
//
//   Drives the `p05-rl-endpoint` policy — a 100 req/s rolling 1 s
//   bucket scoped to `/anything/limited` ONLY. Every other path on
//   the same gateway — in particular `/anything/free` — must stay
//   unrestricted. The distinct axis this profile measures is not
//   "can the gateway rate-limit" (that's p04-rl-static) but "can
//   the gateway scope a rate-limit to one route without leaking
//   into its neighbours". Parity against
//   `fixtures/p05-rl-endpoint.jsonl` already proves the shape; this
//   scenario probes it under sustained load.
//
// HTTP path: GET /anything/limited (rate-limited side) and
// GET /anything/free (unrestricted side). Each iteration issues
// ONE request and alternates between the two deterministically via
// `__ITER % 2` so the overall split is 50/50: even iterations probe
// the free side, odd iterations probe the limited side.
// Body: none.
// Auth: none.
// Tags: bench_gateway / bench_policy / bench_scenario / bench_load /
// bench_run_id are auto-attached by `lib/options.js`; the per-request
// `url` tag is set to either `/anything/limited` or `/anything/free`
// so the report generator can break the 2xx / 429 split out per
// endpoint — without that tag the scoping bug this profile is
// designed to catch would be invisible in the aggregate.
//
// Expected signal:
//   - On `p1-baseline` (10 VUs × 60s) both endpoints stay below
//     their limit and ~100% of responses should be 2xx on both
//     sides.
//   - On `p2-sustained` / `p3-ramp` / `p4-stress` the limited side
//     is expected to see 429 above 100 rps; the free side must not.
//   - The free endpoint MUST see 0 × 429. The limited endpoint MUST
//     see 429 above 100 rps. Both signals together prove the limit
//     is scoped correctly — a 429 on `/anything/free` is the exact
//     scoping bug this profile is designed to surface (the limiter
//     leaking into a neighbour route), and the free-side check
//     `status is 200` fails loudly if it happens.
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
    // k6 exposes `__ITER` as a global inside the default function:
    // it's a per-VU iteration counter that increments by one on
    // every invocation. Even → `/anything/free` (unrestricted),
    // odd → `/anything/limited` (the 100 rps bucket). All VUs use
    // the same parity rule so the aggregate split stays 50/50,
    // which makes any observed asymmetry in 429 counts map
    // unambiguously onto one endpoint.
    const isLimited = (__ITER % 2) === 1;
    const path      = isLimited ? '/anything/limited' : '/anything/free';

    const res = http.get(`${BASE_URL}${path}`, {
        // Per-endpoint URL tag so the report generator can break out
        // 2xx / 429 rates per path. The orchestrator keys off this
        // tag; without it the two endpoints would be aggregated and
        // the scoping-leak signal would be silently averaged away.
        tags: { url: path },
    });

    classify(res);

    if (isLimited) {
        check(res, {
            // 429 is a by-design outcome on the limited side above
            // 100 rps. Anything else — 5xx, 0, other 4xx — fails.
            'limited: status is 200 or 429':       (r) => r.status === 200 || r.status === 429,
            // Happy-path body check; 429 short-circuits because the
            // 429 body shape is gateway-defined, same rationale as
            // in s04-rl-static-http.js.
            'limited: response_body has json.method=GET OR status was 429': (r) => {
                if (r.status === 429) return true;
                try { return JSON.parse(r.body).method === 'GET'; }
                catch { return false; }
            },
        });
    } else {
        check(res, {
            // 429 on /anything/free is the scoping bug p05-rl-endpoint
            // is designed to catch — the limiter bleeding past its
            // route selector into a neighbour path. A strict
            // `status === 200` check makes that failure visible in
            // the check-failure rate without any per-bucket
            // post-processing.
            'free: status is 200':                 (r) => r.status === 200,
            'free: response_body has json.method=GET': (r) => {
                try { return JSON.parse(r.body).method === 'GET'; }
                catch { return false; }
            },
        });
    }
}
