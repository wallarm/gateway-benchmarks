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

> **Phase 4 foundation — done.** All four closed-loop profiles ship
> under `k6/profiles/` and are wired through `scripts/load-gateway.sh`
> + the Go orchestrator (`bench run`); the paced-arrivals variants
> below (`p1c..p4c`) are landed and exercised by Phase 4's 248-run
> production sweep. HTTPS scenarios (`s13`, `s14`) ride the same
> profiles. Phase 5–8 plumbing (3-host topology, Go orchestrator,
> HTML report, reproducibility gate) is also in — see
> [ROADMAP.md](../ROADMAP.md).

## Paced-arrivals variants (opt-in)

The four profiles above are **closed-loop** (`constant-vus` /
`ramping-vus`): each VU fires the next request only after the previous
response arrives, so a faster gateway chews through more iterations
per second than a slower one. That shape is exactly right for
**relative ranking** ("gateway X is ~1.3× faster than gateway Y under
comparable concurrency") — and it is precisely what every public
API-gateway benchmark we cross-referenced ships: `api7/apisix-
benchmark`, `Kong/insomnia`, `jkaninda/goma-gateway-vs-traefik` all
drive k6 closed-loop. So apples-to-apples with the prior art holds.

Closed-loop cannot answer the complementary question: **"can gateway X
sustain 10 000 requests per second?"**. At that framing the x-axis is
absolute arrivals/second, not VU count, and a slower gateway must
surface its shortfall as backpressure (queue growth → latency;
eventually `dropped_iterations` > 0), not as "fewer requests issued".
For that we need k6's `constant-arrival-rate` / `ramping-arrival-rate`
executors, which schedule arrivals on a wall-clock cadence regardless
of how fast the backend answers.

To keep closed-loop (the ranking workhorse) and paced (the absolute-
RPS probe) cleanly separable, each closed-loop profile has a twin:

| Profile       | Twin of        | Target RPS                              | Duration | Purpose                                                                  |
|---------------|----------------|-----------------------------------------|----------|--------------------------------------------------------------------------|
| `p1c-paced`   | `p1-baseline`  | constant 500 RPS                        | 60 s     | smoke: confirm the gateway can sustain 500 absolute arrivals/second      |
| `p2c-paced`   | `p2-sustained` | constant 2 000 RPS                      | 5 m      | steady-state absolute-RPS over 5 minutes; catches queue-buildup drift    |
| `p3c-paced`   | `p3-ramp`      | 500 → 2 000 → 5 000 → 10 000, hold, ramp-down | 7 m (420 s) | sweep the RPS-vs-latency curve to find the gateway's knee            |
| `p4c-paced`   | `p4-stress`    | constant 20 000 RPS                     | 120 s    | absolute-RPS headline number at saturation                               |

Total matrix when both families run: 8 load profiles × 14 scenarios
× 7 gateways = 784 cells. Realistically paced is opted into
per-campaign — the default sweep still runs only the closed-loop
quartet.

### How to trigger

The `-paced` suffix in the profile name IS the gate. There is no
separate env var. Single-cell ad-hoc run:

```bash
make load-gateway \
    LOAD_GATEWAY=nginx \
    LOAD_POLICY=p01-vanilla \
    LOAD_SCENARIO=s01-vanilla-http \
    LOAD_PROFILE=p1c-paced
```

Multi-load sweep via the orchestrator:

```bash
make load-sweep \
    LOAD_GATEWAY=nginx \
    LOAD_POLICIES=p01-vanilla,p02-jwt \
    LOAD_LOADS=p1c-paced,p2c-paced
```

Default behaviour (no `-paced` in the profile slug) takes the
closed-loop code path unchanged — same `constant-vus` / `ramping-vus`
executors, same thresholds, byte-for-byte identical to the pre-paced
world.

### Why the latency budget widens 50 %

Paced and closed-loop see latency differently even against the same
gateway. Under closed-loop, a slow gateway gets *fewer* requests per
VU per second (each VU blocks waiting for the response) — so observed
latency stays pinned to what the gateway can actually serve at that
moment. Under paced, arrivals keep coming on the scheduled cadence
regardless of response time, so a slow gateway accumulates an
in-flight queue; every request then measures its own service time
**plus queue wait**. Two gateways with identical p95 in closed-loop
can diverge by 2–3× in paced if one of them is marginally behind the
target rate. To keep the paced thresholds from tripping on purely
normal queue transients, every `http_req_duration` p(95) cutoff is
widened by 50 % relative to its closed-loop twin:

| Profile       | Twin p(95) cutoff | Paced p(95) cutoff |
|---------------|-------------------|--------------------|
| `p1c-paced`   | 200 ms            | 300 ms             |
| `p2c-paced`   | 300 ms            | 450 ms             |
| `p3c-paced`   | 500 ms            | 750 ms             |
| `p4c-paced`   | (no cutoff)       | (no cutoff)        |

The `policy_5xx_unexpected` floor stays `count==0` on p1c/p2c/p3c
(same as their twins); p4c has no thresholds at all because at 20
kRPS the interesting signal is the error + drop distribution itself.

### Red-signal rule

A paced run is **invalid as an absolute-RPS claim** when:

```
http_reqs  <  target_rps × duration × 0.99
```

i.e. the gateway (or the loadgen) failed to actually emit 99 % of the
scheduled arrivals. In k6's built-in metrics this manifests as
`dropped_iterations` being non-zero — k6 sets that counter whenever
it could not start a scheduled iteration on time because no VU was
available to fire it. The paced profiles enforce this inline:
p1c-paced has a strict `dropped_iterations: count==0` threshold
(a 500-RPS target is too low for drops to be anything other than a
gateway fault); p2c-paced and p3c-paced tolerate up to 1 %
(`rate<0.01`) to absorb brief cold-start queueing; p4c-paced lets
the counter float and has the report generator colour cells where
the shortfall exceeds 5 %.

Closed-loop profiles do not have a `dropped_iterations` threshold —
their executors (`constant-vus` / `ramping-vus`) do not emit that
metric at all. Presence of a non-zero value in a summary JSON is
itself a reliable signal that the run used a paced profile.

### Capacity note — local runs

p1c-paced (500 RPS) and p2c-paced (2 000 RPS) fit comfortably inside
a developer-laptop Docker Desktop envelope on Apple Silicon. p3c-paced
(up to 10 kRPS) is borderline and requires `ulimit -n 65536` raised
on the host shell; p4c-paced (20 kRPS with up to 5 000 VUs) reliably
fails the loadgen-side capacity check on most laptops and is intended
for a dedicated bench host (Linux, 16+ cores, 32+ GB RAM, loopback
networking, `ulimit -n 1048576`, `net.core.somaxconn=65535`). For
local smoke testing prefer `LOAD_LOADS=p1c-paced,p2c-paced`.

