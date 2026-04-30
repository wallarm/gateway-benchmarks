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
        // Gateway-fault budget: zero 5xx tolerated on p1. Correctness
        // is the only SLA — the latency p95 ceiling that lived here
        // (`http_req_duration: p(95)<200`) was removed because it
        // forced k6 exit 99 on every cell where a real gateway hit
        // its capacity wall, which then bubbled up as `K6_FAILED` in
        // aws-clean-cell.sh and excluded the cell from the report.
        // We want to *measure* latency under stress, not fail the
        // run on it; the report renders absolute p50/p95/p99 columns
        // without any SLA gate.
        policy_5xx_unexpected: ['count==0'],
    },
};
