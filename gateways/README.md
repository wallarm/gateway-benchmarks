# gateways — Configurations per Policy Profile

Each sub-directory holds **all configs for a single gateway** covering the 10 policy profiles from [TASK.md §4](../TASK.md).

## Per-gateway layout (reference)

```
gateways/<name>/
├── README.md                    # version, image digest, deviations
├── Dockerfile                   # optional — only if we build a custom layer
├── p01-bypass/                  # policy profile 1
│   ├── config.yaml
│   └── NOTES.md                 # parity notes, specifics
├── p02-tls-terminate/
├── p03-header-auth/
├── p04-jwt-hs256/
├── p05-jwt-rs256/
├── p06-rate-limit-ip/
├── p07-rate-limit-key/
├── p08-body-rewrite/
├── p09-header-rewrite/
└── p10-lua-plugin/
```

Policy profiles must be **numerically identical** across gateways: the same JWT, the same rate-limit windows, the same header substitutions. See [docs/POLICIES.md](../docs/POLICIES.md) and [scripts/parity-attestation.sh](../scripts/parity-attestation.sh).

## Gateways under test

| Gateway | Target version | Image | Language |
|---------|----------------|-------|----------|
| wallarm  | v0.2.x  | `wallarm/api-gateway@sha256:...`         | Rust |
| nginx    | 1.27.x  | `nginx@sha256:...`                       | C |
| envoy    | 1.31.x  | `envoyproxy/envoy@sha256:...`            | C++ |
| kong     | 3.8.x   | `kong@sha256:...`                        | Lua/OpenResty |
| apisix   | 3.11.x  | `apache/apisix@sha256:...`               | Lua/OpenResty |
| traefik  | 3.2.x   | `traefik@sha256:...`                     | Go |
| tyk      | 5.5.x   | `tykio/tyk-gateway@sha256:...`           | Go |

Final versions and digests live in [docs/GATEWAYS.md](../docs/GATEWAYS.md) (filled in as implementation lands).

## Status

> Phases 3 and 5 in the roadmap — pending. See [ROADMAP.md](../ROADMAP.md).
