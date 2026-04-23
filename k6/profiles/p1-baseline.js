// k6/profiles/p1-baseline.js
//
// Load profile p1-baseline (TASK §5, docs/LOAD-PROFILES.md):
//
//   constant 10 VUs × 60s
//
// Purpose: gateway baseline throughput, no thermal effects, no
// connection-pool pressure. The error budget is strictly zero — any
// non-2xx status (apart from policy-shaped 401/403/429) is a real
// regression in the gateway-under-test, not a load artefact.
//
// `discardResponseBodies: false` — body inspection is required for
// the body-rewrite scenarios (p09/p10/p11). Even on s01-vanilla-http
// we keep bodies on so the metrics shape is identical across every
// scenario (otherwise summary tables differ between cells, which
// poisons cycle-to-cycle diffs in Phase 8).
//
// `noConnectionReuse: false` — keep-alive ON per TASK §10.
// `summaryTrendStats` — explicit list so the summary export carries
// p99 + p99.9, which the report generator (Phase 7) needs for the
// tail-latency chart even though p1 traffic rarely surfaces them.

export const options = {
    scenarios: {
        steady: {
            executor: 'constant-vus',
            vus: 10,
            duration: '60s',
            gracefulStop: '5s',
            tags: { bench_load: 'p1-baseline' },
        },
    },
    discardResponseBodies: false,
    noConnectionReuse: false,
    insecureSkipTLSVerify: true,
    summaryTrendStats: ['avg', 'min', 'med', 'p(90)', 'p(95)', 'p(99)', 'p(99.9)', 'max'],
    summaryTimeUnit: 'ms',
    thresholds: {
        // Gateway-fault budget: zero 5xx tolerated on p1.
        policy_5xx_unexpected: ['count==0'],
        // Tail-latency floor: trip the run early if p95 explodes.
        // 200 ms matches the docs/LOAD-PROFILES.md "p1 strict" line.
        http_req_duration: ['p(95)<200'],
    },
};
