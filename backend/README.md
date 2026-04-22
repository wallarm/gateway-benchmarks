# backend — Synthetic Backend

Forked [mccutchen/go-httpbin](https://github.com/mccutchen/go-httpbin) plus any extensions we need.

The backend's job is to be a **predictable echo server**: it answers every gateway the same way so we measure gateway overhead, not backend jitter.

## Exercised endpoints

| Endpoint | Benchmark usage |
|----------|-----------------|
| `/status/200` | Healthcheck and smoke scenarios |
| `/get`        | Plain GET with header echo |
| `/post`       | POST with body echo |
| `/anything`   | Generic echo (GET/POST/PUT) |
| `/bytes/{n}`  | Deterministic payload of size `n` |
| `/headers`    | Echo of incoming headers (used by parity attestation) |
| `/delay/{sec}` | Controlled delay (used in tail-latency scenarios) |

## Docker

```bash
make backend-build   # builds backend:bench-<sha>
make backend-run     # local run on :8080
```

The image is pinned by digest in [infra/local/docker-compose.yaml](../infra/local/docker-compose.yaml) and [infra/aws/](../infra/aws/) — see [docs/REPRODUCIBILITY.md](../docs/REPRODUCIBILITY.md).

## Status

> Phase 2 in the roadmap — currently pending. See [ROADMAP.md](../ROADMAP.md#phase-2-synthetic-backend-05-day).
