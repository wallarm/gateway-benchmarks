# `wallarm / p02-jwt` — deviation notes

**Current verdict on `wallarm/api-gateway:0.2.0`**: `FEATURE-MISSING`.

## Why

The public image we have pinned —
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

## Expected follow-up

This cell will flip to `PASS` as soon as a public Wallarm release
exposes the `jwt_validation` policy. The flow we will bind is the
one canonicalised in [`docs/POLICIES.md § p02`](../../../docs/POLICIES.md#p02--jwt):

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
