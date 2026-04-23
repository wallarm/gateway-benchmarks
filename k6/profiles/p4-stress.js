// k6/profiles/p4-stress.js
//
// Load profile p4-stress (TASK §5, docs/LOAD-PROFILES.md):
//
//   constant 1000 VUs × 120s
//
// Purpose: gateway saturation point. **Non-zero errors are expected**
// — backpressure 503/504 from upstream-pool exhaustion, k6 client
// timeouts as the gateway accept queue saturates. The interesting
// signal is *which kind* of error dominates and at *what* RPS the
// curve flattens; the orchestrator's error-classifier (Phase 6) does
// the actual breakdown.
//
// Therefore p4 has **no** absolute thresholds. The 5xx counter is
// still observed but isn't a hard fail; the report colours cells
// where 5xx exceeds 1% red without aborting the run.

export const options = {
    scenarios: {
        stress: {
            executor: 'constant-vus',
            vus: 1000,
            duration: '120s',
            gracefulStop: '15s',
            tags: { bench_load: 'p4-stress' },
        },
    },
    discardResponseBodies: false,
    noConnectionReuse: false,
    insecureSkipTLSVerify: true,
    summaryTrendStats: ['avg', 'min', 'med', 'p(90)', 'p(95)', 'p(99)', 'p(99.9)', 'max'],
    summaryTimeUnit: 'ms',
    // No `thresholds` block on purpose — see header comment.
};
