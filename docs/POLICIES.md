# Policy Profiles

This document expands the **eleven canonical ranking policy profiles**
defined in [TASK.md §4](../TASK.md) — plus the **one supplemental
capability scenario** `p03-jwks-rs256-basic` (off-grid; documented in
[§ p03-jwks-rs256-basic](#p03-jwks-rs256-basic) below) — into concrete,
testable configurations. Every gateway under test must be configured to
produce **externally observable** behaviour identical to what is
described below, or the corresponding cell is marked as a deviation /
`feature-missing`.

> **Numbering note.** The repository ships **12 numbered profile
> directories** (`gateways/<gw>/p01-…/` through `…/p12-…/`).
> `p03-jwks-rs256-basic` is the supplemental capability scenario; the
> other 11 (`p01, p02, p04..p12`) are the canonical ranking matrix.
> See [§ Canonical profile list](#canonical-profile-list) for the full
> mapping.

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

| #     | ID                       | Profile name                         | Role        | Description                                                                          |
|-------|--------------------------|--------------------------------------|-------------|--------------------------------------------------------------------------------------|
| p01   | `vanilla`                | Vanilla                              | ranking     | Pure proxy, no policies applied                                                      |
| p02   | `jwt`                    | JWT verification (HS256)             | ranking     | HS256 against a shared secret (`BENCH_JWT_SECRET`)                                   |
| p03   | `jwks-rs256-basic`       | JWT verification (RS256 + JWKS)      | supplemental | RS256 + static inline JWKS — capability axis, off-grid (see [§ p03-jwks-rs256-basic](#p03-jwks-rs256-basic)) |
| p04   | `rl-static`              | Static service-wide rate limit       | ranking     | 1000 req/s per service, rolling 1s window                                            |
| p05   | `rl-endpoint`            | Per-endpoint static rate limit       | ranking     | 100 req/s scoped to `/anything/limited`; `/anything/free` stays unrestricted         |
| p06   | `rl-dynamic-low`         | Dynamic rate limit, low cardinality  | ranking     | 10 req/s per client IP, pool of 100 distinct IPs                                     |
| p07   | `rl-dynamic-high`        | Dynamic rate limit, high cardinality | ranking     | 100 req/s per client IP, pool of 50 000 distinct IPs                                 |
| p08   | `req-headers`            | Request headers rewrite              | ranking     | Add `X-Bench-In: 1`, remove `X-Forwarded-For`                                        |
| p09   | `resp-headers`           | Response headers rewrite             | ranking     | Add `X-Bench-Out: 1`, remove `Server`                                                |
| p10   | `req-body`               | Request body rewrite (JSON)          | ranking     | Add `.bench.injected = true`, remove `.secret`                                       |
| p11   | `resp-body`              | Response body rewrite (JSON)         | ranking     | Add `.bench.injected = true`, remove `.origin`                                       |
| p12   | `full-pipeline`          | Full pipeline                        | ranking     | JWT ▶ rl-static ▶ req-headers ▶ req-body ▶ upstream ▶ resp-headers ▶ resp-body       |

Two of the canonical ranking profiles are additionally exercised over
**HTTP/1.1 + TLS** (per [TASK.md §6](../TASK.md)):

| Scenario ID          | Drives policy        | Protocol | Notes                                             |
|----------------------|----------------------|----------|---------------------------------------------------|
| `s13-vanilla-https`        | `p01-vanilla`         | HTTPS    | Same as `vanilla` but with TLS termination        |
| `s14-full-pipeline-https`  | `p12-full-pipeline`   | HTTPS    | Same as `full-pipeline` but with TLS termination  |

That is the full 13-scenario matrix referenced in
[TASK.md §11](../TASK.md): 11 ranking HTTP scenarios (one per ranking
profile) + 2 HTTPS scenarios. The supplemental `p03-jwks-rs256-basic`
runs through parity attestation only and is **not** part of the
ranking matrix.

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

### p02 — JWT verification (HS256)

- Algorithm: **HS256** (HMAC-SHA-256). Core p02 is deliberately a
  **symmetric-secret** probe so every gateway gets asked the exact
  same question. The asymmetric RS256 + JWKS axis lives in the
  supplemental scenario [`p03-jwks-rs256-basic`](#p03-jwks-rs256-basic)
  below, so this profile never has to flex its binding shape to
  accommodate gateways whose JWT primitive is asymmetric-only.
- Shared secret: `bench-jwt-hs256-secret-2026` — public by design; this
  secret has never been used in any production system.
- Canonical payload: `{ "sub": "bench", "role": "tester", "iss": "gateway-benchmarks" }`.
- Expiry: every probe token is minted with `exp = now + 3600` seconds.
- Header name carrying the token: `Authorization: Bearer <jwt>`.
- JWKS fallback: if a gateway only supports JWKS-based validation
  (not a shared secret), a static **HS256 (`kty: oct`) JWKS** is
  served from
  [`gateways/_reference/jwks/jwks.json`](../gateways/_reference/jwks/jwks.json)
  over the benchmark network. That JWKS is intentionally NOT the
  same asset as the p03 RS256 JWKS — it just wraps the
  same HS256 secret in JWK form. Gateways that fall back this way
  are listed in [GATEWAYS.md § deviations](./GATEWAYS.md#deviations).

Parity probes (p02):

| # | Probe                    | Expected status |
|---|--------------------------|-----------------|
| 1 | No `Authorization`       | `401`           |
| 2 | Garbage bearer           | `401`           |
| 3 | Valid HS256 token         | `200`           |
| 4 | Expired HS256 token       | `401`           |
| 5 | Wrong-secret HS256 token  | `401`           |

### p04 — Static rate limit

- Limit: **1000 req/s** per service, rolling window = 1 second.
- Key: the service itself (all requests share one bucket).
- Above-limit behaviour: HTTP **429** with `Retry-After: 1`.
- Storage: every gateway's native store (no shared Redis).

Parity probes (p04): fire 1200 requests in 1 second. Expect at least
150 responses with status 429 (tolerance ±50). Latency of the 2XX
responses is measured in the load phase, not here.

### p05 — Per-endpoint static rate limit

- Limit: **100 req/s**, rolling window = 1 second.
- Scope: a **single specific endpoint path** (the "limited" endpoint
  at `/anything/limited`), not the whole service. Every other path on
  the same gateway must stay unrestricted.
- Key: the endpoint itself. All requests to the limited path share
  one bucket; requests to any other path bypass the bucket.
- Above-limit behaviour: HTTP **429** with `Retry-After: 1`.
- Storage: every gateway's native store (no shared Redis).

This profile is **orthogonal** to p04 / p06 / p07:

- `p04` answers "can the gateway rate-limit the whole service?".
- `p06` / `p07` answer "can the gateway rate-limit per client IP?".
- **`p05` answers "can the gateway scope a rate-limit to one route
  without leaking into its neighbours?"** — a distinct production
  axis (per-endpoint policy attachment, route selector precision)
  that's particularly relevant for gateways whose rate-limit
  primitive is authored as an API-level policy (Tyk, Kong, APISIX)
  rather than a network-level filter.

Parity probes (p05): four deterministic probes exercise both sides
of the scoping invariant.

| # | Probe                                                         | Expected                       |
|---|---------------------------------------------------------------|--------------------------------|
| 1 | `GET /anything/free` (below any limit)                        | `200`                          |
| 2 | `GET /anything/limited` (below the 100-rps limit)             | `200`                          |
| 3 | 1200-request burst on `/anything/limited` in 1 s              | `>= 150 × 429` (tolerance ±50) |
| 4 | 1200-request burst on `/anything/free`    in 1 s              | `0 × 429`, `>= 1100 × 2xx`     |

Probe 4 is the scoping check: the same gateway process, the same
TCP listener, the same client pool — a burst that would trivially
trip the 100-rps limit fires against the unrestricted endpoint
instead and **must not** see a single 429.

### p06 / p07 — Dynamic rate limit

Both profiles key the limit by the **source IP** as the gateway sees
it. The load generator rotates through an IP pool using the `X-Real-IP`
header (see [`docs/LOAD-PROFILES.md`](./LOAD-PROFILES.md)) because
physical IPs cannot be rotated from a single container.

Parity note: gateways are configured to trust `X-Real-IP` **only**
from the loadgen's network; the benchmark pinned-cluster-placement-group
topology makes that trust boundary safe.

| Profile               | Limit             | IP pool size | Trust source |
|-----------------------|-------------------|--------------|--------------|
| `p06-rl-dynamic-low`  | 10 req/s per IP   | 100          | `X-Real-IP`  |
| `p07-rl-dynamic-high` | 100 req/s per IP  | 50 000       | `X-Real-IP`  |

Parity probes (p06): with 10 distinct IPs firing 15 req/s each for
3 seconds, each IP must see about 15 × 429 responses (tolerance ±5).

### p08 — Request headers rewrite

Reshape applied by the gateway:

```
add:    X-Bench-In: 1
remove: X-Forwarded-For
```

Parity probes (p08): the backend (go-httpbin `/headers`) must echo
`X-Bench-In: 1` and **must not** echo `X-Forwarded-For` regardless of
what the client sent.

### p09 — Response headers rewrite

Reshape applied by the gateway to the upstream's response:

```
add:    X-Bench-Out: 1
remove: Server
```

Parity probes (p09): the client must receive `X-Bench-Out: 1` and
**must not** see a `Server:` header.

### p10 — Request body rewrite (JSON)

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

Parity probes (p10): the backend's `/anything` echoes the incoming
body. Assert `.json.bench.injected == true` and `.json.secret` absent.

### p11 — Response body rewrite (JSON)

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

Parity probes (p11): the load generator asserts `$.bench.injected == true`
and `$.origin` is absent from the received body.

### p12 — Full pipeline

Composition of **p02 + p04 + p08 + p10 + p09 + p11** in that order:

```
client
  │ Authorization: Bearer <valid-hs256>        (p02)
  │ body = { "msg": "hello", "secret": "..."}
  ▼
gateway
  │ validate JWT                               (p02)
  │ decrement rate-limit bucket                (p04)
  │ add X-Bench-In, drop X-Forwarded-For       (p08)
  │ body: drop .secret, add .bench.injected    (p10)
  ▼
backend
  │ echo
  ▼
gateway
  │ body: drop .origin, add .bench.injected    (p11)
  │ add X-Bench-Out, drop Server               (p09)
  ▼
client
```

Parity probes (p12): the test script runs every per-profile probe
**and** combined probes exercising the full chain at once. A single
missed transformation fails the cell.

The `s14-full-pipeline-https` scenario is identical in payload and
transformations — the only added layer is TLS termination at the
gateway edge using the shared cert from
[`gateways/_reference/tls/`](../gateways/_reference/tls/).

## p03-jwks-rs256-basic

`p03-jwks-rs256-basic` is a **supplemental capability scenario** that
sits **outside** the 11-profile ranking matrix. It rides the same
parity-attestation harness (`scripts/parity-attestation.sh`, one
fixture, same probe schema) and is driven through the same entry
point:

```bash
make parity-gateway \
    PARITY_GATEWAY=<gw> \
    PARITY_PROFILE=p03-jwks-rs256-basic
```

— but it is **never** pulled into `make parity-gateway-all`, never
contributes to the throughput ranking, and never reshapes an existing
ranking profile to accommodate itself. Running it is always a
deliberate opt-in. (The number `p03` was chosen so the canonical
`p02-jwt` + RS256 capability sit next to each other in directory
listings; the canonical p02 stays HS256-only.)

The rationale: some capabilities (RS256+JWKS, mTLS client auth, OPA,
gRPC-transcoding, …) are genuine axes worth measuring but are not
things every gateway should be graded on. Locking them into the core
matrix would force the canonical p01…p12 ranking questions to bend,
which breaks "identical values across gateways" (§ Principles). A
separate supplemental track keeps the ranking matrix honest while still
letting us publish a capability read-out per gateway.

### `p03-jwks-rs256-basic` — RS256 signature validation against a static JWKS

- Algorithm: **RS256** (RSA-2048 + PKCS#1 v1.5 over SHA-256).
- Key distribution: a **static, inline JWKS** passed directly to the
  gateway's policy binding. Not `jwks_uri` — the first iteration
  deliberately has zero moving network parts.
- JWKS content: **one JWK**, derived from
  [`gateways/_reference/jwks-rs256/public.pem`](../gateways/_reference/jwks-rs256/public.pem)
  and checked in at
  [`gateways/_reference/jwks-rs256/jwks.json`](../gateways/_reference/jwks-rs256/jwks.json).
  The JWK carries the canonical `kid: bench-rs256-2026`.
- Private key:
  [`gateways/_reference/jwks-rs256/private.pem`](../gateways/_reference/jwks-rs256/private.pem)
  — public by design, like every other key material under
  `_reference/`. It is used only by
  [`scripts/gen-jwt-rs256.sh`](../scripts/gen-jwt-rs256.sh) to mint
  probe tokens.
- Payload: same template as p02 (`sub/role/iss`), expiry `now + 3600`,
  header envelope `Authorization: Bearer <jwt>`.
- Token variants (see
  [`scripts/gen-jwt-rs256.sh`](../scripts/gen-jwt-rs256.sh)):
  - `valid` — header `kid = bench-rs256-2026`, signed with the
    canonical private key.
  - `unknown-kid` — header `kid = unknown-kid-2026`, signed with the
    **same** canonical private key (so the signature itself is valid
    against the private key, but no JWK with that `kid` exists in
    the inline JWKS — a correct JWKS verifier must reject).

Parity probes (`p03-jwks-rs256-basic`):

| # | Probe                                         | Expected | Axis                                         |
|---|-----------------------------------------------|----------|----------------------------------------------|
| 1 | No `Authorization` header                     | `401`    | Missing credential                           |
| 2 | Valid RS256 token, `kid = bench-rs256-2026`    | `200`    | JWKS kid→JWK lookup + RS256 signature verify |
| 3 | RS256 token, `kid = unknown-kid-2026` (sig valid) | `401`    | JWKS kid-lookup rejects unknown key id       |

Probe 3 is the one that makes this scenario meaningful: a verifier
that just tries every JWK against the signature would accept the
token; a correct JWKS verifier keys the lookup by `kid` and must
reject because no JWK with that id exists in the inline JWKS.

Reference fixture:
[`fixtures/p03-jwks-rs256-basic.jsonl`](../fixtures/p03-jwks-rs256-basic.jsonl).
Token generator:
[`scripts/gen-jwt-rs256.sh`](../scripts/gen-jwt-rs256.sh). Reference
assets:
[`gateways/_reference/jwks-rs256/README.md`](../gateways/_reference/jwks-rs256/README.md).

### Future supplemental scenarios (tracked, not yet implemented)

- `jwks-rs256-uri` — RS256 + JWKS served over `jwks_uri`, measuring
  the JWKS-rotation path (cache TTL, cold-fetch latency, unavailable
  JWKS server). Built on the same key material as
  `p03-jwks-rs256-basic`.
- `mtls-basic` — mutual TLS with client certificate validation.

Each new supplemental scenario gets its own directory under
`gateways/_reference/<slug>/` and its own fixture under
`fixtures/<slug>.jsonl`. No supplemental scenario may modify the
canonical ranking assets (`p01, p02, p04..p12`).

## Feature availability matrix

Known or expected limitations per gateway (refined continuously in
[GATEWAYS.md § deviations](./GATEWAYS.md#deviations)):

| Profile               | wallarm | nginx | envoy | kong | apisix | traefik | tyk |
|-----------------------|:-------:|:-----:|:-----:|:----:|:------:|:-------:|:---:|
| p01 vanilla           | ✓       | ✓     | ✓     | ✓    | ✓      | ✓       | ✓   |
| p02 jwt (HS256)       | ✓       | Lua*  | Lua*  | ✓    | ✓      | plugin* | ✓   |
| p04 rl-static         | ✓       | ✓     | ✓     | ✓    | ✓      | ✓       | ✓   |
| p05 rl-endpoint       | ✓       | ✓     | ✓     | ✓    | ✓      | ✓       | ✓   |
| p06 rl-dyn-low        | ✓       | ✓     | ✓     | ✓    | ✓      | ✓‡      | ✓   |
| p07 rl-dyn-high       | ✓       | ✓†    | ✓     | ✓    | ✓      | ✓‡      | ✓   |
| p08 req-headers       | ✓       | ✓     | ✓     | ✓    | ✓      | ✓       | ✓   |
| p09 resp-headers      | ✓       | ✓     | ✓     | ✓    | ✓      | ✓       | ✓   |
| p10 req-body          | ✓       | Lua*  | Lua*  | ✓    | ✓      | plugin* | ✓   |
| p11 resp-body         | ✓       | Lua*  | Lua*  | ✓    | ✓      | plugin* | ✓   |
| p12 full-pipeline     | ✓       | Lua*  | Lua*  | ✓    | ✓      | plugin* | ✓ § |

> The supplemental [`p03-jwks-rs256-basic`](#p03-jwks-rs256-basic-capability-matrix)
> capability is reported in its own table below — by design it is
> **not** part of the ranking matrix.

Legend: ✓ native · `Lua*` via lua-nginx-module / Lua filter · `plugin*`
local Yaegi plugin shipped under `gateways/<gw>/_shared/plugins-local/`
(not a third-party catalogue dependency) · `†` requires explicit `zone`
sizing for the 50 k key pool · `‡` requires
`entryPoints.web.forwardedHeaders.insecure: true` in the static config
so traefik trusts `X-Real-IP` on the bench-net (safe because loadgen
runs against localhost; see
[GATEWAYS.md § Deviations `[gw=traefik, p=p06/p07]`](./GATEWAYS.md#deviations))
· `§` Tyk's JWT middleware (`mw_jwt.go`) hard-codes 400/403 instead
of the canonical 401 on rejection paths — capability works (PASS on
every probe that exercises the underlying primitive) but the
status-code axis is a documented PARTIAL — see
[GATEWAYS.md § Deviations `[gw=tyk, p=p02-jwt]`](./GATEWAYS.md#deviations)
· `—` no known way to implement without pulling in a full programmability
layer the gateway does not ship.

When a cell is `—`, the corresponding run is marked
`FEATURE-MISSING` and contributes only to the "features" summary, not
to the throughput ranking.

### `p03-jwks-rs256-basic` capability matrix

The supplemental `p03-jwks-rs256-basic` scenario gets its own
capability read-out. It does NOT contribute to the ranking; it
documents which gateways can natively cover the RS256 + JWKS axis.

| Scenario           | wallarm | nginx | envoy | kong | apisix | traefik | tyk |
|--------------------|:-------:|:-----:|:-----:|:----:|:------:|:-------:|:---:|
| `p03-jwks-rs256-basic` | ✓†      | ✓◊    | ✓‡    | ✓★   | ✓¶     | ✓♦      | ✓§  |

Legend: ✓ native · `†` native `jwt_validation` policy on the
from-source Wallarm API Gateway build (passed via `WALLARM_IMAGE`) —
**PASS 3/3** · `‡` native
`envoy.filters.http.jwt_authn` with `local_jwks.inline_string` on
`envoyproxy/envoy:distroless-v1.32.6` — **PASS 3/3**
(asymmetric-only — exactly the primitive this axis measures; notably
this is also why canonical p02-jwt needs a Lua-filter fallback on
envoy) · `§` native `jwt_signing_method: rsa` + JWKS-over-HTTP on
`tykio/tyk-gateway:v5.11.1` — **PASS 1/3**: capability (JWKS fetch,
`kid` lookup, RS256 verification, unknown-`kid` rejection) works
correctly, but Tyk's rejection status codes are hard-coded in
`mw_jwt.go` as `400 "Authorization field missing"` and `403 "Key not
authorized"` instead of the canonical `401`, so probes 1 and 3 FAIL
on the status-code axis while probe 2 PASSes cleanly. See
[`gateways/tyk/p03-jwks-rs256-basic/NOTES.md`](../gateways/tyk/p03-jwks-rs256-basic/NOTES.md)
for the full breakdown · `¶` native `openid-connect` plugin
(`use_jwks: true` + OIDC discovery URL) on
`apache/apisix:3.15.0-debian` — **PASS 3/3**: capability (JWKS
fetch, `kid` lookup, RS256 verification, unknown-`kid` rejection,
canonical `401` status code on every rejection path) all work
natively via `lua-resty-openidc`'s `bearer_jwt_verify`. APISIX is
deployed in standalone mode (no etcd, no Admin API); the plugin
reads `jwks_uri` out of an OIDC discovery document served by a
tiny `oidc-server` sidecar on the private bench-net, alongside
the canonical JWKS. The simpler `jwt-auth` plugin was NOT used —
it accepts a single inline `public_key` per Consumer and does NOT
perform `kid` lookup, which would collapse probe 3 into a spurious
PASS (same trap Tyk's PEM path falls into; see
[apisix#12791](https://github.com/apache/apisix/issues/12791)).
See
[`gateways/apisix/p03-jwks-rs256-basic/NOTES.md`](../gateways/apisix/p03-jwks-rs256-basic/NOTES.md)
for the full breakdown · `★` native `jwt` plugin with
`key_claim_name: kid` + per-consumer `jwt_secret` carrying
`algorithm: RS256` and `rsa_public_key: <PEM>` on
`kong/kong:3.9.1` — **PASS 3/3**: Kong's plugin hashes credentials
by `key` (wired to the JWT's `kid` claim via `key_claim_name`), so
the kid→key dispatch and RS256 verify both happen inside the native
plugin with zero custom Lua. Missing auth and unknown-kid both
reject with the canonical `401`. See
[`gateways/kong/p03-jwks-rs256-basic/NOTES.md`](../gateways/kong/p03-jwks-rs256-basic/NOTES.md)
for the full breakdown · `◊` LuaJIT-FFI to `libcrypto.so`'s
`EVP_DigestVerify*` (OpenSSL 3.x) on
`openresty/openresty:1.27.1.2-alpine` — **PASS 3/3**: pure LuaJIT
FFI calls against the `libcrypto.so.3` that OpenResty itself links
against, no extra image layers and no third-party `lua-resty-*`
dependency. JWKS + `kid` dispatch is pure Lua on top of an
`{kid → EVP_PKEY*}` map initialised in `init_by_lua_block` from the
canonical `gateways/_reference/jwks-rs256/` bind-mount.
`nginx:1.27.3-alpine` (the mainline image most nginx profiles run on)
lacks LuaJIT FFI, so the p03 profile pins OpenResty
via an in-directory `.env`. See
[`gateways/nginx/p03-jwks-rs256-basic/NOTES.md`](../gateways/nginx/p03-jwks-rs256-basic/NOTES.md)
for the full breakdown · `♦` native `forwardAuth` middleware on
`traefik:v3.3.4` delegating to an OpenResty sidecar that reuses
the nginx-column Lua modules verbatim — **PASS 3/3**: Yaegi's
stdlib allowlist excludes `crypto/rsa` and `crypto/x509`, so an
in-process plugin for asymmetric verify is architecturally off the
table (unlike HS256, which the in-repo `jwt_hs256` Yaegi plugin
already closes). The sidecar lives under the Docker Compose
profile `p03-jwks-rs256-basic`, so none of the 12 traefik profile
runs see it boot — `scripts/parity-gateway.sh` exports
`COMPOSE_PROFILES="${PROFILE}"` so the sidecar is opt-in per
profile. See
[`gateways/traefik/p03-jwks-rs256-basic/NOTES.md`](../gateways/traefik/p03-jwks-rs256-basic/NOTES.md)
for the full breakdown · `?` pending capability pass (none
outstanding).

## HTTPS scenarios (s13, s14)

The k6 load harness ships two scenarios that re-exercise the canonical
`p01-vanilla` and `p12-full-pipeline` policies over **HTTPS/1.1**
instead of plain HTTP:

| Scenario                            | Drives policy         | Protocol | Activation                                   |
|-------------------------------------|-----------------------|----------|----------------------------------------------|
| `k6/scenarios/s13-vanilla-https.js` | `p01-vanilla`         | HTTPS    | Phase 5 prerequisite (TLS plumbing)          |
| `k6/scenarios/s14-full-pipeline-https.js` | `p12-full-pipeline` | HTTPS    | Phase 5 prerequisite (TLS plumbing)          |

These two scenarios are **orthogonal** to the 12 HTTP scenarios
(`s01..s12`): they do not replace s01 or s12, they sit alongside on a
separate protocol axis. The canonical policy → scenario mapping in
[`scripts/load-orchestrator.sh`](../scripts/load-orchestrator.sh)
stays `p01 → s01-vanilla-http` / `p12 → s12-full-pipeline-http`; s13
and s14 are invoked explicitly via `--scenarios s13-vanilla-https`
(or a `--scenarios` list pairing `p01,p12` with `s13-…,s14-…`).

### Why just two HTTPS scenarios, not all twelve

The TLS handshake cost is **uniform across policy profiles** — the
gateway terminates the same ClientHello / Finished bytes regardless
of whether the downstream request then hits a pure proxy (p01), a
JWT validator (p02), a rate-limit bucket (p04..p07), a header / body
rewriter (p08..p11), or the full pipeline (p12). Measuring TLS
overhead on `p01` (the simplest downstream path, minimum gateway
work) and on `p12` (the most complex downstream path, maximum gateway
work) **sandwiches** the real TLS impact:

- `s13 − s01` → isolates the TLS-termination cost with every other
  downstream stage held at zero. Gives the "pure TLS" number.
- `s14 − s12` → isolates the TLS-termination cost when the gateway is
  also running every policy axis in parallel. Gives the "TLS under
  load" number.
- `(s14 − s12) − (s13 − s01)` → any non-zero residual is an
  **interaction** between TLS and the policy pipeline (e.g. a gateway
  doing synchronous TLS record-sealing on the same event-loop turn
  that runs Lua filters).

Running HTTPS variants for p02..p11 individually would add no
information — every one of them would land somewhere inside the
bracket defined by s13 and s14 (exactly by construction, since each
single-stage policy is a strict subset of p12). The two-scenario
bracket is the canonical design; a full per-policy HTTPS sweep is
explicitly out of scope.

### When the HTTPS scenarios activate

s13 and s14 are **dead code** until Phase 5 ships the TLS plumbing:

1. **Cert chain** under
   [`gateways/_reference/tls/`](../gateways/_reference/tls/) — the
   canonical `bench.local` leaf + CA + key, same uniform shape every
   gateway mounts.
2. **`listen 443 ssl;` (or equivalent)** on every gateway's
   configuration, reading the cert from the shared reference mount.
3. **`:8443` host-port binding** in each `gateways/<gw>/docker-compose.yaml`
   so the k6 loadgen on `bench-net` (and operators on the host) can
   reach the TLS listener.

Each scenario validates at init that `BENCH_TARGET_URL_HTTPS` is
both non-empty AND starts with `https://`, so an operator who tries
to run s13 / s14 before Phase 5 lands — or with a plain-HTTP URL by
mistake — gets a clear, actionable error message pointing at the
missing plumbing. Until Phase 5, the orchestrator leaves
`BENCH_TARGET_URL_HTTPS` unset and the scenarios are never invoked.

Phase 5's cert and TLS-config work is tracked in
[ROADMAP.md § Phase 5](../ROADMAP.md#phase-5-infrastructure-2-days);
the scenarios themselves are already landed and dormant.

## Status

- **Phase 3 — done**: this document, `gateways/_reference/`,
  `fixtures/`, and `scripts/parity-attestation.sh` are in place; the
  feature availability matrix above reflects the current parity-pass
  reality across all 7 gateways × 12 numbered profiles.
- **Phase 8 — done**: every per-cell deviation called out above is
  reproduced one-to-one in [GATEWAYS.md § Deviations summary
  table](./GATEWAYS.md#summary-table) and gated by `bench compare-runs`
  (see [REPRODUCIBILITY.md](./REPRODUCIBILITY.md)).
