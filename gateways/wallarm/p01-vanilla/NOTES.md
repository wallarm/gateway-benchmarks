# wallarm / p01-vanilla

Profile: [`docs/POLICIES.md#p01-vanilla`](../../../docs/POLICIES.md#p01-vanilla).

## Shape

Plain reverse-proxy. No JWT, no rate limiting, no header / body
rewrites. Because wallarm 0.2.0 (the public tag) does not yet support
a catch-all `base_path: "/"`, we register one service per prefix
touched by the fixtures (`/anything`, `/bytes`, `/status`, `/headers`,
`/response-headers`). See [Deviations](#deviations) below.

```
client ──────────────────────────> wallarm :9080 ──> backend :8080
                                   /anything            /anything
                                   /bytes/…             /bytes/…
                                   /status/…            /status/…
                                   /headers             /headers
                                   /response-headers    /response-headers
```

## Files

| File               | Purpose |
|--------------------|---------|
| [`gateway.yaml`](./gateway.yaml) | static `unigw` config — listener, admin, pool, TCP tuning |
| [`setup.sh`](./setup.sh)         | idempotent Admin API bootstrap — one service per prefix |
| [`NOTES.md`](./NOTES.md)         | this file |

## Parity compliance

| Uniform setting (see docs/GATEWAYS.md) | Value here | Status |
|----------------------------------------|------------|--------|
| HTTP/1.1 only (downstream)             | `net.http_port`, no http2 / h2c  | matches |
| HTTP/1.1 only (upstream)               | default in unigw 0.2.0           | matches |
| Upstream pool                          | `upstream.pool.size: 1024`       | matches |
| Pool idle timeout                      | `60 s` (60 000 ms)               | matches |
| TCP keepalive                          | 90 s                             | matches |
| Access logging                         | off (not configured)             | matches |
| Admin / metrics port separation        | 9081 vs 9080                     | matches |

## Deviations

### 1. No catch-all `base_path`

**What differs.** Wallarm 0.2.0 rejects `base_path: "/"` with
`INVALID_BASE_PATH`; catch-all support was added in a later internal
build. Every other gateway under test uses one rule / `location /`.

**Root cause.** Validation in
[`crates/validation/src/base_path.rs`](https://github.com/wallarm/wallarm-api-gateway)
(private) required a non-empty suffix at 0.2.0. The fix is tracked in
the upstream repo under `NODE-7630` and is already merged on `main`.

**Resolution.** `setup.sh` registers one service per path prefix that
the fixtures touch. The client-visible contract is identical — every
`GET /anything/foo` lands on the backend as `GET /anything/foo` — so
parity is preserved.

**Impact on ranking.** None for `p01-vanilla`: the same probes run
against every gateway. The behaviour diverges only in the wallarm
admin API surface, not in the user-observable data plane.

**Status.** Accepted; will be revisited when wallarm publishes the
next public tag (post-0.2.0).

### 2. Base-path strip + trailing slash

**What differs.** Wallarm strips the registered `base_path` from the
request URI before forwarding, then appends a `/` if the remainder is
empty:

```
GET /anything       → strip /anything → ""     → upstream http://backend:8080/anything/
GET /anything/foo   → strip /anything → "/foo" → upstream http://backend:8080/anything/foo
```

`go-httpbin /anything` happily accepts both `/anything` and
`/anything/` (it mounts a handler for the prefix), but `go-httpbin
/get` does not — the trailing slash gives a 404. We work around this
by pointing each service's `target.endpoint.url` at the already-prefixed
backend URL (`http://backend:8080/anything` rather than
`http://backend:8080`), which means the backend always sees the
intended prefix.

**Impact on ranking.** None. The client observes the same JSON body.

**Status.** Accepted.

## Reproducing manually

```bash
# From the repo root
make backend-build                           # if you haven't yet
GATEWAY_PROFILE=p01-vanilla \
    docker compose -f gateways/wallarm/docker-compose.yaml up -d
bash gateways/wallarm/p01-vanilla/setup.sh
bash scripts/parity-attestation.sh \
    --gateway wallarm \
    --profile p01-vanilla \
    --target  http://localhost:9080 \
    --verbose
docker compose -f gateways/wallarm/docker-compose.yaml down -v
```

Or, using the Makefile (tears everything down at the end):

```bash
make parity-gateway PARITY_GATEWAY=wallarm PARITY_PROFILE=p01-vanilla
```

## Expected result

As of the current pin (`wallarm/api-gateway:0.2.0`), parity is
**4/4 PASS**:

```
✓ GET /status/200 returns 200
✓ GET /anything echoes method
✓ POST /anything echoes body
✓ GET /bytes/1024 returns exactly 1024 bytes
```
