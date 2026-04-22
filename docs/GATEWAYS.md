# Gateways Under Test

> Roster, versions, digests, deviations. Fills in as Phase 3 lands.

## Canonical versions (target)

| Gateway | Version | Docker image | Digest | Language | Source |
|---------|---------|--------------|--------|----------|--------|
| wallarm  | v0.2.x        | `wallarm/api-gateway:v0.2.x`           | `sha256:TBD` | Rust | https://github.com/wallarm/wallarm-api-gateway |
| nginx    | 1.27.3-alpine | `nginx:1.27.3-alpine`                  | `sha256:TBD` | C | https://hub.docker.com/_/nginx |
| envoy    | v1.31.5       | `envoyproxy/envoy:v1.31.5`             | `sha256:TBD` | C++ | https://hub.docker.com/r/envoyproxy/envoy |
| kong     | 3.8.0         | `kong:3.8.0`                           | `sha256:TBD` | Lua/OpenResty | https://hub.docker.com/_/kong |
| apisix   | 3.11.0-debian | `apache/apisix:3.11.0-debian`          | `sha256:TBD` | Lua/OpenResty | https://hub.docker.com/r/apache/apisix |
| traefik  | v3.2.1        | `traefik:v3.2.1`                       | `sha256:TBD` | Go | https://hub.docker.com/_/traefik |
| tyk      | v5.5.0        | `tykio/tyk-gateway:v5.5.0`             | `sha256:TBD` | Go | https://hub.docker.com/r/tykio/tyk-gateway |

Once digests are locked they are mirrored here, in `infra/local/docker-compose.yaml`, and in the per-run `manifest.json`.

The final list may change — we are discussing whether to add HAProxy ([issue #N](../issues)).

## Settings kept identical everywhere

To keep the comparison fair:

| Setting | Value | Comment |
|---------|-------|---------|
| Request buffer      | 64 KB            | same limit everywhere |
| Response buffer     | 64 KB            | — |
| Upstream keepalive  | on, pool=256     | — |
| Client keepalive    | on               | — |
| Request timeout     | 10s              | does not affect p1-p2; matters for p4 |
| TLS versions        | TLSv1.2, TLSv1.3 | same cipher list |
| Access logging      | off              | disk I/O is excluded from the measurement |
| Metrics/admin port  | off              | exclude built-in overhead |

Any deviation is documented below.

## Deviations

> Every objective difference that keeps a cell from being a 100% parity comparison is recorded here.

### Example format (to be populated in Phase 3)

```
### [gw=kong, p=p04-jwt-hs256]

What differs: Kong 3.8 JWT plugin does not accept `exp` as an ISO string, only a Unix timestamp.
Resolution: payload.exp in fixtures/p04.jsonl is always a Unix timestamp.
Impact on ranking: none; this is fixture shape, not gateway overhead.
Source: https://docs.konghq.com/hub/kong-inc/jwt/
```

## Reproducibility guarantee

Every image tag is resolved to a digest **automatically** by the orchestrator before every run (`docker inspect --format='{{index .RepoDigests 0}}'`). If the digest in `manifest.json` no longer matches after a re-pull, the run is marked `image_digest_mismatch` and excluded from aggregation.

## Status

> Stub. Populated in Phase 3 (parity framework), Phase 5 (infrastructure), and Phase 8 (doc review).
