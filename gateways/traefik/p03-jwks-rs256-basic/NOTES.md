# `traefik / p03-jwks-rs256-basic` — p03-jwks-rs256-basic scenario notes

**Verdict on `traefik:v3.3.4@sha256:cc11989f…`**: `PASS (3/3)`.

## What this scenario is — and is NOT

`p03-jwks-rs256-basic` is a policy profile in the 12-profile matrix that exercises the
**RS256 + JWKS-shaped `kid` lookup** axis. It is deliberately kept
outside the 12-profile matrix:

- The canonical [`p02-jwt`](../p02-jwt/NOTES.md) profile stays **HS256**
  — that is the profile every gateway is compared on, and traefik
  passes it via the in-repo Yaegi plugin at
  [`_shared/plugins-local/src/github.com/wallarm/jwt_hs256/`](../_shared/plugins-local/).
- This p03-jwks-rs256-basic scenario lives parallel to p02 so traefik's
  RS256 / JWKS capability can be measured **without reshaping p02's
  question** across every other gateway.
- It does not appear in `make parity-gateway-all`. It is invoked
  explicitly:

  ```bash
  make parity-gateway \
      PARITY_GATEWAY=traefik \
      PARITY_PROFILE=p03-jwks-rs256-basic
  ```

The first iteration is deliberately minimal — **one kid, one PEM,
three probes, one sidecar**. A future iteration may add an N-key
JWKS, cache-aware `forwardAuth` tuning, or a load-facing variant
that exercises sidecar cold-start fairness.

## Realisation: `forwardAuth` + OpenResty sidecar

Unlike [envoy](../../envoy/p03-jwks-rs256-basic/NOTES.md),
[apisix](../../apisix/p03-jwks-rs256-basic/NOTES.md),
[kong](../../kong/p03-jwks-rs256-basic/NOTES.md),
[tyk](../../tyk/p03-jwks-rs256-basic/NOTES.md), and
[wallarm](../../wallarm/p03-jwks-rs256-basic/NOTES.md) — where the JWT+JWKS
decision is made **inside** the gateway process by a native
filter / plugin — traefik delegates the decision to an external HTTP
service via its NATIVE [`forwardAuth`][fwd-auth] middleware. The
architecture:

```
  client ──:9080──▶ traefik ──forwardAuth──▶ jwks-auth:9091 (OpenResty sidecar)
                       │                        │
                       │                        ▼
                       │              FFI → libcrypto RS256 verify
                       │              kid → EVP_PKEY* dispatch
                       │              exp freshness check
                       │                        │
                       │ ◀──── 200 (OK) / 401 ──┘
                       ▼
                  service(backend:8080)
```

The sidecar runs the exact same request hot path as the
[nginx-column `p03-jwks-rs256-basic` profile](../../nginx/p03-jwks-rs256-basic/NOTES.md)
and shares its Lua modules (`jwt_rs256_verify.lua` +
`jwt_rs256_jwks.lua`, column-local copies under
[`./jwks-auth/lualib/`](./jwks-auth/lualib/) — same pattern apisix
uses for its ported `jwt_hs256.lua` / `body_rewrite.lua`). A drift
guard in [`setup.sh`](./setup.sh) diffs the column-local copies
against the nginx canonical on every boot, so a bugfix on the
nginx-column lualib cannot silently drift the traefik sidecar.

[fwd-auth]: https://doc.traefik.io/traefik/middlewares/http/forwardauth/

### Why a sidecar, not an in-process Yaegi plugin

Traefik plugins run in [Yaegi](https://github.com/traefik/yaegi), a
Go interpreter whose [stdlib whitelist](https://github.com/traefik/yaegi/tree/master/stdlib)
deliberately **excludes**:

- `crypto/rsa` — required for RSA public-key parse and RS256 signature verify
- `crypto/x509` — required to parse `SubjectPublicKeyInfo` PEM into
  an `rsa.PublicKey`

HS256 was an edge case Yaegi's allowlist admits (`crypto/hmac` +
`crypto/sha256`; see
[`_shared/plugins-local/src/github.com/wallarm/jwt_hs256/jwt_hs256.go`](../_shared/plugins-local/src/github.com/wallarm/jwt_hs256/jwt_hs256.go)).
Asymmetric crypto is categorically off-limits without forking
Traefik to extend Yaegi's allowlist — which we are not in the
business of shipping from a benchmark repo.

`forwardAuth` is traefik's own escape hatch for exactly this
case: when an auth decision cannot be expressed in Yaegi, delegate
it to a sibling HTTP service. It is the pattern traefik itself
documents for OAuth2, OIDC, SPIFFE, and now (for this bench) RS256.

### Why reuse the nginx-column Lua (and not write a Python / Go sidecar)

Three reasons:

1. **Zero new image pins.** The sidecar uses the exact same
   `openresty/openresty:1.27.1.2-alpine` image pin the nginx column
   already ships. No new reproducibility surface, no Dockerfile.
2. **Single canonical implementation.** The nginx column's
   `jwt_rs256_jwks.lua` is already under audit; forking it into a
   different language would mean two codebases to keep in sync.
3. **Sidecar pattern generalises.** If a future scenario needs JWKS
   for a column without native support (e.g., caddy, haproxy), the
   sidecar + `forwardAuth`-shaped pattern is already validated here.

## Compose profile gating

The sidecar is declared in [`../docker-compose.yaml`](../docker-compose.yaml)
with `profiles: [p03-jwks-rs256-basic]` so it **only** starts when
`COMPOSE_PROFILES=p03-jwks-rs256-basic` is set. That environment
variable is exported unconditionally by
[`scripts/parity-gateway.sh`](../../../scripts/parity-gateway.sh) as
`COMPOSE_PROFILES="${PROFILE}"`, so:

- Running `make parity-gateway PARITY_GATEWAY=traefik PARITY_PROFILE=p01-vanilla`
  → `COMPOSE_PROFILES=p01-vanilla` → sidecar stays down.
- Running `make parity-gateway PARITY_GATEWAY=traefik PARITY_PROFILE=p03-jwks-rs256-basic`
  → `COMPOSE_PROFILES=p03-jwks-rs256-basic` → sidecar boots alongside
  backend + gateway.

This keeps the 12 profile runs byte-for-byte identical to the
pre-p03 behaviour: the sidecar's container, image, and
bench-net IP all disappear from the stack when it isn't needed.

## `forwardAuth` semantics

The middleware configuration in [`dynamic.yaml`](./dynamic.yaml):

```yaml
middlewares:
  bench-jwks-rs256:
    forwardAuth:
      address: "http://jwks-auth:9091/verify"
      trustForwardHeader: false
```

`trustForwardHeader` defaults to `false`; we set it explicitly to
document the posture: we do NOT trust any pre-existing
`X-Forwarded-*` from the downstream client — the sidecar lives in
its own trust domain. Everything else on the middleware is left at
the default because the p03-jwks-rs256-basic fixture only asserts status
codes on its three probes and does not assert forwarded headers or
auth-response headers.

The middleware is attached to the one router so it applies to every
request path. Traefik issues a GET to `http://jwks-auth:9091/verify`
with the **original downstream headers** (in particular
`Authorization`) and returns the downstream 401 if the sidecar
returns anything other than 2xx.

## Probes

The three probes in
[`../../../fixtures/p03-jwks-rs256-basic.jsonl`](../../../fixtures/p03-jwks-rs256-basic.jsonl):

| # | Probe                                                        | Expected | Downstream response body                       |
|---|--------------------------------------------------------------|----------|------------------------------------------------|
| 1 | No `Authorization` header                                    | `401`    | traefik default (empty body, `401 Unauthorized`) |
| 2 | `Authorization: Bearer <RS256 token, kid=bench-rs256-2026>`  | `200`    | — (proxied from backend)                       |
| 3 | `Authorization: Bearer <RS256 token, kid=unknown-kid-2026>`  | `401`    | traefik default (empty body, `401 Unauthorized`) |

Probe 3 is the one that makes this scenario meaningful: the token's
signature IS valid against the canonical private key, so a verifier
that just tries every key in the store would accept it. The
sidecar's dispatch keys strictly on `header.kid` — unknown kid
rejects before any signature work — which matches what every other
JWKS-aware column in this bench does.

## Drift guard layers

[`setup.sh`](./setup.sh) runs four guards at every boot, before a
single parity probe fires:

1. **Column-local Lua = nginx canonical** — `cmp -s` against
   `../../nginx/_shared/lualib/jwt_rs256_verify.lua` and
   `../../nginx/_shared/lualib/jwt_rs256_jwks.lua`. Blocks any
   drift where a bugfix on the nginx column doesn't propagate to
   the traefik sidecar copies.
2. **Reference JWKS + PEM + kid are mutually consistent** — same
   check the nginx column runs. Catches a partial rotation where
   `kid.txt` and `jwks.json` fall out of sync.
3. **Data plane readiness** — traefik answers 401 on `/anything`
   without an Authorization header only once the sidecar is up
   AND the middleware is wired. This single signal covers both
   containers.
4. **Three mini-probes** mirror the canonical fixture — the same
   truth-table the parity runner will exercise, but run inside
   setup.sh so a failure at boot surfaces before the verdict is
   bundled.

## Known future work (not blocking first iteration)

- **Paced-arrival load variant.** Under load, `forwardAuth` adds one
  extra HTTP round-trip per request (traefik → sidecar → traefik).
  The sidecar is on bench-net with keep-alive and is trivially
  pooled, but a future `k6` scenario should measure the marginal
  latency / RPS cost vs the in-process columns (envoy jwt_authn,
  apisix openid-connect, kong jwt, nginx Lua-in-process). That is
  a Phase-4 task, not a parity one.
- **Sidecar scale-out.** The single-replica sidecar is a strict
  bottleneck under k6's p4-stress (1000 VUs). A future iteration
  may add a two-replica variant (two OpenResty containers behind a
  docker-compose round-robin alias) to study connection-churn
  behaviour at the auth-service boundary.
- **Yaegi allowlist petition.** If traefik upstream ever extends
  the Yaegi allowlist to include `crypto/rsa` (unlikely — most JWT
  plugins in the traefik plugin catalogue rely on cgo or forks for
  that reason), we can land an in-process plugin variant side-by-
  side with this sidecar path and measure the two shapes head-to-
  head. That is a multi-year wait at minimum.

## See also

- [`docs/POLICIES.md § p03-jwks-rs256-basic`](../../../docs/POLICIES.md)
  — canonical description of this scenario and why it is separate
  from p02.
- [`gateways/_reference/jwks-rs256/README.md`](../../_reference/jwks-rs256/README.md)
  — reference assets (private/public key, JWKS, canonical kid) and
  regeneration procedure.
- [`scripts/gen-jwt-rs256.sh`](../../../scripts/gen-jwt-rs256.sh)
  — RS256 token generator for `valid` and `unknown-kid`.
- [`../../nginx/p03-jwks-rs256-basic/NOTES.md`](../../nginx/p03-jwks-rs256-basic/NOTES.md)
  — sibling scenario on the nginx column, where the exact same
  Lua modules run in-process.
- [`../../envoy/p03-jwks-rs256-basic/NOTES.md`](../../envoy/p03-jwks-rs256-basic/NOTES.md),
  [`../../apisix/p03-jwks-rs256-basic/NOTES.md`](../../apisix/p03-jwks-rs256-basic/NOTES.md),
  [`../../kong/p03-jwks-rs256-basic/NOTES.md`](../../kong/p03-jwks-rs256-basic/NOTES.md),
  [`../../tyk/p03-jwks-rs256-basic/NOTES.md`](../../tyk/p03-jwks-rs256-basic/NOTES.md),
  [`../../wallarm/p03-jwks-rs256-basic/NOTES.md`](../../wallarm/p03-jwks-rs256-basic/NOTES.md)
  — sibling scenarios on the other gateway columns.
