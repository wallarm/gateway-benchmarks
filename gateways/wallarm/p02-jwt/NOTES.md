# `wallarm / p02-jwt` — deviation notes

**Pinned public verdict on `wallarm/api-gateway:0.2.0`**: `FEATURE-MISSING`.

**Local override verdict on `wallarm/api-gateway:main-5f1ab30`**:
`PASS (6/6)`.

## Why

The pinned public image we have pinned —
`wallarm/api-gateway:0.2.0@sha256:a3d4d2f780e8f1f22b27e2aa450d4a5cfde6d8c51e153a900f63da464393e825`
— ships only three built-in policies, as reported by its own Admin API:

```bash
$ curl -s http://localhost:9081/policies | jq -r '.policies[].policy_id'
lua_runner
ratelimit
verify_api_key
```

There is **no `jwt_validation` policy** in this image. Attempts to
bind it via `POST /services/<svc>/routes/<rt>/flow` fail with:

```json
{
  "error": {
    "code": "INVALID_FLOW",
    "details": [{
      "field": "policy_id",
      "message": "Policy 'jwt_validation' not found in registry",
      "value": "jwt_validation"
    }]
  }
}
```

`setup.sh` now checks `/policies` at runtime. On this public image it
returns a deliberate `FEATURE-MISSING` (exit code 42 captured by
`scripts/parity-gateway.sh`) instead of a generic failure.

## Local main override

When run with:

```bash
WALLARM_IMAGE=wallarm/api-gateway:main-5f1ab30 \
    make parity-gateway PARITY_GATEWAY=wallarm PARITY_PROFILE=p02-jwt
```

the same `setup.sh` sees `jwt_validation` in `/policies`, binds the
native policy, and the fixture passes `6/6`:

- no Authorization header -> `401`
- garbage bearer token -> `401`
- malformed scheme -> `401`
- valid HS256 token -> `200`
- expired HS256 token -> `401`
- wrong-secret HS256 token -> `401`

## Why we don't fall back to `lua_runner`

In principle we could implement HS256 validation inline with
`lua_runner`. We choose not to, because:

1. The benchmark's "JWT" profile is meant to measure the cost of the
   **gateway's native JWT primitive**. A hand-rolled HS256
   implementation in pure Lua, without access to a crypto library,
   would measure Lua interpreter overhead rather than the gateway's
   own auth path.
2. The source tree (`wallarm-api-gateway/tests/integration/jwt_validation_test.sh`)
   shows a first-class `jwt_validation` policy with `HS256`, `RS256`,
   `issuer`, `audience`, and JWKS support — so the policy **exists**;
   it is just not present in this public release.

## Runtime binding

The flow bound by the local override is the canonical one from
[`docs/POLICIES.md § p02`](../../../docs/POLICIES.md#p02--jwt):

```json
{
  "request_flow": [{
    "policy_id":   "jwt_validation",
    "policy_name": "bench-p02-jwt",
    "config": {
      "algorithm":  "HS256",
      "secret_key": "bench-jwt-hs256-secret-2026"
    }
  }]
}
```

Tracking: [docs/GATEWAYS.md § deviations](../../../docs/GATEWAYS.md#deviations).
The public `0.2.0` cell stays `FEATURE-MISSING` until a released Wallarm
tag exposes `jwt_validation`.
