# tyk · p03-jwks-rs256-basic

> p03-jwks-rs256-basic (NOT part of the 12-profile matrix). See
> [`docs/POLICIES.md § p03-jwks-rs256-basic`](../../../docs/POLICIES.md)
> for the full contract.

## Verdict

**PARTIAL PASS 1/3** on tyk 5.11.1 OSS.

| Probe                                      | Expected | Observed | Verdict | Why                                                                                                 |
| ------------------------------------------ | -------- | -------- | ------- | --------------------------------------------------------------------------------------------------- |
| no Authorization header                    | `401`    | `400`    | **FAIL**| Tyk's JWT middleware returns `400 "Authorization field missing"` (hard-coded in `mw_jwt.go`).       |
| valid RS256 token, canonical `kid`         | `200`    | `200`    | **PASS**| Native JWKS URL fetch + `kid` lookup + RS256 verification all work.                                 |
| valid RS256 signature, `kid=unknown-kid-…` | `401`    | `403`    | **FAIL**| Tyk returns `403 "Key not authorized"` for any failed signature / unknown-`kid` rejection path.     |

The capability itself — JWKS-over-HTTP with `kid` lookup, RS256
signature verification, rejection of unknown-`kid` tokens — is fully
native. The two FAILs are purely **cosmetic status-code differences**;
Tyk still rejects the bad requests, just with its own HTTP codes
instead of the canonical `401` every other gateway returns. Neither
response code is configurable in Tyk Classic OSS — they live in
`tyk/gateway/mw_jwt.go` as literal `http.StatusBadRequest` and
`http.StatusForbidden` returns.

Run locally with:

```bash
make parity-gateway \
    PARITY_GATEWAY=tyk \
    PARITY_PROFILE=p03-jwks-rs256-basic
```

## Native primitive

Tyk's `jwt_signing_method: "rsa"` + JWKS-over-URL is implemented in
[`gateway/mw_jwt.go`][tyk-mw-jwt] of the Tyk Gateway source tree.
The interesting call path for this scenario is:

```
processRequest (HCM)
    └─ JWTMiddleware.ProcessRequest
        └─ getSecretToVerifySignature
            └─ getSecretFromURL             ◀── JWKS fetch + kid lookup
        └─ processCentralisedJWT
            └─ generateSessionFromPolicy    ◀── applies jwt_default_policies
            └─ ApplyPolicies                ◀── bench-default-policy
```

1. On the first request, `getSecretFromURL` fetches the JWKS
   document at `jwt_source`, caches it for 240 s, and looks up the
   JWK whose `kid` matches the incoming token's `header.kid`.
2. RS256 signature verification happens against the matched JWK's
   `(n, e)` via `go-jose/v3`.
3. `processCentralisedJWT` hydrates an ephemeral session using
   `jwt_identity_base_field` (→ `sub`) and applies every policy id
   listed in `jwt_default_policies` — here the permissive
   `bench-default-policy` from
   [`gateways/tyk/_policies/policies.json`](../_policies/policies.json).

[tyk-mw-jwt]: https://github.com/TykTechnologies/tyk/blob/v5.11.1/gateway/mw_jwt.go

## Why a JWKS sidecar?

Tyk's `jwt_source` field has **two distinct parse modes** (see
`getSecretToVerifySignature` in mw_jwt.go):

1. **URL mode** — the base64-decoded value matches `^(http|https):`.
   Tyk fetches the JWKS and performs a `kid` lookup. RS256 + kid
   works.
2. **Static-key mode** — the base64-decoded value is a raw HMAC
   secret (for `jwt_signing_method: "hmac"`) or a PEM-encoded public
   key (for `jwt_signing_method: "rsa"`). **The PEM path has no
   `kid` lookup**: it just verifies every token against the one
   key. That collapses probe 3 into a PASS we did not earn — an
   attacker-forged token signed with the real private key but
   carrying an unknown `kid` would be accepted.

There is no `file://` scheme support in Tyk's URL matcher (the
regexp is literally `^(http|https):`). To exercise the real
kid-lookup axis we therefore stand up a tiny static server on
`bench-net`:

```
gwb-tyk  ─── jwt_source: base64("http://jwks-server/.well-known/jwks.json") ───▶  gwb-tyk-jwks-server
  ▲                                                                                  │
  │                                                                                  │
  └─── reads /.well-known/jwks.json ◀── bind mount: _reference/jwks-rs256/jwks.json
```

See [`gateways/tyk/docker-compose.yaml`](../docker-compose.yaml) for the
topology and [`gateways/tyk/_jwks-server/nginx.conf`](../_jwks-server/nginx.conf)
for the single-endpoint nginx configuration.

This is **not** a deviation from the canonical scenario definition:
the canonical definition only constrains the probe shape (three
statuses) and the reference material (`gateways/_reference/jwks-rs256/
jwks.json`). How a gateway internally ingests the JWKS — inline,
local file, or HTTP URL — is a free axis. The scenario's invariant is
that the JWKS byte content matches `_reference/jwks-rs256/jwks.json`,
which `setup.sh`'s drift guard enforces at every run.

## Why is `jwt_source` base64-encoded?

```jsonc
  "jwt_source": "aHR0cDovL2p3a3Mtc2VydmVyLy53ZWxsLWtub3duL2p3a3MuanNvbg==",
  // "http://jwks-server/.well-known/jwks.json"
```

Tyk's docs (the [JWT authentication section][tyk-jwt-docs]) prescribe
the base64 encoding for every `jwt_source` value — URL or PEM. We
followed it here after diagnosing a second-request failure:

[tyk-jwt-docs]: https://tyk.io/docs/api-management/authentication/jwt-signature-validation

The relevant code path in `mw_jwt.go` at v5.11.1 is:

```go
// getSecretFromURL (v5.11.1)
cachedAPIDefRaw, foundDef := jwkCache.Get(cacheAPIDef)
if foundDef {
    cachedAPIDef, _ := cachedAPIDefRaw.(*apidef.APIDefinition)
    decodedURL, err := base64.StdEncoding.DecodeString(cachedAPIDef.JWTSource)
    if err != nil {
        return nil, err   // ← hard fail on the 2nd request if JWTSource is a plain URL
    }
    if string(decodedURL) != url { ... }
}
```

With a plain `"http://..."` JWTSource:

* Request #1 — `foundDef == false`, we skip the decode branch and
  the fresh fetch works. The JWKS is cached. The API definition is
  cached **with the plain-URL string as its JWTSource**.
* Request #2 — `foundDef == true`; the code base64-decodes the
  cached plain URL, hits `illegal base64 data at input byte 4`
  (byte 4 of `http:` is `:`, which is not a valid base64 character),
  and returns the error directly. Tyk logs `level=error
  msg="JWT validation error"` and serves `403 "Key not authorized"`
  to the client — a misleading error for what is really a
  configuration-shape bug.

Base64-encoding the URL makes every subsequent request go through
the happy path: `decodedURL == url`, cache hits, no refetch.

## Setup flow

`scripts/parity-gateway.sh` boots the stack, then
[`setup.sh`](./setup.sh) does:

1. Wait for `GET /hello` to return `{"status":"pass"}` (the Tyk
   liveness endpoint; a slow Redis boot shows up here first).
2. Confirm that `/tyk/apis` reports `api_id=p03-jwks-rs256-basic` —
   i.e. Tyk successfully parsed `apis/p03-jwks-rs256-basic.json`.
3. Drift-guard: fetch the JWKS from inside the `jwks-server`
   container itself and compare `keys[0].n` + `keys[0].kid`
   against `_reference/jwks-rs256/jwks.json`.
4. Smoke three mini-probes mirroring the fixture. `setup.sh` is
   lenient on the rejection status (accepts any 4xx) and strict on
   the success (must be exactly 200); the exact-status divergence
   for probes 1 and 3 is captured by the canonical parity runner
   as 2 FAILs in the JSONL report.

No Admin-API mutation happens — the API definition and the default
policy are mounted read-only at container start and Tyk hot-loads
them from disk.

## Files in this profile

| Path                                        | Role                                          |
| ------------------------------------------- | --------------------------------------------- |
| `apis/p03-jwks-rs256-basic.json`                | Tyk Classic API definition with JWT middleware |
| `setup.sh`                                  | Readiness + drift guard + 3-probe smoke       |
| `NOTES.md`                                  | This document                                 |

Shared with every tyk profile:

| Path                                        | Role                                          |
| ------------------------------------------- | --------------------------------------------- |
| `../tyk.standalone.conf`                    | Standalone Tyk config (file-based apps/policies) |
| `../_policies/policies.json`                | The single permissive `bench-default-policy`  |
| `../_jwks-server/nginx.conf`                | Static JWKS HTTP origin on `bench-net`        |
| `../docker-compose.yaml`                    | 4-service stack: backend + redis + jwks + gateway |

## Known limits

* **Non-canonical rejection codes (2 FAILs out of 3).** Tyk's JWT
  middleware returns `400` for missing Authorization and `403` for
  every signature / kid / authz rejection. Every other gateway in
  this repo returns `401` in both cases. The canonical fixture
  expects `401`, so Tyk lands on a documented **1/3 PASS** —
  probe 2 PASSes cleanly, probes 1 and 3 FAIL only on the status
  code, not on the underlying rejection behavior.
* **Base64-encoded `jwt_source` is mandatory.** Plain URLs fail on
  the second request with `illegal base64 data at input byte 4`.
  See § _Why is `jwt_source` base64-encoded?_ above.
* **Redis is mandatory**. Tyk OSS refuses to serve traffic until its
  Redis pool is healthy — this scenario therefore cannot run in a
  two-container shape. A future minimal-topology profile that
  sidesteps JWT + rate-limit + session storage entirely might be
  able to skip Redis, but that is out of scope here.
* **JWKS cache TTL = 240 s**. Classic APIs do not expose a way to
  override the default cache for `jwt_source`; rotating the
  reference JWKS in-place and expecting Tyk to pick up the change
  within seconds will not work. Restart the `gateway` container
  after a `_reference/jwks-rs256` rotation, or wait ≥ 240 s.
* **`jwt_default_policies` is mandatory**. Without it, every
  correctly signed token is rejected with `no session found for
  token user identity`. The default policy here (`bench-default-
  policy`) is the minimum viable shape: no rate limit, no quota,
  ACL only.
