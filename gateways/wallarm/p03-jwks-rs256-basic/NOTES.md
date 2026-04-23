# `wallarm / p03-jwks-rs256-basic` — p03-jwks-rs256-basic scenario notes

**Expected verdict**: `PASS (3/3)` against a Wallarm API Gateway build
whose policy registry exposes `jwt_validation` with the `RS256 + JWKS`
binding form (the same primitive requirement as
[`p02-jwt`](../p02-jwt/NOTES.md)).

## What this scenario is — and is NOT

`p03-jwks-rs256-basic` is a policy profile in the 12-profile matrix that exercises the
**RS256 + JWKS** axis against the Wallarm gateway. It is deliberately
kept outside the 12-profile matrix:

- The canonical [`p02-jwt`](../p02-jwt/NOTES.md) profile stays **HS256**
  against a shared secret; it is the profile everyone gets compared on.
- This p03-jwks-rs256-basic scenario lives parallel to p02 so that a gateway's
  RS256 / JWKS capability can be measured **without reshaping p02's
  question** across every other gateway.
- It does not appear in `make parity-gateway-all`. It is invoked
  explicitly:

  ```bash
  make parity-gateway \
      PARITY_GATEWAY=wallarm \
      PARITY_PROFILE=p03-jwks-rs256-basic
  ```

The first iteration is deliberately minimal — **static inline JWKS**
and three probes. A future iteration may add a `jwks_uri` variant, an
`unknown-kid-with-forged-signature` probe, or issuer / audience checks.

## Shared shape with p02-jwt

The static config in [`gateway.yaml`](./gateway.yaml) is byte-for-byte
identical to [`../p02-jwt/gateway.yaml`](../p02-jwt/gateway.yaml) on
purpose: the only thing that differs between the canonical p02 run
and this p03 run is the policy binding emitted by
[`setup.sh`](./setup.sh).

| Aspect          | `p02-jwt`                          | `p03-jwks-rs256-basic`                              |
|-----------------|------------------------------------|-------------------------------------------------|
| Algorithm       | `HS256`                            | `RS256`                                         |
| Key source      | `secret_key: <shared bench secret>` | `jwks: { keys: [<one RSA JWK>] }` (inline)      |
| Reference files | `../../_reference/jwt/`            | `../../_reference/jwks-rs256/`                  |
| Token generator | `scripts/gen-jwt.sh`               | `scripts/gen-jwt-rs256.sh`                      |
| Fixture         | `fixtures/p02-jwt.jsonl` (6 probes) | `fixtures/p03-jwks-rs256-basic.jsonl` (3 probes)   |

The probes themselves deliberately form a subset of the p02 fixture:
"missing token → 401", "valid → 200", "bad → 401". The "bad" case here
is a token whose `kid` is absent from the JWKS — which is the axis the
scenario is really about.

## Runtime binding

On a main/unreleased image that exposes `jwt_validation`,
[`setup.sh`](./setup.sh) binds:

```json
{
  "request_flow": [{
    "policy_id":   "jwt_validation",
    "policy_name": "bench-p03-jwks-rs256-basic",
    "config": {
      "algorithm": "RS256",
      "jwks": {
        "keys": [{
          "kty": "RSA",
          "use": "sig",
          "alg": "RS256",
          "kid": "bench-rs256-2026",
          "n":   "<base64url modulus from public.pem>",
          "e":   "AQAB"
        }]
      }
    }
  }]
}
```

The shape matches
[`wallarm-api-gateway/tests/integration/jwt_validation_test.sh § test_07`](../../../wallarm-api-gateway/tests/integration/jwt_validation_test.sh)
verbatim. `issuer` / `audience` are deliberately omitted so the first
iteration only asks one question: "does the policy correctly resolve
the token's `kid` against the static JWKS and verify the RS256
signature?".

## Sanity-check probes in `setup.sh`

[`setup.sh`](./setup.sh) uses a two-stage guard to keep the verdict
honest across images the runner might have pointed `WALLARM_IMAGE` at:

1. **`GET /policies`** — if `jwt_validation` is not registered, exit
   with `FEATURE-MISSING` (exit code 42, captured by
   [`scripts/parity-gateway.sh`](../../../scripts/parity-gateway.sh)).
2. **`POST /services/<svc>/flow`** with the RS256+JWKS binding above.
   If the policy exists but the binding is rejected (HTTP 400), surface
   a distinct `FEATURE-MISSING` with a reason that points at the
   binding rather than the registry — this covers a hypothetical
   transitional build where HS256 works but RS256 hasn't landed yet.

The expected outcome on a build that ships the full `jwt_validation`
policy is `PASS (3/3)` — two 401s + one 200.

## Probes

The three probes in
[`../../../fixtures/p03-jwks-rs256-basic.jsonl`](../../../fixtures/p03-jwks-rs256-basic.jsonl):

| # | Probe                                                   | Expected | Axis                                               |
|---|---------------------------------------------------------|----------|----------------------------------------------------|
| 1 | No `Authorization` header                               | `401`    | Missing credential                                 |
| 2 | `Authorization: Bearer <RS256 token, kid=bench-rs256-2026>` | `200`    | Signature verifies; kid resolves in JWKS           |
| 3 | `Authorization: Bearer <RS256 token, kid=unknown-kid-2026>` | `401`    | Signature is mathematically valid for bench's private key — but the verifier **must** reject because no JWK with `kid=unknown-kid-2026` exists in the inline JWKS |

Probe 3 is the one that makes this scenario meaningful: the token's
signature IS valid against the canonical private key, so a verifier
that just tries every key in the JWKS would accept it; a verifier that
correctly uses the `kid` as an index into the JWKS must reject.

## Why inline JWKS (not `jwks_uri`) for the first iteration

1. Deterministic: no background HTTP fetch, no cache TTL, no DNS.
2. No new moving part in the topology (no additional container to
   serve `/.well-known/jwks.json`).
3. Focus: the axis we care about first is **static JWKS kid lookup +
   RS256 verify**, not JWKS rotation semantics. The latter is a
   separate, richer axis worth its own p03-jwks-rs256-basic scenario.

Future iterations may add `jwks-rs256-uri` as a distinct scenario once
the inline form is green across every gateway that can do it.

## See also

- [`docs/POLICIES.md § p03-jwks-rs256-basic`](../../../docs/POLICIES.md)
  — canonical description of this scenario and why it is separate
  from p02.
- [`gateways/_reference/jwks-rs256/README.md`](../../_reference/jwks-rs256/README.md)
  — reference assets (private/public key, JWKS, canonical kid).
- [`scripts/gen-jwt-rs256.sh`](../../../scripts/gen-jwt-rs256.sh)
  — RS256 token generator for `valid` and `unknown-kid`.
- [`gateways/wallarm/p02-jwt/NOTES.md`](../p02-jwt/NOTES.md)
  — twin scenario for HS256 shared secret.
