# envoy

Envoy column of the gateway benchmarks. One directory per canonical
policy profile (`docs/POLICIES.md`), all sharing a single
`docker-compose.yaml` and the same pinned envoy image.

## Pinned image

```
envoyproxy/envoy:distroless-v1.32.6
  @sha256:569ad5b2503aca24c9f6af48c47449200afdb761bb4d1a021741d6d6692acf56
```

The distroless flavour strips shell + package manager which keeps
the attack surface small and, more importantly, makes the
`docker-compose.yaml` identical across every profile — no
Dockerfile, no in-container `apk add`. Refresh the digest with:

```bash
docker pull envoyproxy/envoy:distroless-v1.32.6 && \
docker image inspect envoyproxy/envoy:distroless-v1.32.6 \
    --format '{{index .RepoDigests 0}}'
```

## Layout

```
gateways/envoy/
├── README.md                 (this file)
├── docker-compose.yaml       (gateway + backend on bench-net)
├── _shared/
│   └── lualib/               (shared Lua helpers for p02/p08/p09/p10, TBD)
└── p01-vanilla/
    ├── envoy.yaml            (full static bootstrap: listener + cluster)
    ├── setup.sh              (HTTP smoke — envoy is fully configured at boot)
    └── NOTES.md              (parity compliance, uniform-setting mapping)
```

Only `p01-vanilla` is populated today. The remaining nine profiles
follow the same per-profile layout — each gets its own
`envoy.yaml`, `setup.sh`, `NOTES.md` and, if it needs a Lua
primitive, a reference into `_shared/lualib`.

## Feature matrix

| Profile                 | Envoy primitive                                     | Parity    |
|-------------------------|-----------------------------------------------------|-----------|
| `p01-vanilla`           | Single listener + `router` filter + 1 cluster       | PASS (4/4)|
| `p02-jwt`               | Lua filter + shared `jwt_hs256` helper (see below)  | TBD       |
| `p03-rl-static`         | `envoy.filters.http.local_ratelimit` (per-route)    | TBD       |
| `p04-rl-dynamic-low`    | `local_ratelimit` with `descriptors` keyed on header| TBD       |
| `p05-rl-dynamic-high`   | Same as p04, different `tokens_per_fill`            | TBD       |
| `p06-req-headers`       | `request_headers_to_add` + `request_headers_to_remove` | TBD    |
| `p07-resp-headers`      | `response_headers_to_add` + `_to_remove` (+ server_header_transformation) | TBD |
| `p08-req-body`          | Lua filter reading/rewriting `request_body`         | TBD       |
| `p09-resp-body`         | Lua filter reading/rewriting `response_body`        | TBD       |
| `p10-full-pipeline`     | Composition of p02…p09 in envoy filter chain order  | TBD       |

### JWT HS256 note

`envoy.filters.http.jwt_authn` only supports asymmetric algorithms
(RS / ES / PS) natively — HS256 is not in its algorithm list. The
benchmark's canonical secret (`docs/POLICIES.md §p02`) is HS256, so
envoy's p02 will lean on the same shared Lua helper that the nginx
column uses (`gateways/nginx/_shared/lualib/jwt_hs256.lua`, mounted
into envoy at `/etc/envoy/lualib/jwt_hs256.lua`) rather than
`jwt_authn`. This keeps fixture semantics identical across columns
and avoids branching the fixtures per gateway.

## Running parity

```bash
# One profile against envoy:
make parity-gateway \
    PARITY_GATEWAY=envoy \
    PARITY_PROFILE=p01-vanilla

# All populated profiles against envoy (skips TBD cells cleanly):
make parity-gateway-all \
    PARITY_GATEWAY=envoy
```

The harness copies `gateways/envoy/docker-compose.yaml` into its
ephemeral temp root, picks the requested profile's `envoy.yaml`,
brings the stack up, runs `<profile>/setup.sh` as the smoke gate,
then drives `scripts/parity-attestation.sh` against
`http://localhost:9080`.

## Admin API (read-only)

While a parity run is up, you can poke at envoy directly:

```bash
curl -s http://localhost:9901/clusters | head -20
curl -s http://localhost:9901/stats | grep upstream_rq_total
curl -s http://localhost:9901/config_dump | jq '.configs | length'
```

No profile mutates envoy through the admin API — envoy's on-disk
bootstrap is the single source of truth per profile.
