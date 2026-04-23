# `wallarm / p05-rl-endpoint` — parity compliance

**Verdict**: `PASS` on `the pinned Wallarm build…`.

## Canonical spec ([`docs/POLICIES.md § p04`](../../../docs/POLICIES.md#p04--per-endpoint-static-rate-limit))

- Limit: **100 req/s**, rolling 1 s window.
- Scope: ONE client-visible path (`/anything/limited`).
- `/anything/free` must stay unrestricted.
- Over-limit: `429 Too Many Requests` + `Retry-After: 1`.

## Wallarm binding — route-level `POST /flow`

Wallarm's native per-endpoint idiom is to register multiple routes
under a single service and attach a policy flow to one route only
via `POST /services/<svc>/routes/<rt>/flow`. This is the same
mechanism the upstream project uses in `tests/integration` and the
direct analogue of envoy's `typed_per_filter_config` and nginx's
`limit_req` inside a `location` block.

Shape:

```
  service "bench-p05" (base_path=/anything → backend:8080/anything)
    │
    ├── route "limited" (condition: path=["/limited","/limited/**"])
    │     └── POST /services/bench-p05/routes/limited/flow
    │           policy_id=ratelimit
    │           rate=100, window=1, window_type=sliding, scope=service
    │
    └── route "free"    (condition: path=["/free","/free/**"])
          └── no flow binding → unrestricted
```

Route ordering: `limited` is registered BEFORE `free` to hedge
against a hypothetical "first defined wins" matching implementation.
Conditions themselves are mutually exclusive (`/limited/**` vs
`/free/**`), so ordering does not matter on the current build in practice, but
defining the rate-limited route first keeps the bucket on the
exact path the fixture exercises.

Path patterns: `["/limited", "/limited/**"]` covers both the exact
form (fixture's `GET /anything/limited`) and any deep suffix
(`/anything/limited/foo`). Same idea on the free side.

## Deviation: `window_type = sliding` (inherited from p03)

As with [`p04-rl-static`](../p04-rl-static/NOTES.md#deviation-window_type--sliding-instead-of-fixed),
`window_type: fixed` with `window=1` is a silent no-op on
the Wallarm API Gateway — we therefore use `window_type:
sliding`. The PRD wording "rolling 1-second window" matches
`sliding` more literally than `fixed` anyway.

Tracking: [docs/GATEWAYS.md § deviations](../../../docs/GATEWAYS.md#deviations).

## Observed shape

Under the fixture's ASAP 1200-request burst (`curl --parallel
--parallel-max 128`):

```
probe 3 (/anything/limited):  2xx=98,   429=1102, 5xx=0, other=0
probe 4 (/anything/free):     2xx=1200, 429=0,    5xx=0, other=0
```

Symmetric with nginx/p04 (`2xx=107, 429=1093`) and envoy/p04
(`2xx=112, 429=1088`) within a handful of requests — three
different implementations (location-scoped `limit_req`, HCM
per-route override, wallarm route-flow binding) converge on
the same externally observable behaviour.

## Parity — all four probes

```
✓ PASS  single request on free endpoint below any limit -> 200
✓ PASS  single request on limited endpoint below 100rps -> 200
✓ PASS  1200 rps on limited endpoint -> at least 150 × 429 (bucket engages)
✓ PASS  1200 rps on free endpoint -> 0 × 429 (limit is scoped to /limited)
```

## Layout

```
gateways/wallarm/p05-rl-endpoint/
├── NOTES.md            ← this file
├── gateway.yaml        ← baseline settings (no policies here)
└── setup.sh            ← Admin-API bootstrap (service + 2 routes + route-level flow)
```

`setup.sh` has env-var overrides: `RL_RATE`, `RL_WINDOW`,
`RL_WINDOW_TYPE`, `RL_KEY`.

## Running

```bash
make parity-gateway PARITY_GATEWAY=wallarm PARITY_PROFILE=p05-rl-endpoint
```
