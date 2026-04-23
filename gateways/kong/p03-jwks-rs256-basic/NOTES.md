# `kong / p03-jwks-rs256-basic` — p03-jwks-rs256-basic scenario notes

**Verdict on `kong/kong:3.9.1`**: `PASS (3/3)`.

## What this scenario is — and is NOT

`p03-jwks-rs256-basic` is a policy profile in the 12-profile matrix that exercises the
**RS256 + JWKS-shaped `kid` lookup** axis. It is deliberately kept
outside the 12-profile matrix:

- The canonical [`p02-jwt`](../p02-jwt/NOTES.md) profile stays **HS256**
  — that is the profile every gateway is compared on.
- This p03-jwks-rs256-basic scenario lives parallel to p02 so kong's JWKS /
  RS256 capability can be measured **without reshaping p02's question**
  across every other gateway.
- It does not appear in `make parity-gateway-all`. It is invoked
  explicitly:

  ```bash
  make parity-gateway \
      PARITY_GATEWAY=kong \
      PARITY_PROFILE=p03-jwks-rs256-basic
  ```

The first iteration is deliberately minimal — **a single credential,
statically keyed by the canonical `kid`, three probes**. A future
iteration may add an N-key JWKS (multiple credentials in `jwt_secrets`
keyed by distinct `kid`s with per-key rotation) and an
`unknown-kid-with-forged-signature` probe.

## Native primitive

Kong ships RS256 in the stock [`jwt`][jwt-plugin] plugin (available on
OSS kong 3.x; no enterprise-only gate). Like wallarm, envoy, apisix,
and tyk — and unlike nginx / traefik — kong's JWKS capability is a
pure declarative-config exercise: no Lua, no sidecar, no plugin
install.

The realisation in [`kong.yml`](./kong.yml):

```yaml
consumers:
  - username: bench
    jwt_secrets:
      - key: bench-rs256-2026          # canonical kid
        algorithm: RS256
        rsa_public_key: |              # reference PEM (byte-for-byte)
          -----BEGIN PUBLIC KEY-----
          …
          -----END PUBLIC KEY-----

services:
  - name: bench
    url: http://backend:8080
    routes: [{ name: bench-route, paths: ["/"] }]
    plugins:
      - name: jwt
        config:
          key_claim_name: kid          # fall-through: payload.kid → header.kid
          claims_to_verify: [exp]
          run_on_preflight: false
```

Everything else (upstream URL, route, DB-less mode, kong headers off)
is byte-for-byte identical to the core kong columns so the only axis
the parity fixture can measure is the JWT/JWKS primitive itself.

[jwt-plugin]: https://docs.konghq.com/hub/kong-inc/jwt/

## Kong's plugin is not a JWKS consumer — and that is fine

Unlike [`envoy`'s `jwt_authn` filter](../../envoy/p03-jwks-rs256-basic/NOTES.md)
(which ingests a JWKS document wholesale via `local_jwks.inline_string`)
or [`apisix`'s `openid-connect` plugin](../../apisix/p03-jwks-rs256-basic/NOTES.md)
(which fetches JWKS from a discovery URL), kong's `jwt` plugin only
accepts one PEM-encoded RSA public key per credential. We feed it the
single key that backs the canonical JWKS — semantically equivalent for
a one-key JWKS, which is exactly what the p03-jwks-rs256-basic fixture
exercises.

Why this works as a `kid` lookup despite not being a JWKS ingestion:

1. Kong's `jwt` plugin is built around **per-consumer credentials**
   indexed by an arbitrary claim (`config.key_claim_name`).
2. Setting `key_claim_name: kid` and registering **one** credential
   with `key = bench-rs256-2026` makes:
   - a token whose header claims `kid = bench-rs256-2026` → match the
     single credential → verify against `rsa_public_key` → PASS on
     valid signature.
   - a token whose header claims `kid = unknown-kid-2026` → no
     credential with `key = unknown-kid-2026` → kong 401 "no
     credentials found for given `iss`" (message still says `iss`
     regardless of `key_claim_name`; cosmetic — see § Cosmetic
     deviations).
   - a request with no `Authorization` header → plugin 401 before any
     credential lookup.
3. All three outcomes match the fixture. The semantic difference
   between "single-credential PEM lookup by kid" and "multi-key JWKS
   lookup by kid" is irrelevant for a one-key JWKS.

The one cost is that a future N-key JWKS fixture will have to
declare N credentials in `jwt_secrets[]` instead of plopping a larger
JWKS document in. That is a scenario-level decision, not a kong
limitation — we will cross it when it lands.

## Why `key_claim_name: kid`, not `iss`

The default is `key_claim_name: iss`. With `iss` the canonical RS256
token (`iss: gateway-benchmarks`) would match one and only one
credential keyed by `gateway-benchmarks` — and **both** the valid and
the unknown-kid tokens would match (they share the same `iss`). Probe
3 would then either:

- pass the signature check (because both tokens are signed by the
  same private key), which would return 200 and **fail** the probe,
  or
- fail because the verify would pass but something else. No, in
  fact it would PASS the sig check on both, so probe 3 would return
  200 instead of 401.

The only axis that distinguishes the two tokens is the `kid` claim in
the JWT **header**. Pointing `key_claim_name` at `kid` makes that axis
load-bearing:

- kong's `jwt.load` reads `payload.kid` first (absent in our tokens —
  canonical payload is `{sub, role, iss, iat, exp}`; see
  [`gateways/_reference/jwt/payload-template.json`](../../_reference/jwt/payload-template.json)),
- falls back to `header.kid` (always present from
  [`scripts/gen-jwt-rs256.sh`](../../../scripts/gen-jwt-rs256.sh)),
- and dispatches credential lookup on that value.

This is the exact semantics other JWKS-aware gateways (envoy, apisix,
wallarm) encode in their native filters / plugins.

## Cosmetic deviations

Kong 3.9.1's `jwt` plugin always phrases the 401 body as
`No credentials found for given 'iss'` regardless of
`config.key_claim_name`. This is a hard-coded string in
`plugins/jwt/handler.lua` (same class of cosmetic deviation as
tyk's `mw_jwt.go` `400`/`403` literals — see
[`../p02-jwt/NOTES.md § Cosmetic deviations`](../p02-jwt/NOTES.md) if
that file ever documents it; the canonical fixture does not assert
body shape on the 401 probes, so the deviation has no impact on the
verdict).

## Probes

The three probes in
[`../../../fixtures/p03-jwks-rs256-basic.jsonl`](../../../fixtures/p03-jwks-rs256-basic.jsonl):

| # | Probe                                                        | Expected | Kong response body (401 probes)                    |
|---|--------------------------------------------------------------|----------|----------------------------------------------------|
| 1 | No `Authorization` header                                    | `401`    | `{"message":"Unauthorized"}`                       |
| 2 | `Authorization: Bearer <RS256 token, kid=bench-rs256-2026>`  | `200`    | —                                                  |
| 3 | `Authorization: Bearer <RS256 token, kid=unknown-kid-2026>`  | `401`    | `{"message":"No credentials found for given 'iss'"}` |

Probe 3 is the one that makes this scenario meaningful: the token's
signature IS valid against the canonical private key, so a verifier
that just tries every key in the store would accept it; a verifier
that correctly uses the `kid` as an index into the key material must
reject. Kong does the correct thing.

## Drift guard (setup.sh)

Kong loads the declarative config at container start (DB-less mode;
see [`../docker-compose.yaml`](../docker-compose.yaml)); there is no
Admin API binding to verify at runtime. [`setup.sh`](./setup.sh)
therefore does three things:

1. Waits for the data plane (the proxy returns 401 as soon as kong
   finishes loading `kong.yml` — that is the readiness signal).
2. Drift guard: asserts the interior PEM canary (second line of the
   reference `public.pem`) still appears verbatim in `kong.yml`, and
   the consumer credential `key` still matches
   [`gateways/_reference/jwks-rs256/kid.txt`](../../_reference/jwks-rs256/kid.txt).
   If the reference is ever rotated and someone forgets to refresh
   `kong.yml`, the guard fails before a single probe runs.
3. Smokes the three mini-probes that mirror the fixture so a failure
   at boot surfaces before the parity runner even starts.

Unlike [`gateways/wallarm/p03-jwks-rs256-basic/setup.sh`](../../wallarm/p03-jwks-rs256-basic/setup.sh),
this `setup.sh` has NO `FEATURE-MISSING` fallback path: kong 3.x
ships RS256 in the stock `jwt` plugin. If the plugin misbehaves it is
a FAIL, not a FEATURE-MISSING.

## See also

- [`docs/POLICIES.md § p03-jwks-rs256-basic`](../../../docs/POLICIES.md)
  — canonical description of this scenario and why it is separate
  from p02.
- [`gateways/_reference/jwks-rs256/README.md`](../../_reference/jwks-rs256/README.md)
  — reference assets (private/public key, JWKS, canonical kid).
- [`scripts/gen-jwt-rs256.sh`](../../../scripts/gen-jwt-rs256.sh)
  — RS256 token generator for `valid` and `unknown-kid`.
- [`../../envoy/p03-jwks-rs256-basic/NOTES.md`](../../envoy/p03-jwks-rs256-basic/NOTES.md),
  [`../../apisix/p03-jwks-rs256-basic/NOTES.md`](../../apisix/p03-jwks-rs256-basic/NOTES.md),
  [`../../tyk/p03-jwks-rs256-basic/NOTES.md`](../../tyk/p03-jwks-rs256-basic/NOTES.md),
  [`../../wallarm/p03-jwks-rs256-basic/NOTES.md`](../../wallarm/p03-jwks-rs256-basic/NOTES.md)
  — sibling scenarios on the other gateway columns.
