# `wallarm / p02-jwt` — deviation notes

**Expected verdict**: `PASS (6/6)` against a Wallarm API Gateway build
whose policy registry exposes `jwt_validation`.

## Requirement

This profile relies on the native `jwt_validation` policy. The
benchmark's runner passes the Wallarm image via `WALLARM_IMAGE` (see
[`gateways/wallarm/README.md`](../README.md)), and `setup.sh` verifies
the primitive's presence at startup:

```bash
$ curl -s http://localhost:9081/policies | jq -r '.policies[].policy_id'
jwt_validation
lua_runner
ratelimit
verify_api_key
…
```

If `jwt_validation` is absent, `setup.sh` exits with `FEATURE-MISSING`
(code 42). This is purely a sanity guard — it is not expected to fire
against any build the runner would normally use; it catches the case
where `WALLARM_IMAGE` points at a build predating the policy's
introduction.

## Why we don't fall back to `lua_runner`

In principle we could implement HS256 validation inline with
`lua_runner`. We choose not to, because:

1. The benchmark's "JWT" profile is meant to measure the cost of the
   **gateway's native JWT primitive**. A hand-rolled HS256
   implementation in pure Lua, without access to a crypto library,
   would measure Lua interpreter overhead rather than the gateway's
   own auth path.
2. The source tree
   (`wallarm-api-gateway/tests/integration/jwt_validation_test.sh`)
   shows a first-class `jwt_validation` policy with `HS256`, `RS256`,
   `issuer`, `audience`, and JWKS support — so the policy **exists**,
   and the benchmark should measure it, not a Lua emulation.

## Runtime binding

The flow bound by `setup.sh` is the canonical one from
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

## Smoke probes

`setup.sh` exercises all six fixture-style probes:

- no Authorization header                 → `401`
- garbage bearer token                    → `401`
- malformed scheme                        → `401`
- valid HS256 token                       → `200`
- expired HS256 token                     → `401`
- wrong-secret HS256 token                → `401`

Tracking:
[docs/GATEWAYS.md § deviations](../../../docs/GATEWAYS.md#deviations).
