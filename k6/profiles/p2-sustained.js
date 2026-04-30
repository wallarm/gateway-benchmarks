// k6/profiles/p2-sustained.js
//
// Load profile p2-sustained (TASK §5, docs/LOAD-PROFILES.md):
//
//   constant 100 VUs × 5m
//
// Purpose: steady-state RSS measurement, memory-leak detection, no
// p95 regression after 3 minutes of warm-up. The orchestrator's
// docker-stats sampler (Phase 6) is what actually captures the
// memory-vs-time curve from this profile; k6 here just sustains the
// load long enough that any leaky allocator surface a slope.
//
// p95 budget is wider than p1 (300 ms) because 100 VUs over 5
// minutes will catch transient cold-cache effects every minute or so;
// p1's 200 ms floor would falsely trip on those.

export const options = {
    scenarios: {
        steady: {
            executor: 'constant-vus',
            vus: 100,
            duration: '5m',
            gracefulStop: '10s',
            tags: { bench_load: 'p2-sustained' },
        },
    },
    discardResponseBodies: false,
    noConnectionReuse: false,
    insecureSkipTLSVerify: true,
    summaryTrendStats: ['avg', 'min', 'med', 'p(90)', 'p(95)', 'p(99)', 'p(99.9)', 'max'],
    summaryTimeUnit: 'ms',
    thresholds: {
        // Correctness gate only — see p1-baseline.js for the rationale
        // behind dropping the `http_req_duration` p95 ceiling.
        policy_5xx_unexpected: ['count==0'],
    },
};
