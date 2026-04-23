# traefik

Configurations for Traefik covering the 12 policy profiles defined in
[TASK.md §4](../../TASK.md) and documented in
[docs/POLICIES.md](../../docs/POLICIES.md).

## Pinned image

`traefik:v3.3.4` — minimum stable tag of the v3 line where
`experimental.localPlugins` + Yaegi runtime behave as documented.
We deliberately stay below v3.5.x: later minors ship Yaegi ABI
revisions that have not yet been exercised against the two custom
plugins under
[`_shared/plugins-local/src/github.com/wallarm/`](./_shared/plugins-local/src/github.com/wallarm/):

- [`body_rewrite/`](./_shared/plugins-local/src/github.com/wallarm/body_rewrite/) — JSON inject + drop on request / response bodies.
- [`jwt_hs256/`](./_shared/plugins-local/src/github.com/wallarm/jwt_hs256/) — HS256 JWT verifier (closes p02 + p11).

The authoritative image + digest row lives in
[docs/GATEWAYS.md](../../docs/GATEWAYS.md).

## Roster

| Profile              | Status              | Mechanism                                                                                              |
|----------------------|---------------------|--------------------------------------------------------------------------------------------------------|
| `p01-vanilla`        | **PASS 4/4**        | Single router + service, no middleware                                                                 |
| `p02-jwt`            | **PASS 6/6**        | Local Yaegi plugin `jwt_hs256` (HS256, secret inlined, `WWW-Authenticate: Bearer` on 401)              |
| `p04-rl-static`      | **PASS 2/2**        | `rateLimit` middleware, `average: 1000, burst: 200, period: 1s`                                        |
| `p05-rl-endpoint`    | **PASS 4/4**        | Two routers; `rateLimit` (100 rps) attached to `/anything/limited` only                                |
| `p06-rl-dynamic-low` | **PASS 2/2**        | `rateLimit` + `sourceCriterion.requestHeaderName: X-Real-IP`, 10 rps/IP                                |
| `p07-rl-dynamic-high`| **PASS 3/3**        | Same primitive as p05, 100 rps/IP                                                                      |
| `p08-req-headers`    | **PASS 3/3**        | `headers.customRequestHeaders` inject + empty-string drop                                              |
| `p09-resp-headers`   | **PASS 2/2**        | `headers.customResponseHeaders` inject + empty-string drop                                             |
| `p10-req-body`       | **PASS 3/3**        | Local Yaegi plugin `body_rewrite` on `target: request`                                                 |
| `p11-resp-body`      | **PASS 3/3**        | Local Yaegi plugin `body_rewrite` on `target: response`                                                |
| `p12-full-pipeline`  | **PASS 4/4**        | Chained middleware: `bench-p02 → bench-p04 → bench-p08 → bench-p10 → bench-p09 → bench-p11`            |

Full sweep verdict: **12 PASS, 0 FAIL, 0 FEATURE-MISSING, 39/39 probes.**

## Running parity

```bash
# One profile, end-to-end:
make parity-gateway PARITY_GATEWAY=traefik PARITY_PROFILE=p01-vanilla

# All profiles, end-to-end:
make parity-gateway-all PARITY_GATEWAY=traefik
```

Cold-start note: every profile mounts both Yaegi plugins
(`body_rewrite` + `jwt_hs256`); profiles that don't reference a
plugin still load it at startup. First request after a cold boot
takes ~3-5 s while Yaegi compiles the plugin source. The
profile-specific `setup.sh` polls `/anything` until it observes the
expected steady-state status code (200 for plugin-less profiles,
401 for p02/p11) before declaring readiness.

## Landed deviations

See [`docs/GATEWAYS.md § Deviations`](../../docs/GATEWAYS.md#deviations):

- `[gw=traefik, p=p06-rl-dynamic-low / p07-rl-dynamic-high,
  infra=forwardedHeaders-insecure]` — per-profile
  `entryPoints.web.forwardedHeaders.insecure: true` in
  `traefik.yaml` so the rate-limit middleware trusts the
  client-supplied `X-Real-IP` verbatim. Mandatory in this
  bench-net topology (loadgen is untrusted-peer by default).
- `[gw=traefik, p=p10-req-body / p11-resp-body / p12-full-pipeline,
  infra=yaegi-json-literal-coercion]` — `coerceJSONLiteral` shim
  in the custom `body_rewrite` plugin's `New()` constructor
  promotes YAML-stringified scalars (`"true"`, `"false"`,
  `"null"`, number-like) back to native Go types before they
  reach the JSON encoder.
- `[gw=traefik, p=p02-jwt / p12-full-pipeline,
  infra=yaegi-json-no-method-dispatch]` — Yaegi's reflect-driven
  JSON decoder silently skips method dispatch on user-declared
  types, so the textbook `flexInt` pattern (a struct with a
  custom `UnmarshalJSON` method) cannot be used. The `jwt_hs256`
  plugin works around this by decoding into
  `map[string]json.RawMessage` and re-decoding each claim
  individually as `int64` — sticks to plain stdlib types Yaegi
  hands back byte-for-byte.

## Config ingestion

Each profile ships `traefik.yaml` (static config, mounted as
`/etc/traefik/traefik.yaml`) plus `dynamic.yaml` (file provider,
mounted as `/etc/traefik/dynamic/dynamic.yaml`). The shared
`docker-compose.yaml` performs both mounts and sets
`--configFile=/etc/traefik/traefik.yaml`.

**Gotcha:** Traefik's static-config sources are mutually
exclusive — when `--configFile` is set, CLI flags and env-vars
alongside it are **silently ignored**. Every knob (entryPoint
settings, experimental flags, plugin declarations) must live
inside the YAML; do not add `--entryPoints...` flags to the
`command:` block in `docker-compose.yaml` expecting them to
override the YAML. This cost ~2h of debug on p05/p06 before it
was found.

**Secondary gotcha (macOS only):** Docker Desktop's VirtioFS
bind-mount cache occasionally keeps serving a pre-edit copy of
`traefik.yaml` or `dynamic.yaml` inside the container after a
host-side edit. Symptom: `md5sum` on host and inside the
container disagree. Fix — force an inode change:

```bash
f=gateways/traefik/<profile>/traefik.yaml
cp "$f" "$f.new" && rm "$f" && mv "$f.new" "$f"
```

`touch` does NOT invalidate the cache. Non-issue on Linux CI.

## Local Yaegi plugins

Two stdlib-only plugins live under `_shared/plugins-local/src/github.com/wallarm/`:

### `body_rewrite/` — used by p09 / p10 / p11

Inject one dotted JSON path, drop N dotted JSON paths, recompute
Content-Length on the way out. Symmetric API with the lua
counterparts in `gateways/nginx/_shared/lualib/` and
`gateways/envoy/_shared/lualib/`. Source: ~330 lines of Go
(comments dominant), only stdlib imports (`bytes`, `context`,
`encoding/json`, `io`, `net/http`, `strconv`, `strings`).

### `jwt_hs256/` — used by p02 / p11

HS256 JWT verifier. Reads `Authorization: Bearer <jwt>`, parses
the three-segment compact serialization (RFC 7515 § 3),
recomputes HMAC-SHA-256 with the configured secret, compares in
constant time (`hmac.Equal`), checks `exp` / `nbf` against
`time.Now().Unix()` with optional leeway. Refuses any non-HS256
`alg` (no `none`, no RS256, no ES256). Rejects with the
configured status code (default 401) + empty body +
`WWW-Authenticate: Bearer`. Source: ~250 lines of Go, only
stdlib imports (`context`, `crypto/hmac`, `crypto/sha256`,
`encoding/base64`, `encoding/json`, `net/http`, `strings`,
`time`) — every package on Yaegi's stdlib allowlist.

Why we ship two locally-vendored plugins instead of pulling from
the Traefik Plugin Catalog: every public JWT plugin we vetted
either bundled extra knobs the canonical fixture does not
exercise (audience, issuer, RS256 fallback), had no recent
commits, or pulled in cryptographic helpers outside Yaegi's
stdlib whitelist. Shipping ~250 lines of stdlib-only Go inside
the repo is cheaper to audit than vendoring any of those
dependencies, and it stays HS256-only on purpose so it maps 1:1
onto the canonical p02 contract.
