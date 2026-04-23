# gateways — Configurations per Policy Profile

Each sub-directory holds **all configs for a single gateway** covering
the 10 canonical policy profiles from [TASK.md §4](../TASK.md) and
documented in [docs/POLICIES.md](../docs/POLICIES.md).

## Per-gateway layout

```
gateways/<name>/
├── README.md                    # version, image digest, deviations
├── Dockerfile                   # optional — only if we build a custom layer
├── docker-compose.yaml          # gateway + backend (bench-net)
├── p01-vanilla/                 # profile 1  — plain proxy
│   ├── gateway.yaml             # static config
│   ├── setup.sh                 # Admin API / plugin bootstrap
│   └── NOTES.md                 # parity compliance, deviations
├── p02-jwt/                     # profile 2  — JWT HS256
├── p04-rl-static/               # profile 3  — service-wide rate limit
├── p05-rl-endpoint/             # profile 4  — per-endpoint rate limit (added Iter 16)
├── p06-rl-dynamic-low/          # profile 5  — per-key RL, low cardinality
├── p07-rl-dynamic-high/         # profile 6  — per-key RL, high cardinality
├── p08-req-headers/             # profile 7  — request-header rewrite
├── p09-resp-headers/            # profile 8  — response-header rewrite
├── p10-req-body/                # profile 9  — request body rewrite (JSON)
├── p11-resp-body/               # profile 10 — response body rewrite (JSON)
└── p12-full-pipeline/           # profile 11 — combined pipeline
```

Policy profiles are **numerically identical** across gateways: the
same JWT, the same rate-limit windows, the same header substitutions.
The single source of truth is
[`_reference/values.yaml`](./_reference/values.yaml); parity is verified
by [`scripts/parity-attestation.sh`](../scripts/parity-attestation.sh)
and driven end-to-end by [`scripts/parity-gateway.sh`](../scripts/parity-gateway.sh).

## Gateways under test

| Gateway  | Target tag        | Image                         | Language       |
|----------|-------------------|-------------------------------|----------------|
| wallarm  | from-sources      | `${WALLARM_IMAGE:?required}`  | Rust           |
| nginx    | `1.27.x-alpine`   | `nginx:1.27.x-alpine`         | C              |
| envoy    | `v1.31.x`         | `envoyproxy/envoy:v1.31.x`    | C++            |
| kong     | `3.8.x`           | `kong:3.8.x`                  | Lua / OpenResty|
| apisix   | `3.11.x-debian`   | `apache/apisix:3.11.x-debian` | Lua / OpenResty|
| traefik  | `v3.3.4`          | `traefik:v3.3.4`              | Go             |
| tyk      | `v5.11.1`         | `tykio/tyk-gateway:v5.11.1`   | Go             |

Final pinned versions and SHA-256 digests (resolved by the
orchestrator at start-of-run) live in
[docs/GATEWAYS.md](../docs/GATEWAYS.md). Each per-gateway README
locks its own digest; the docs file is the authoritative roster.

## Running parity

```bash
# Single profile, end-to-end (compose up → setup → parity → compose down):
make parity-gateway PARITY_GATEWAY=wallarm PARITY_PROFILE=p01-vanilla

# All profiles, end-to-end, for one gateway:
make parity-gateway-all PARITY_GATEWAY=wallarm

# All profiles against an already-running target:
make parity-check-all  PARITY_GATEWAY=wallarm PARITY_TARGET=http://localhost:9080
```

See [ROADMAP.md](../ROADMAP.md) for the per-phase implementation
status across the matrix.

## Status

| Phase | Scope                                                        | State |
|-------|--------------------------------------------------------------|-------|
| 3a    | Parity framework foundation (fixtures, runner, backend-direct baseline) | done |
| 3b    | Per-gateway configs across the 7 × 12 matrix (84 cells) | **done** — 81 PASS + 3 PARTIAL, 0 FEATURE-MISSING (traefik p02 + p11), 5 cosmetic FAILs inside 2 PARTIAL PASS cells (tyk p02 + p11, all tracing to one fixed `mw_jwt.go` literal). Six full-green columns (nginx, envoy, wallarm, apisix, kong) + (traefik historical: 9/11+2 FM, now 12/12 after local Yaegi plugin) + tyk 9/12+3 PARTIAL PASS. Closed by [`.notes/PROGRESS.md` § Iteration 27](../.notes/PROGRESS.md). |
| 3d    | p03-jwks-rs256-basic (`p03-jwks-rs256-basic` for kong / traefik / nginx; tr.opt traefik HS256 Yaegi plugin to close p02/p11 FM → PASS) | scheduled — not blocking ranking |

Shared assets (JWT secret, JWKS, TLS cert, canonical JSON bodies) are
in [`_reference/`](./_reference/README.md).
