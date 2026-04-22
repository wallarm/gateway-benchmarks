# k6 — Load Framework

k6 scripts that drive **4 load profiles × 12 policy/protocol scenarios × 7 gateways**, per [TASK.md §§4–5](../TASK.md).

## Layout

```
k6/
├── lib.js            # shared helpers: request builders, metrics, sampling
├── profiles/         # 4 load profiles (TASK §5)
│   ├── p1-baseline.js        # constant low load
│   ├── p2-sustained.js       # moderate, long-running
│   ├── p3-ramp.js            # smooth ramp to target, hold, drop
│   └── p4-stress.js          # high-concurrency stress
└── scenarios/        # 12 policy/protocol scenarios (TASK §4)
    ├── s01-bypass-http.js
    ├── s02-bypass-https.js
    ├── s03-header-auth-http.js
    ├── s04-header-auth-https.js
    ├── s05-jwt-hs256-https.js
    ├── s06-jwt-rs256-https.js
    ├── s07-rate-limit-ip-http.js
    ├── s08-rate-limit-key-https.js
    ├── s09-body-rewrite-http.js
    ├── s10-header-rewrite-https.js
    ├── s11-lua-plugin-http.js
    └── s12-lua-plugin-https.js
```

Total: **48 cells × 7 gateways = 336 test cells** (TASK §4).

## How a run is assembled

- The Go orchestrator invokes k6 for every (profile × scenario × gateway) cell.
- Each run shares a single per-run seed pulled from the manifest, so body payloads and keys are deterministic.
- Metrics land in `reports/<run>/raw/*.json` (k6 `--summary-export` plus `--out json=...` for the time series).

See [docs/LOAD-PROFILES.md](../docs/LOAD-PROFILES.md) and [docs/POLICIES.md](../docs/POLICIES.md).

## k6 version

Pinned: `grafana/k6:1.7.1@sha256:...` — the concrete digest is recorded in [infra/local/docker-compose.yaml](../infra/local/docker-compose.yaml).

## Status

> Phase 4 in the roadmap — pending.
