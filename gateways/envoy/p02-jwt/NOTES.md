# envoy / p02-jwt

HS256 JWT validation with the canonical shared secret
(`bench-jwt-hs256-secret-2026` — public, benchmark-only).
Implemented via `envoy.filters.http.lua` + a pure-Lua verifier,
because envoy's native `envoy.filters.http.jwt_authn` does NOT
support symmetric algorithms.

## Canonical contract

* `docs/POLICIES.md § p02` — HS256 JWT validation.
* `fixtures/p02-jwt.jsonl`:

  | Probe | Expect |
  | --- | --- |
  | `GET /anything` no Authorization | 401 |
  | `GET /anything` Authorization: `Bearer not.a.jwt` | 401 |
  | `GET /anything` Authorization: `Basic Zm9vOmJhcg==` | 401 |
  | `GET /anything` Authorization: `Bearer <valid>` | 200 |
  | `GET /anything` Authorization: `Bearer <expired>` | 401 |
  | `GET /anything` Authorization: `Bearer <wrong-secret>` | 401 |

Verdict: **PASS (6/6)**.

## Envoy primitive

`envoy.filters.http.lua` runs in the request-phase filter chain,
BEFORE the router. A verifier call that returns `false` triggers
`request_handle:respond(...)`, which short-circuits the filter
chain and returns the 401 envelope directly — the upstream is
never contacted.

```
envoy.filters.http.lua       (envoy_on_request: verify; respond 401 on fail)
envoy.filters.http.router    (only reached when the JWT is valid)
```

### Why not native `jwt_authn`

Envoy's native JWT filter supports only asymmetric algorithms
(RS256/384/512, PS256/384/512, ES256/384/512, EdDSA) — by design.
The `kty: oct` JWK form, which is the JWK representation of a
symmetric HS256 secret, is rejected at parse time. The upstream
rationale (see envoyproxy/envoy#16081 and #18214) is that JWKS
distribution of symmetric secrets is a security anti-pattern in
production.

The benchmark's canonical JWT cell is HS256 (shared secret in
`gateways/_reference/jwt/secret.txt`), so native `jwt_authn` is
not an option. The `p03-jwks-rs256-basic` scenario covers
the RS256/JWKS axis separately via native `jwt_authn`, so the
envoy column tests both authentication paths — just with
different primitives.

### Shared Lua verifier

The Lua filter requires our `_shared/lualib` modules at runtime:

* `base64.lua`       — RFC 4648 §4 / §5 codec (header/payload/sig
                        are each base64url-encoded segments)
* `sha256.lua`       — FIPS 180-4 SHA-256 + RFC 2104 HMAC
* `json.lua`         — minimal pure-Lua JSON decoder (for the
                        header's `alg` and the payload's `exp`)
* `jwt_hs256.lua`    — top-level entry point (`verify(authz, secret)`)

Total ~500 lines of pure Lua. Every file has an RFC/FIPS citation
in its header comment so the reviewer can map the implementation
back to the spec line-by-line. No external dependencies — every
primitive is either LuaJIT's built-in `bit` module or `os.time()`.

Why write it instead of vendoring lua-resty-jwt? Because OpenResty
bundles `lua-resty-jwt` and its transitive deps (`lua-resty-hmac`,
`lua-resty-rsa`, `lua-resty-evp`) but Envoy does NOT. Installing
them would require a custom Dockerfile, which breaks the "public
pinned image, no build step" reproducibility contract every other
envoy profile honours. Pure Lua is a one-time cost we now share
across p02-jwt and p12-full-pipeline.

### Constant-time signature comparison

`jwt_hs256.consttime_eq(a, b)` XORs every byte pair into an
accumulator and returns `accum == 0`. The classic naive
`a == b` short-circuits at the first mismatch, leaking a timing
oracle; the constant-time form eliminates it. Not exploitable in
this benchmark context (p02 does not exercise a side-channel)
but trivial to include and matches what a production verifier
would do. Same pattern as nginx's column.

### 401 envelope shape

On a rejection the Lua filter calls:

```lua
req:respond({
    [":status"] = "401",
    ["content-type"] = "application/json",
    ["www-authenticate"] =
        'Bearer realm="bench", charset="UTF-8"',
}, '{"error":"unauthorized","reason":"jwt_validation_failed"}')
```

This matches nginx/p02-jwt's `error_page 401 = @unauthorized`
body byte-for-byte (diffable surface across columns). The
`www-authenticate` header is RFC 6750 §3 compliant; no fixture
probe asserts it but a production-shaped response emits it.

## Parity delta vs sibling columns

| Cell | Primitive |
| --- | --- |
| `nginx/p02-jwt` | `access_by_lua_block` + `jwt_hs256.lua` using OpenResty's bundled `resty.sha256` + `cjson.safe` (~60 lines of custom code, the rest from OpenResty) |
| `envoy/p02-jwt` | `envoy.filters.http.lua` + pure-Lua `base64` + `sha256` + `json` + `jwt_hs256` (~500 lines total, no external deps beyond LuaJIT) |
| `wallarm/p02-jwt` | native `jwt_validation` policy against a from-source build; see [`gateways/wallarm/p02-jwt/NOTES.md`](../../wallarm/p02-jwt/NOTES.md) |

All three cells converge on the same fixture verdict (PASS 6/6
for nginx and envoy; FEATURE-MISSING documented for wallarm).
The envoy cell is bigger on-disk because it ships its own crypto
primitives; the performance story is unchanged — benchmark
throughput is dominated by envoy request dispatch + backend
roundtrip, not by HMAC-SHA-256 on a ~220-byte JWT.

## Deviations

None.

## Files

* `envoy.yaml` — p01-vanilla base + Lua filter (inline source
  calls `jwt_hs256.verify` and `respond()` on fail).
* `setup.sh` — waits for data plane, proves 401 on no-auth +
  200 on a freshly minted HS256 token via `scripts/gen-jwt.sh`.
* `NOTES.md` — this file.
