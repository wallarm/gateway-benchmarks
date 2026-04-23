# tyk · p02-jwt

## Verdict

**FAIL 2/6** on tyk 5.11.1 OSS.

| # | Probe                                        | Expected | Observed | Verdict |
| - | -------------------------------------------- | -------- | -------- | ------- |
| 1 | no Authorization header                      | `401`    | `400`    | **FAIL** |
| 2 | garbage bearer token                         | `401`    | `403`    | **FAIL** |
| 3 | malformed Authorization scheme (`Basic …`)   | `401`    | `403`    | **FAIL** |
| 4 | valid HS256 token                            | `200`    | `200`    | **PASS** |
| 5 | expired HS256 token                          | `401`    | `401`    | **PASS** |
| 6 | wrong-secret HS256 token                     | `401`    | `403`    | **FAIL** |

The capability itself — HMAC-SHA-256 signature validation against a
shared secret, expiration check, hard rejection of bad signatures and
malformed/missing tokens — is fully native and works correctly. The
four FAILs are **purely cosmetic status-code differences**: Tyk
rejects the bad requests but returns its own HTTP codes instead of
the canonical `401` every other gateway returns.

This is the exact same deviation already documented for the
[`p03-jwks-rs256-basic`](../p03-jwks-rs256-basic/NOTES.md)
scenario — both probes hit the same `mw_jwt.go` code path because
HMAC and RSA share the rejection codes:

| Failure                            | Hard-coded status              | Code path |
| ---------------------------------- | ------------------------------ | --------- |
| Missing `Authorization`            | `400 Bad Request`              | early-return at `getAuthToken` |
| Parse / signature / wrong key      | `403 Forbidden`                | `errorAndStatusCode("Key not authorized", http.StatusForbidden)` |
| `exp` claim in the past            | `401 Unauthorized`             | dedicated branch — passes through `errorTokenExpired` which DOES emit 401 |

Probe 5 lands on the `exp` branch (the only path in `mw_jwt.go` that
returns `401`) and PASSes; probes 1, 2, 3, 6 all hit the `400`/`403`
branches and FAIL on the status-code axis even though Tyk has
correctly identified each as a bad request.

Neither status code is overridable in Tyk Classic OSS — the literals
`http.StatusBadRequest` and `http.StatusForbidden` are inlined in
`tyk/gateway/mw_jwt.go` (v5.11.1) and there is no config knob in
the Classic API definition or `tyk.standalone.conf` that swaps them.
A workaround using a JSVM pre-middleware to intercept and re-emit
`401` would require ~250 LoC of pure-JS HMAC-SHA-256 (otto ships no
crypto bindings), which would also displace the native code path and
defeat the point of measuring the native primitive.

## Native primitive

API definition lives in [`apis/bench.json`](./apis/bench.json):

| Field                          | Value                                                | Why                                                  |
| ------------------------------ | ---------------------------------------------------- | ---------------------------------------------------- |
| `enable_jwt`                   | `true`                                               | turns on `mw_jwt.go`                                 |
| `jwt_signing_method`           | `"hmac"`                                             | selects the HMAC validation branch                   |
| `jwt_source`                   | `"YmVuY2gtand0LWhzMjU2LXNlY3JldC0yMDI2"`             | base64-encoded shared HMAC secret (`bench-jwt-hs256-secret-2026`) — `mw_jwt.go` decodes it and uses the bytes directly |
| `jwt_identity_base_field`      | `"iss"`                                              | hash session by `iss = gateway-benchmarks` (every probe shares one ephemeral session — fine, policy applies no rate limit / quota) |
| `jwt_skip_kid`                 | `true`                                               | HMAC tokens have no `kid` header                     |
| `jwt_default_policies`         | `["bench-default-policy"]`                           | required: without a policy Tyk returns `403 "no session found for token user identity"` even for valid tokens |
| `jwt_*_validation_skew`        | `1`                                                  | matches the canonical 1 s clock-skew envelope used everywhere else |

The shared `bench-default-policy` lives in
[`../_policies/policies.json`](../_policies/policies.json) and grants
the `bench` `api_id` access via `access_rights.bench` — without that
entry every signed token would be `403`'d at policy resolution time.

## Setup flow

`scripts/parity-gateway.sh` boots the stack, then
[`setup.sh`](./setup.sh) does:

1. Wait for `GET /hello` to return `{"status":"pass"}` (Tyk's
   liveness endpoint; a slow Redis boot shows up here first).
2. Confirm `/tyk/apis` reports `api_id=bench` with
   `enable_jwt=true` — i.e. Tyk parsed the API definition.
3. Confirm `/tyk/policies` reports `bench-default-policy` with the
   `bench` API in its `access_rights`.

No probe smoke is run from `setup.sh` — the canonical
`parity-attestation.sh` runner exercises all six probes and captures
the four cosmetic FAILs in the JSONL report on its own.

## Files in this profile

| Path                         | Role                                                 |
| ---------------------------- | ---------------------------------------------------- |
| `apis/bench.json`            | Tyk Classic API definition with HMAC JWT middleware  |
| `setup.sh`                   | Readiness + API-loaded + policy-loaded checks        |
| `NOTES.md`                   | This document                                        |

Shared with every tyk profile:

| Path                         | Role                                                 |
| ---------------------------- | ---------------------------------------------------- |
| `../tyk.standalone.conf`     | Standalone Tyk config (file-based apps/policies)     |
| `../_policies/policies.json` | Permissive `bench-default-policy` (ACL only)         |
| `../docker-compose.yaml`     | 4-service stack: backend + redis + jwks + gateway    |
