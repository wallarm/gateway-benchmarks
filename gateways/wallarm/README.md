# wallarm

Per-profile configurations for the Wallarm API Gateway (the gateway
that this benchmark primarily measures). Each profile lives in its own
sub-directory with a static config plus a setup script that bootstraps
the Admin API.

## Pinned version

| Field          | Value |
|----------------|-------|
| Version        | `0.2.0` |
| Docker image   | `wallarm/api-gateway:0.2.0` |
| Digest         | `sha256:a3d4d2f780e8f1f22b27e2aa450d4a5cfde6d8c51e153a900f63da464393e825` |
| Architecture   | `linux/amd64` |
| Language       | Rust |
| Source         | [`wallarm/wallarm-api-gateway`](https://hub.docker.com/r/wallarm/api-gateway) (public Docker Hub) |
| Documentation  | [`wallarm/wallarm-api-gateway` product docs](https://docs.wallarm.com/api-gateway/) |

Refresh the digest with:

```bash
docker pull wallarm/api-gateway:0.2.0
docker image inspect wallarm/api-gateway:0.2.0 \
    --format '{{index .RepoDigests 0}}'
```

## Layout

```
gateways/wallarm/
├── README.md                  (this file)
├── docker-compose.yaml        (gateway + backend on bench-net)
├── p01-vanilla/
│   ├── gateway.yaml           (static listener + pool)
│   ├── setup.sh               (Admin API bootstrap)
│   └── NOTES.md               (parity compliance, deviations)
├── p02-jwt/
│   ├── FEATURE-MISSING        (no jwt_validation policy in 0.2.0)
│   └── NOTES.md               (explainer + future-ready config)
├── p03-rl-static/
│   ├── gateway.yaml           (listener + pool; copied from p01)
│   ├── setup.sh               (Admin API: ratelimit policy on flow)
│   └── NOTES.md               (deviation: sliding window, not fixed)
├── p04-rl-dynamic-low/        (to be added)
├── p05-rl-dynamic-high/       (to be added)
├── p06-req-headers/           (to be added)
├── p07-resp-headers/          (to be added)
├── p08-req-body/              (to be added)
├── p09-resp-body/             (to be added)
└── p10-full-pipeline/         (to be added)
```

## Feature matrix

| Profile                 | Primitive                                          | Parity            |
|-------------------------|----------------------------------------------------|-------------------|
| `p01-vanilla`           | Catch-all service `/ → backend`                    | PASS (4/4)        |
| `p02-jwt`               | `jwt_validation` policy (HS256 via shared secret)  | FEATURE-MISSING   |
| `p03-rl-static`         | `ratelimit` policy, key = service, 1000 rps        | PASS (2/2)        |
| `p04-rl-dynamic-low`    | `ratelimit` keyed on `X-Real-IP`, 10 rps           | planned           |
| `p05-rl-dynamic-high`   | `ratelimit` keyed on `X-Real-IP`, 100 rps          | planned           |
| `p06-req-headers`       | `header_transform` on request                      | planned           |
| `p07-resp-headers`      | `header_transform` on response                     | planned           |
| `p08-req-body`          | `body_transform` (JSON) on request                 | planned           |
| `p09-resp-body`         | `body_transform` (JSON) on response                | planned           |
| `p10-full-pipeline`     | Composition of p02…p09 in that exact order         | planned           |

`PASS` / `FEATURE-MISSING` entries reflect the latest run of
`make parity-gateway-all PARITY_GATEWAY=wallarm`. See each profile's
`NOTES.md` and [`docs/GATEWAYS.md § Deviations`](../../docs/GATEWAYS.md#deviations)
for the per-cell rationale.

The full list of canonical values (rate limit, JWT secret, header
names, JSON body paths) lives in
[`../_reference/values.yaml`](../_reference/values.yaml) and
[`docs/POLICIES.md`](../../docs/POLICIES.md). This directory never
hard-codes values that differ from those files; if it ever does, the
parity attestation will surface the drift.

## Uniform settings enforcement

This gateway's declared settings versus the uniform values from
[`docs/GATEWAYS.md`](../../docs/GATEWAYS.md):

| Row                             | Uniform value                 | `wallarm` setting                           |
|---------------------------------|-------------------------------|---------------------------------------------|
| HTTP/1.1 only downstream        | HTTP/1.1 only                 | `net.http_port` (no `http2`, no `h2c`)      |
| Upstream pool size              | 1024                          | `upstream.pool.size: 1024`                  |
| Pool idle timeout               | 60 s                          | `upstream.pool.idle_timeout_ms: 60000`      |
| TCP keep-alive                  | on                            | `upstream.tcp.keepalive_secs: 90`           |
| TCP nodelay                     | on                            | `upstream.tcp.nodelay: true`                |
| Downstream keep-alive           | on                            | default (handled by unigw)                  |
| Access logging on hot path      | off                           | default (no logging config)                 |
| Admin / data plane separation   | yes                           | 9081 (admin) vs 9080 (data)                 |
| Request buffering               | off                           | Rust proxy is streaming; no explicit toggle |
| Response buffering              | off                           | same                                        |

Anything that later deviates goes into the matching profile's `NOTES.md`
and into `docs/GATEWAYS.md § Deviations`.

## Running parity

```bash
# One profile end-to-end (bring up, setup, parity, tear down):
make parity-gateway \
    PARITY_GATEWAY=wallarm \
    PARITY_PROFILE=p01-vanilla

# All 10 profiles against an already-running wallarm:
make parity-check-all \
    PARITY_GATEWAY=wallarm \
    PARITY_TARGET=http://localhost:9080
```

See [`../../Makefile`](../../Makefile) for the full list of targets and
variables.
