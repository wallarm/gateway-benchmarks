# Policy Profiles

This document expands the ten policy profiles defined in
[TASK.md §4](../TASK.md) into concrete, testable configurations.
Every gateway under test must be configured to produce **externally
observable** behaviour identical to what is described below, or the
corresponding cell is marked as a deviation / `feature-missing`.

## Principles

1. **One profile — one aspect.** Profiles are orthogonal; they are not
   combined except in the explicit `full-pipeline` profile.
2. **Parity before metrics.** A gateway's cell is included in the final
   ranking only if its configuration passes [parity attestation](#parity-attestation).
3. **Identical values across gateways.** Every secret, limit, header
   name and JSON field listed here is the ground truth. The same
   constants live under [`gateways/_reference/`](../gateways/_reference/).
4. **No third-party plugins unless explicitly called out** (e.g. the
   Traefik JWT community plugin). Such cases become entries in
   [`docs/GATEWAYS.md`](./GATEWAYS.md#deviations).

## Canonical profile list

All profiles run over **plaintext HTTP/1.1** unless stated otherwise.
HTTP/2 and HTTP/3 must be forcibly disabled on every gateway.

| #   | ID                  | Profile name                       | Description                                                                          |
|-----|---------------------|------------------------------------|--------------------------------------------------------------------------------------|
| p01 | `vanilla`           | Vanilla                            | Pure proxy, no policies applied                                                      |
| p02 | `jwt`               | JWT verification                   | HS256 against a shared secret (`BENCH_JWT_SECRET`)                                    |
| p03 | `rl-static`         | Static service-wide rate limit     | 1000 req/s per service, rolling 1s window                                            |
| p04 | `rl-dynamic-low`    | Dynamic rate limit, low cardinality | 10 req/s per client IP, pool of 100 distinct IPs                                      |
| p05 | `rl-dynamic-high`   | Dynamic rate limit, high cardinality | 100 req/s per client IP, pool of 50 000 distinct IPs                                 |
| p06 | `req-headers`       | Request headers rewrite            | Add `X-Bench-In: 1`, remove `X-Forwarded-For`                                         |
| p07 | `resp-headers`      | Response headers rewrite           | Add `X-Bench-Out: 1`, remove `Server`                                                 |
| p08 | `req-body`          | Request body rewrite (JSON)        | Add `.bench.injected = true`, remove `.secret`                                        |
| p09 | `resp-body`         | Response body rewrite (JSON)       | Add `.bench.injected = true`, remove `.server`                                        |
| p10 | `full-pipeline`     | Full pipeline                      | JWT ▶ rl-static ▶ req-headers ▶ req-body ▶ upstream ▶ resp-headers ▶ resp-body        |

Two of these profiles are additionally exercised over **HTTP/1.1 + TLS**
(per [TASK.md §6](../TASK.md)):

| ID                   | Protocol | Notes                                             |
|----------------------|----------|---------------------------------------------------|
| `vanilla-tls`        | HTTPS    | Same as `vanilla` but with TLS termination        |
| `full-pipeline-tls`  | HTTPS    | Same as `full-pipeline` but with TLS termination  |

That is the full 12-tab matrix referenced in [TASK.md §11](../TASK.md).

## Parity attestation

Before any load is generated, the orchestrator runs
[`scripts/parity-attestation.sh`](../scripts/parity-attestation.sh)
against the gateway in the current configuration. The script fires a
small, deterministic set of probes (see [`fixtures/`](../fixtures/)) and
asserts that:

- The response status code matches the expected value.
- Response headers contain / do not contain the expected markers.
- If applicable, the backend observed the expected transformation of
  the request (the backend is our own [`backend`](../backend) — we read
  its echo).

The script emits machine-readable JSON per cell:

```json
{
  "gateway":   "wallarm",
  "profile":   "p02-jwt",
  "status":    "PASS",
  "checks":   24,
  "passed":   24,
  "failed":    0,
  "deviations": []
}
```

Possible terminal statuses:

- `PASS` — the cell contributes to the ranking.
- `FAIL` — the cell is excluded from the ranking; coloured red.
- `FEATURE-MISSING` — the gateway cannot implement the policy
  natively; coloured amber. A distinct status from `FAIL`.
- `DEVIATION` — the cell runs, but one or more observable aspects
  differ; counted separately.

## Exact values

All constants live once in
[`gateways/_reference/values.yaml`](../gateways/_reference/values.yaml)
and are loaded by the attestation script and by every gateway config
generator.

### Shared constants

| Name                        | Value                                   |
|-----------------------------|-----------------------------------------|
| `BENCH_SERVICE_NAME`        | `bench-service`                         |
| `BENCH_UPSTREAM_HOST`       | `backend`                               |
| `BENCH_UPSTREAM_PORT`       | `8080`                                  |
| `BENCH_UPSTREAM_PATH`       | `/anything`                             |
| `BENCH_CLIENT_HEADER_ADD`   | `X-Bench-In: 1`                          |
| `BENCH_CLIENT_HEADER_DROP`  | `X-Forwarded-For`                        |
| `BENCH_SERVER_HEADER_ADD`   | `X-Bench-Out: 1`                         |
| `BENCH_SERVER_HEADER_DROP`  | `Server`                                 |
| `BENCH_JSON_FIELD_ADD_PATH` | `$.bench.injected`                       |
| `BENCH_JSON_FIELD_ADD_VAL`  | `true`                                   |
| `BENCH_JSON_FIELD_DROP_IN`  | `$.secret`                               |
| `BENCH_JSON_FIELD_DROP_OUT` | `$.origin`                               |

### p02 — JWT

- Algorithm: **HS256** (HMAC-SHA-256).
- Shared secret: `bench-jwt-hs256-secret-2026` — public by design; this
  secret has never been used in any production system.
- Canonical payload: `{ "sub": "bench", "role": "tester", "iss": "gateway-benchmarks" }`.
- Expiry: every probe token is minted with `exp = now + 3600` seconds.
- Header name carrying the token: `Authorization: Bearer <jwt>`.
- JWKS fallback: if a gateway only supports JWKS-based validation
  (not a shared secret), a static JWKS URL is served from
  [`gateways/_reference/jwks/jwks.json`](../gateways/_reference/jwks/jwks.json)
  over the benchmark network. Gateways that fall back this way are
  listed in [GATEWAYS.md § deviations](./GATEWAYS.md#deviations).

Parity probes (p02):

| # | Probe                    | Expected status |
|---|--------------------------|-----------------|
| 1 | No `Authorization`       | `401`           |
| 2 | Garbage bearer           | `401`           |
| 3 | Valid HS256 token         | `200`           |
| 4 | Expired HS256 token       | `401`           |
| 5 | Wrong-secret HS256 token  | `401`           |

### p03 — Static rate limit

- Limit: **1000 req/s** per service, rolling window = 1 second.
- Key: the service itself (all requests share one bucket).
- Above-limit behaviour: HTTP **429** with `Retry-After: 1`.
- Storage: every gateway's native store (no shared Redis).

Parity probes (p03): fire 1200 requests in 1 second. Expect at least
150 responses with status 429 (tolerance ±50). Latency of the 2XX
responses is measured in the load phase, not here.

### p04 / p05 — Dynamic rate limit

Both profiles key the limit by the **source IP** as the gateway sees
it. The load generator rotates through an IP pool using the `X-Real-IP`
header (see [`docs/LOAD-PROFILES.md`](./LOAD-PROFILES.md)) because
physical IPs cannot be rotated from a single container.

Parity note: gateways are configured to trust `X-Real-IP` **only**
from the loadgen's network; the benchmark pinned-cluster-placement-group
topology makes that trust boundary safe.

| Profile      | Limit         | IP pool size | Trust source       |
|--------------|---------------|--------------|--------------------|
| `rl-dynamic-low`  | 10 req/s per IP   | 100           | `X-Real-IP` |
| `rl-dynamic-high` | 100 req/s per IP  | 50 000        | `X-Real-IP` |

Parity probes (p04): with 10 distinct IPs firing 15 req/s each for
3 seconds, each IP must see about 15 × 429 responses (tolerance ±5).

### p06 — Request headers rewrite

Reshape applied by the gateway:

```
add:    X-Bench-In: 1
remove: X-Forwarded-For
```

Parity probes (p06): the backend (go-httpbin `/headers`) must echo
`X-Bench-In: 1` and **must not** echo `X-Forwarded-For` regardless of
what the client sent.

### p07 — Response headers rewrite

Reshape applied by the gateway to the upstream's response:

```
add:    X-Bench-Out: 1
remove: Server
```

Parity probes (p07): the client must receive `X-Bench-Out: 1` and
**must not** see a `Server:` header.

### p08 — Request body rewrite (JSON)

- Incoming body (client ⇒ gateway):

  ```json
  {
    "msg": "hello",
    "secret": "please-drop-me",
    "bench": { "from_client": true }
  }
  ```

- Outgoing body (gateway ⇒ upstream):

  ```json
  {
    "msg": "hello",
    "bench": { "from_client": true, "injected": true }
  }
  ```

- Rule: **add** `$.bench.injected = true`, **remove** `$.secret`.
- `Content-Length` and `Transfer-Encoding` must be recomputed by the
  gateway; the parity script inspects both.

Parity probes (p08): the backend's `/anything` echoes the incoming
body. Assert `.json.bench.injected == true` and `.json.secret` absent.

### p09 — Response body rewrite (JSON)

The upstream is `go-httpbin` and every `/anything` response has the
shape:

```json
{
  "method":  "GET",
  "url":     "...",
  "origin":  "172.19.0.3",
  "headers": { ... }
}
```

- Rule: **add** `$.bench.injected = true`, **remove** `$.origin`.
- `$.origin` is chosen because go-httpbin always returns it, so the
  drop rule is always exercised.
- `Content-Length` must be recomputed by the gateway.

Delivered body (gateway ⇒ client):

```json
{
  "method":  "GET",
  "url":     "...",
  "headers": { ... },
  "bench":   { "injected": true }
}
```

Parity probes (p09): the load generator asserts `$.bench.injected == true`
and `$.origin` is absent from the received body.

### p10 — Full pipeline

Composition of **p02 + p03 + p06 + p08 + p07 + p09** in that order:

```
client
  │ Authorization: Bearer <valid-hs256>        (p02)
  │ body = { "msg": "hello", "secret": "..."}
  ▼
gateway
  │ validate JWT                               (p02)
  │ decrement rate-limit bucket                (p03)
  │ add X-Bench-In, drop X-Forwarded-For       (p06)
  │ body: drop .secret, add .bench.injected     (p08)
  ▼
backend
  │ echo
  ▼
gateway
  │ body: drop .server, add .bench.injected     (p09)
  │ add X-Bench-Out, drop Server                (p07)
  ▼
client
```

Parity probes (p10): the test script runs every per-profile probe
**and** combined probes exercising the full chain at once. A single
missed transformation fails the cell.

The `full-pipeline-tls` variant is identical in payload and
transformations — the only added layer is TLS termination at the
gateway edge using the shared cert from
[`gateways/_reference/tls/`](../gateways/_reference/tls/).

## Feature availability matrix

Known or expected limitations per gateway (refined continuously in
[GATEWAYS.md § deviations](./GATEWAYS.md#deviations)):

| Profile          | wallarm | nginx | envoy | kong | apisix | traefik | tyk |
|------------------|:-------:|:-----:|:-----:|:----:|:------:|:-------:|:---:|
| p01 vanilla      | ✓       | ✓     | ✓     | ✓    | ✓      | ✓       | ✓   |
| p02 jwt          | ✓       | Lua*  | ✓     | ✓    | ✓      | plugin* | ✓   |
| p03 rl-static    | ✓       | ✓     | ✓     | ✓    | ✓      | plugin* | ✓   |
| p04 rl-dyn-low   | ✓       | ✓     | ✓     | ✓    | ✓      | plugin* | ✓   |
| p05 rl-dyn-high  | ✓       | ✓†    | ✓     | ✓    | ✓      | plugin* | ✓   |
| p06 req-headers  | ✓       | ✓     | ✓     | ✓    | ✓      | ✓       | ✓   |
| p07 resp-headers | ✓       | ✓     | ✓     | ✓    | ✓      | ✓       | ✓   |
| p08 req-body     | ✓       | Lua*  | Lua*  | ✓    | ✓      | —       | —   |
| p09 resp-body    | ✓       | Lua*  | Lua*  | ✓    | ✓      | —       | —   |
| p10 full         | ✓       | Lua*  | Lua*  | ✓    | ✓      | —       | —   |

Legend: ✓ native · `Lua*` via lua-nginx-module / Lua filter · `plugin*`
community plugin required · `†` requires explicit `zone` sizing for
the 50 k key pool · `—` no known way to implement without pulling in
a full programmability layer the gateway does not ship.

When a cell is `—`, the corresponding run is marked
`FEATURE-MISSING` and contributes only to the "features" summary, not
to the throughput ranking.

## Status

Phase 3 foundation (this document, `gateways/_reference/`, `fixtures/`,
parity script skeleton) — done.
Per-gateway configurations — in progress, tracked in
[ROADMAP.md § Phase 3](../ROADMAP.md#phase-3-parity-framework-3-5-days--core-work).
