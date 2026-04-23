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
│   └── lualib/               (shared Lua helpers for p02/p09/p10/p11, TBD)
├── p01-vanilla/
│   ├── envoy.yaml            (full static bootstrap: listener + cluster)
│   ├── setup.sh              (HTTP smoke — envoy is fully configured at boot)
│   └── NOTES.md              (parity compliance, uniform-setting mapping)
├── p04-rl-static/
│   ├── envoy.yaml            (p01 + local_ratelimit at HCM, service-wide 1000 rps)
│   ├── setup.sh              (single below-limit GET smoke)
│   └── NOTES.md              (parity + nginx leaky-bucket shape mapping)
├── p05-rl-endpoint/
│   ├── envoy.yaml            (HCM-level local_ratelimit globally DISABLED + typed_per_filter_config override on /anything/limited)
│   ├── setup.sh              (smoke both /anything/limited and /anything/free)
│   └── NOTES.md              (route-level override idiom; no deviation)
├── p06-rl-dynamic-low/
│   ├── envoy.yaml            (local_ratelimit + enumerated `descriptors`, 10 rps/IP)
│   ├── setup.sh              (single below-limit GET on 10.0.0.1)
│   └── NOTES.md              (parity + v1.32 enumerated-descriptors deviation)
├── p07-rl-dynamic-high/
│   ├── envoy.yaml            (same shape as p05, 100 rps/IP on 10.5.0.0/24 pool)
│   ├── setup.sh              (single below-limit GET on 10.5.0.1)
│   └── NOTES.md              (parity + v1.32 enumerated-descriptors deviation)
└── p03-jwks-rs256-basic/         
    ├── envoy.yaml            (p01 + `envoy.filters.http.jwt_authn` with `local_jwks.inline_string`)
    ├── setup.sh              (drift guard against `_reference/jwks-rs256/` + 3-probe smoke)
    └── NOTES.md              (native primitive, inline-vs-mounted rationale, 401 body shapes)
```

`p01`, `p04`, `p05`, `p06`, `p07` are the populated rate-limit and
vanilla profiles. `p03-jwks-rs256-basic` is the RS256+JWKS profile
(see
[`docs/POLICIES.md § p03-jwks-rs256-basic`](../../docs/POLICIES.md#p03-jwks-rs256-basic))
and is invoked the same way as any other:

```bash
make parity-gateway \
    PARITY_GATEWAY=envoy \
    PARITY_PROFILE=p03-jwks-rs256-basic
```

The remaining six profiles (`p02-jwt`, `p08-req-headers`,
`p09-resp-headers`, `p10-req-body`, `p11-resp-body`,
`p12-full-pipeline`) follow the same per-profile layout — each gets
its own `envoy.yaml`, `setup.sh`, `NOTES.md` and, if it needs a Lua
primitive, a reference into `_shared/lualib`.

## Config ingestion (bind-mount, with an Apple-Silicon gotcha)

`docker-compose.yaml` mounts each profile's `envoy.yaml` via a
standard `volumes:` bind-mount at `/etc/envoy/envoy.yaml:ro`.
An earlier iteration switched to Docker's `configs:` mechanism
chasing a phantom "bind-mount staleness" symptom; that symptom
turned out to be `max_connection_duration: 0s` in the HCM's
`common_http_protocol_options`, which closes every connection at
`t=0` and hides config changes behind a wall of
`curl: (52) Empty reply from server`. That field is now UNSET
across every envoy profile, so bind-mount is reliable again.

Apple-Silicon caveat: Docker Desktop's VirtioFS occasionally
caches a bind-mounted file by inode and continues serving a
pre-edit copy inside the container even after `docker compose
down -v && up`. The symptom is an otherwise-clean envoy.yaml
that envoy rejects with `no such field` / `unknown fields`
errors referencing an OLD indentation you have already fixed on
disk. The cure is a one-shot inode swap:

```bash
f=gateways/envoy/<profile>/envoy.yaml
cp "$f" "$f.new" && rm "$f" && mv "$f.new" "$f"
docker compose -f gateways/envoy/docker-compose.yaml down -v
make parity-gateway PARITY_GATEWAY=envoy PARITY_PROFILE=<profile>
```

`touch "$f"` does NOT invalidate the VirtioFS cache entry; only a
genuine inode change does. After the first successful run the
cache is refreshed and further edits via editor-native save
(which writes-then-renames, also changing the inode) work as
expected.

## Thread model: `--concurrency 1`, shared bucket

`docker-compose.yaml` pins `--concurrency 1`. Envoy's
`local_ratelimit` filter uses a **shared** token bucket across
every worker thread in the process by default (v1.17+, confirmed
by the v1.32 proto doc: "By default the token bucket is shared
across all workers, thus the rate limits are applied per Envoy
process") — not per-worker. An earlier iteration mis-read this as
per-worker and halved every `max_tokens` to compensate, which
cut the effective rate in half. We verified the shared-bucket
reality empirically on p03 (with `--concurrency 1` and
`--concurrency 2`, both produced the same 550-request pass on a
1200-req burst) and every RL profile now sizes buckets at the
canonical rate verbatim:

* `p03`: `max_tokens=200, tokens_per_fill=50, fill_interval=0.05s`
  — 1000 rps steady refill with a 200-request burst cap (matches
  nginx's leaky-bucket shape of `rate=1000r/s, burst=200`).
* `p05`: `max_tokens=10, tokens_per_fill=10, fill_interval=1s` —
  10 rps per enumerated IP.
* `p06`: `max_tokens=100, tokens_per_fill=100, fill_interval=1s` —
  100 rps per enumerated IP.

Raising `--concurrency` does not change the rate limit (single
bucket per descriptor regardless of thread count); it only
changes raw throughput headroom. One worker is the simplest
deterministic posture for parity attestation; a future load-phase
campaign can raise `--concurrency` without touching any RL
config.

## Feature matrix

| Profile                 | Envoy primitive                                     | Parity         |
|-------------------------|-----------------------------------------------------|----------------|
| `p01-vanilla`           | Single listener + `router` filter + 1 cluster       | PASS (4/4)     |
| `p02-jwt`               | Lua filter + shared `jwt_hs256` helper (see below)  | TBD            |
| `p04-rl-static`         | `envoy.filters.http.local_ratelimit` (HCM-level), canonical 1000 rps | PASS (2/2) |
| `p05-rl-endpoint`      | HCM-level `local_ratelimit` globally disabled + `typed_per_filter_config` override on `/anything/limited` (route-level), 100 rps | PASS (4/4) |
| `p06-rl-dynamic-low`    | `local_ratelimit` with enumerated `descriptors` keyed on `X-Real-IP`, 10 rps/IP | PASS (2/2)¹ |
| `p07-rl-dynamic-high`   | Same shape as p05, 100 rps/IP                       | PASS (3/3)¹    |
| `p08-req-headers`       | `request_headers_to_add` + `request_headers_to_remove` | TBD         |
| `p09-resp-headers`      | `response_headers_to_add` + `_to_remove` (+ server_header_transformation) | TBD |
| `p10-req-body`          | Lua filter reading/rewriting `request_body`         | TBD            |
| `p11-resp-body`         | Lua filter reading/rewriting `response_body`        | TBD            |
| `p12-full-pipeline`     | Composition of p02…p10 in envoy filter chain order  | TBD            |
|                         | **— p03-jwks-rs256-basic —**               |                |
| `p03-jwks-rs256-basic`‡     | Native `envoy.filters.http.jwt_authn` with `local_jwks.inline_string` | PASS (3/3) |

‡ **p03-jwks-rs256-basic** — RS256 JWT via JWKS (12-profile matrix)
and therefore NOT included in `parity-gateway-all`. Runs opt-in:
`make parity-gateway PARITY_GATEWAY=envoy PARITY_PROFILE=p03-jwks-rs256-basic`.
Measures the RS256+JWKS axis (asymmetric signature + kid→JWK lookup)
orthogonal to the HS256 question asked by canonical `p02-jwt`. No
admin-API binding — the filter is baked into the static bootstrap
and activated at container start; a drift guard in `setup.sh` greps
the reference RSA modulus + `kid` against the inline JWKS so a future
rotation of `gateways/_reference/jwks-rs256/` cannot leave the
profile stale. See
[`p03-jwks-rs256-basic/NOTES.md`](./p03-jwks-rs256-basic/NOTES.md) and
[`../../docs/POLICIES.md § p03-jwks-rs256-basic`](../../docs/POLICIES.md#p03-jwks-rs256-basic).

¹ `p05` / `p06` use envoy v1.32's `local_ratelimit` **enumerated
descriptors** (one `descriptors[]` entry per fixture IP). Blank-
value wildcard descriptors — the idiomatic "one bucket per unique
header value" shape — landed in v1.33 via envoyproxy/envoy#36623
and are therefore unavailable in the pinned column image. The
real-world 100-IP / 50 000-IP pool mandated by `docs/POLICIES.md`
will be restored in Phase 4 either by bumping the column to
v1.33+ or by pairing `local_ratelimit` with a global RLS keyed
on `X-Real-IP`. See each profile's `NOTES.md § Deviation` and
`docs/GATEWAYS.md § Deviations`.

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
