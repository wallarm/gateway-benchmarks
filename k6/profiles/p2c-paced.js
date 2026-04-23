// k6/profiles/p2c-paced.js
//
// Paced-arrivals twin of p2-sustained (TASK §5, docs/LOAD-PROFILES.md
// § Paced-arrivals variants):
//
//   constant 2000 RPS × 5m, 50 preAllocatedVUs, 200 maxVUs
//
// Purpose: absolute-RPS steady-state claim over a 5-minute window.
// The closed-loop twin (100 VUs × 5m) answers "gateway X sustains
// 100-VU load without memory growth"; this profile answers the
// orthogonal question "gateway X sustains 2000 arrivals/second for
// 5 minutes without queueing". Both signals matter: closed-loop
// catches allocator slope (RSS vs time via docker-stats sidecar),
// paced catches queue buildup (http_req_duration vs time).
//
// preAllocatedVUs=50 covers the expected steady concurrency at
// 2 kRPS if the gateway holds p95 ≈ 25 ms (2000 × 0.025 = 50). The
// healthy operating point of the four fastest gateways in our
// reference set (nginx, envoy, apisix) sits well under 10 ms p95 at
// this RPS — so 50 VUs is already 2× headroom. maxVUs=200 is the
// upper bound k6 will grow to before declaring arrival-rate failure
// via dropped_iterations; a gateway that needs > 200 concurrent VUs
// to drain 2000 RPS is running at > 100 ms p95, which is itself a
// regression worth catching.
//
// Threshold widening: closed-loop p2 allows p(95) < 300 ms. Paced
// p2c allows p(95) < 450 ms (+50%). Under paced arrivals a slower
// gateway accumulates an in-flight queue instead of getting fewer
// requests, so the same "slow" gateway measures larger latency
// numbers than in closed loop. Rationale matches p1c-paced's.

export const options = {
    scenarios: {
        paced: {
            executor: 'constant-arrival-rate',
            rate: 2000,
            timeUnit: '1s',
            duration: '5m',
            preAllocatedVUs: 50,
            maxVUs: 200,
            gracefulStop: '10s',
            tags: { bench_load: 'p2c-paced' },
        },
    },
    discardResponseBodies: false,
    noConnectionReuse: false,
    insecureSkipTLSVerify: true,
    summaryTrendStats: ['avg', 'min', 'med', 'p(90)', 'p(95)', 'p(99)', 'p(99.9)', 'max'],
    summaryTimeUnit: 'ms',
    thresholds: {
        policy_5xx_unexpected: ['count==0'],
        http_req_duration: ['p(95)<450'],
        // At 2 kRPS × 5 min = 600 k scheduled iterations. A single
        // dropped iteration is 1.7 ppm — noise. Tolerate up to 1 %
        // dropped before calling the absolute-RPS claim invalid, which
        // matches the `http_reqs < target × duration × 0.99` red-
        // signal rule in docs/LOAD-PROFILES.md § Paced-arrivals
        // variants.
        dropped_iterations: ['rate<0.01'],
    },
};
