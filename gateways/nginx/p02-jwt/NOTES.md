# `nginx / p02-jwt` — notes

Canonical spec — [`docs/POLICIES.md § p02`](../../../docs/POLICIES.md).

```
algorithm: HS256
secret:    bench-jwt-hs256-secret-2026
claims:    sub=bench, role=tester, iss=gateway-benchmarks, exp=now+3600
reject 401 on: missing Authorization, non-Bearer scheme, malformed JWT,
               expired exp, wrong-secret signature
```

## Image

**OpenResty** — [`openresty/openresty:1.27.1.2-alpine`](../p09-resp-headers/NOTES.md)
(same pin as p08). Pinned by digest via
[`./.env`](./.env) and plugged into the shared
[`docker-compose.yaml`](../docker-compose.yaml) through the
`${GATEWAY_IMAGE:-<mainline>}` override.

Mainline `nginx` would also satisfy p01/p03/p05/p06/p07 on its own,
but has no Lua and no JWT directive. OpenResty is the bench-wide
choice for any profile that needs Lua, so we reuse the same pin.

## What we ship

A ~60-line pure-Lua HS256 verifier — see
[`gateways/nginx/_shared/lualib/jwt_hs256.lua`](../_shared/lualib/jwt_hs256.lua).
The module uses only primitives that ship in stock OpenResty:

- `resty.sha256` — 32-byte SHA-256 digest (bundled with
  `lua-resty-core`).
- `cjson.safe`   — non-throwing JSON decode (bundled with
  `lua-cjson`).
- `bit.bxor`     — byte-level XOR (LuaJIT builtin).
- `ngx.encode_base64` / `ngx.decode_base64` / `ngx.time`.

HMAC-SHA-256 is built by hand from `resty.sha256` via the classic
RFC 2104 construction:

```
K' = sha256(K) if |K| > 64 else K
ipad = K' ⊕ (0x36 × 64)
opad = K' ⊕ (0x5c × 64)
HMAC(K, m) = sha256(opad || sha256(ipad || m))
```

Plus a constant-time byte compare for the signature check and an
`exp >= now` window check. That is the whole JWT verification
surface exercised by
[`fixtures/p02-jwt.jsonl`](../../../fixtures/p02-jwt.jsonl).

## Why not `lua-resty-jwt`?

The obvious off-the-shelf library is
[`SkyLothar/lua-resty-jwt`](https://github.com/SkyLothar/lua-resty-jwt).
We chose not to use it because:

1. It is not bundled with stock OpenResty. Including it would
   require either a custom `Dockerfile` (breaks the image-digest
   pin story) or an `opm` install step at build time (breaks
   reproducibility across hosts).
2. The extra surface area of `lua-resty-jwt` — JWK, JWE, x5c chain
   validation, nested signing — is not exercised by the canonical
   fixture. The benchmark's p02 profile is deliberately scoped to
   the primitive HS256 path; anything beyond HS256 lives in a
   separate, future profile.
3. A hand-rolled 60-line verifier is fully visible to anyone
   reading the repo. The alternative pulls in ~1500 lines from a
   third-party project whose test coverage varies.

The same tradeoff is documented in
[`gateways/wallarm/p02-jwt/NOTES.md`](../../wallarm/p02-jwt/NOTES.md) —
wallarm implements p02 natively through its `jwt_validation`
policy, but the benchmark requires a from-source `WALLARM_IMAGE`
for that to be present. nginx makes p02 a first-class PASS on an
off-the-shelf public OpenResty image without any admin-API binding.

## Deviation — `user nobody;`

OpenResty's alpine image does not provision a `nginx` user; only
`nobody` is available. So the directive is `user nobody;` rather
than `user nginx;` from the mainline-pin profiles (p01/p03/p05/
p06/p07). This is a cosmetic deviation (same privilege class in
practice) and is called out for parity with
[`gateways/nginx/p09-resp-headers/NOTES.md`](../p09-resp-headers/NOTES.md).

## Parity result

```
==> parity: gateway=nginx profile=p02-jwt target=http://localhost:9080
    fixture: fixtures/p02-jwt.jsonl
  ✓ PASS   no Authorization header -> 401
  ✓ PASS   garbage bearer token -> 401
  ✓ PASS   malformed Authorization scheme -> 401
  ✓ PASS   valid HS256 token -> 200
  ✓ PASS   expired HS256 token -> 401
  ✓ PASS   wrong-secret HS256 token -> 401
verdict: PASS  (6/6)
```
