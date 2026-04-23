// k6/profiles/p4c-paced.js
//
// Paced-arrivals twin of p4-stress (TASK §5, docs/LOAD-PROFILES.md
// § Paced-arrivals variants):
//
//   constant 20 000 RPS × 120s, 1000 preAllocatedVUs, 5000 maxVUs
//
// Purpose: the marquee "gateway X sustained 20 kRPS for 120 s with
// N % dropped" number. Where p4-stress answers "how does gateway X
// behave at 1000 VUs of saturation pressure" (the signal is shape
// of the error distribution), p4c-paced answers "can gateway X
// absorb 20 kRPS for 2 minutes". These are complementary views of
// the same "stress" operating point — p4 stresses the gateway's
// workload sharing, p4c stresses its arrival-queue absorption.
//
// Capacity warning — NOT LAPTOP-FRIENDLY:
//
//   20 kRPS + 5000 maxVUs through Docker Desktop on macOS is
//   aggressive enough that most developer laptops cannot sustain
//   the loadgen side cleanly. Symptoms when the laptop is the
//   bottleneck:
//     - dropped_iterations > 5 % at t≈30 s (kernel run-queue
//       saturation on the k6 container).
//     - http_req_failed spikes with status 0 (k6 client-side
//       connection/dial failures).
//     - docker-stats sidecar shows the *k6 container's* CPU
//       pegged before the gateway container's — the true red-
//       signal that the bench machine is undersized.
//
//   For local verification prefer `LOAD_PROFILES=p1c-paced,p2c-paced`
//   which stays inside a developer laptop's envelope. Run p3c and
//   p4c on a dedicated bench host (Linux, 16+ cores, 32+ GB RAM,
//   loopback networking, `ulimit -n 1048576` and
//   `net.core.somaxconn = 65535`) — see docs/LOAD-PROFILES.md.
//
// preAllocatedVUs=1000 covers the expected concurrency at 20 kRPS
// if the gateway holds p95 ≈ 50 ms (20000 × 0.05 = 1000). maxVUs=
// 5000 gives 5× headroom — enough for a 250-ms p95 before drops
// kick in, which is well past the point the operator would call
// the gateway "unable to sustain 20 kRPS" anyway.
//
// No latency thresholds, matching the closed-loop twin p4-stress:
// at saturation the interesting signal is the error + drop
// distribution, not a pass/fail on p(95). The report generator
// (Phase 7) plots the achieved_rps vs target_rps curve from
// `http_reqs` and `dropped_iterations` and colours cells where
// the shortfall exceeds 5 %.

export const options = {
    scenarios: {
        paced: {
            executor: 'constant-arrival-rate',
            rate: 20000,
            timeUnit: '1s',
            duration: '120s',
            preAllocatedVUs: 1000,
            maxVUs: 5000,
            gracefulStop: '15s',
            tags: { bench_load: 'p4c-paced' },
        },
    },
    discardResponseBodies: false,
    noConnectionReuse: false,
    insecureSkipTLSVerify: true,
    summaryTrendStats: ['avg', 'min', 'med', 'p(90)', 'p(95)', 'p(99)', 'p(99.9)', 'max'],
    summaryTimeUnit: 'ms',
    // No `thresholds` block on purpose — mirrors p4-stress. At 20
    // kRPS the matrix is *looking for* the error distribution, not
    // gating on any specific cutoff. The orchestrator's error-
    // classifier colours the cell red when 5xx exceeds 1 % or when
    // dropped_iterations exceeds 5 % of target; neither condition
    // aborts the run here.
};
