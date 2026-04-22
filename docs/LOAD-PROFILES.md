# Load Profiles

> The 4 load profiles from [TASK.md §5](../TASK.md). Every profile is run against every (gateway × policy × protocol) cell.

## Why four profiles, not one

A single RPS run hides: tail latency under ramp load, memory leaks under sustained load, and graceful degradation under stress. Hence **four distinct traffic shapes**:

| # | Name | Character | Duration | VUs | Target RPS |
|---|------|-----------|----------|-----|------------|
| p1 | **baseline**   | Constant low | 60s | 10 | ~1 000 |
| p2 | **sustained**  | Constant moderate, long-running | 300s | 100 | ~10 000 |
| p3 | **ramp**       | Smooth ramp to target, 180s hold, ramp-down | 480s | 10 → 500 → 0 | up to ~30 000 |
| p4 | **stress**     | High-concurrency stress | 120s | 1 000 | whatever the gateway can sustain |

## Exact k6 stages

### `p1-baseline.js`

```js
export const options = {
  scenarios: {
    default: {
      executor: 'constant-vus',
      vus: 10,
      duration: '60s',
    },
  },
};
```

Purpose: gateway baseline throughput with no thermal effects. Error budget — strictly **zero**.

### `p2-sustained.js`

```js
export const options = {
  scenarios: {
    default: {
      executor: 'constant-vus',
      vus: 100,
      duration: '5m',
    },
  },
};
```

Purpose: steady-state RSS, memory-leak detection, no p95 regression after 3 minutes of warm-up.

### `p3-ramp.js`

```js
export const options = {
  scenarios: {
    default: {
      executor: 'ramping-vus',
      startVUs: 10,
      stages: [
        { duration: '60s',  target: 100 },
        { duration: '60s',  target: 300 },
        { duration: '60s',  target: 500 },
        { duration: '180s', target: 500 },
        { duration: '60s',  target: 0   },
      ],
    },
  },
};
```

Purpose: tail latency at ramp transitions, behaviour under sharp connection growth. Catches connection-pool bugs.

### `p4-stress.js`

```js
export const options = {
  scenarios: {
    default: {
      executor: 'constant-vus',
      vus: 1000,
      duration: '120s',
    },
  },
};
```

Purpose: gateway saturation point. **Non-zero** errors are expected (backpressure 503/504). Error classification matters here (see [REPORT.md](./REPORT.md#error-breakdown)).

## Common settings

Every profile inherits a shared base:

```js
export const options = {
  discardResponseBodies: false,   // bodies needed for parity and body-rewrite scenarios
  noConnectionReuse: false,       // keep-alive ON (TASK §5)
  batchPerHost: 1000,             // enough for p3/p4
  insecureSkipTLSVerify: true,    // self-signed in bench mode
  thresholds: {
    http_req_failed: ['rate<0.01'],          // strict on p1/p2/p3
    http_req_duration: ['p(95)<200'],        // relaxed on p4
  },
};
```

Profiles override these thresholds where relevant.

## Fairness

- **Identical keep-alive settings** for k6 against every gateway.
- **Same HTTP version negotiation** — k6 does not issue HTTP/2, only HTTP/1.1 (TASK decision — it compares gateways in the mode they are all strong in).
- **Warm-up**: the first 10 seconds of every run are excluded from metric aggregation.
- **Seeds**: `__ITER`, `__VU`, and a global run seed → deterministic body payloads and JWT claims.

## Status

> Stub. Phase 4 in the roadmap.
