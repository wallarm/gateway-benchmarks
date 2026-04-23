// k6/profiles/p3-ramp.js
//
// Load profile p3-ramp (TASK §5, docs/LOAD-PROFILES.md):
//
//   ramp 10 → 100 → 300 → 500 VUs (3 × 60s steps),
//   hold at 500 VUs for 180s,
//   ramp 500 → 0 in 60s
//   total: 480s
//
// Purpose: tail-latency behaviour at ramp transitions, surfacing
// connection-pool bugs (e.g. nginx's `proxy_http_version 1.0`
// silently disabling keep-alive — every step would then 1.4× the
// upstream socket count instead of reusing).
//
// Threshold is the loosest of the four profiles because ramp
// transients are real and expected. The 5xx budget is still zero —
// pool exhaustion should manifest as client-side timeout (k6's
// `http_req_failed`), not as upstream 5xx.

export const options = {
    scenarios: {
        ramp: {
            executor: 'ramping-vus',
            startVUs: 10,
            stages: [
                { duration: '60s',  target: 100 },
                { duration: '60s',  target: 300 },
                { duration: '60s',  target: 500 },
                { duration: '180s', target: 500 },
                { duration: '60s',  target: 0   },
            ],
            gracefulRampDown: '15s',
            gracefulStop: '15s',
            tags: { bench_load: 'p3-ramp' },
        },
    },
    discardResponseBodies: false,
    noConnectionReuse: false,
    insecureSkipTLSVerify: true,
    summaryTrendStats: ['avg', 'min', 'med', 'p(90)', 'p(95)', 'p(99)', 'p(99.9)', 'max'],
    summaryTimeUnit: 'ms',
    thresholds: {
        policy_5xx_unexpected: ['count==0'],
        http_req_duration: ['p(95)<500'],
    },
};
