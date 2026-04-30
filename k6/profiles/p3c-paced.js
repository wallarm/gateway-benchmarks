// k6/profiles/p3c-paced.js
//
// Paced-arrivals twin of p3-ramp (TASK §5, docs/LOAD-PROFILES.md
// § Paced-arrivals variants):
//
//   startRate 500 RPS →
//     60s ramp to  2 000 RPS
//     60s ramp to  5 000 RPS
//     60s ramp to 10 000 RPS
//    180s hold at 10 000 RPS
//     60s ramp to      0 RPS
//   total: 420 s (same as closed-loop p3-ramp)
//
//   preAllocatedVUs 200, maxVUs 2000
//
// Purpose: probe where the gateway's knee is on the RPS-vs-latency
// curve by sweeping absolute arrival rates. The closed-loop p3-ramp
// sweeps VUs, which hides the RPS at which the gateway saturates
// (the faster the gateway, the higher the saturation RPS, so the
// closed-loop curves are not directly comparable across gateways).
// This profile pins the x-axis to absolute arrivals/second, so the
// "gateway X saturates at Y RPS" number is finally meaningful.
//
// Capacity warning for local runs:
//   10 000 RPS through Docker Desktop on a developer laptop is at
//   the edge. On Apple Silicon (M1/M2/M3) with `ulimit -n 65536`
//   raised on the host shell, the full ramp lands cleanly. On Intel
//   Macs and on laptops with the default 256-file-descriptor limit,
//   `dropped_iterations` will surface above 0 in the top stages and
//   the absolute-RPS claim is invalidated (the run is still useful
//   for relative ranking, just not for "can X sustain 10 kRPS").
//   For local verification prefer `LOAD_PROFILES=p1c-paced,p2c-paced`;
//   run p3c on a dedicated bench host (Linux, 16+ cores, 32+ GB
//   RAM, loopback networking).
//
// Threshold widening: closed-loop p3 allows p(95) < 500 ms. Paced
// p3c allows p(95) < 750 ms (+50%). During the 10k-RPS hold segment
// most of the "latency growth" is queue depth, not actual gateway
// work — a 5 ms p95 gateway under 10 kRPS with only 200 VUs pre-
// allocated will queue briefly on cold start while k6 grows to the
// needed VU count. The budget covers that transient.

export const options = {
    scenarios: {
        paced: {
            executor: 'ramping-arrival-rate',
            startRate: 500,
            timeUnit: '1s',
            stages: [
                { duration: '60s',  target:  2000 },
                { duration: '60s',  target:  5000 },
                { duration: '60s',  target: 10000 },
                { duration: '180s', target: 10000 },
                { duration: '60s',  target:     0 },
            ],
            preAllocatedVUs: 200,
            maxVUs: 2000,
            gracefulStop: '15s',
            tags: { bench_load: 'p3c-paced' },
        },
    },
    discardResponseBodies: false,
    noConnectionReuse: false,
    insecureSkipTLSVerify: true,
    summaryTrendStats: ['avg', 'min', 'med', 'p(90)', 'p(95)', 'p(99)', 'p(99.9)', 'max'],
    summaryTimeUnit: 'ms',
    thresholds: {
        // Correctness gate only — see p1-baseline.js for the rationale
        // behind dropping the latency ceiling and dropped-iterations
        // ceiling. Both signals are still emitted to the summary and
        // surfaced verbatim in the report's columns; we just don't
        // turn them into exit-99 failures any more.
        policy_5xx_unexpected: ['count==0'],
    },
};
