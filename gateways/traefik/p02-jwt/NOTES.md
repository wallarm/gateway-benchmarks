# gateways/traefik/p02-jwt

**Status:** `PASS 6/6`

## Canonical contract

`docs/POLICIES.md § p02` — HS256 JWT validation, token source
`Authorization: Bearer <jwt>`, secret shared across every gateway
under `gateways/_reference/jwt/secret.txt`.

## Mechanism

Local Yaegi plugin `jwt_hs256` declared under
[`_shared/plugins-local/src/github.com/wallarm/jwt_hs256/`](../_shared/plugins-local/src/github.com/wallarm/jwt_hs256/).
The plugin is ~250 LoC of stdlib-only Go (`crypto/hmac`,
`crypto/sha256`, `encoding/base64`, `encoding/json`, `time`,
`net/http`, `strings`, `context`) — every package on Yaegi's
allowlist.

Validation pipeline:

1. Read `Authorization` (configurable header). Missing → 401.
2. Split on first space. Require scheme prefix (default `Bearer`,
   case-insensitive per RFC 6750 § 2.1). Non-matching scheme → 401.
3. Strip whitespace from the token. Empty token → 401.
4. Split token on `.` — must be exactly three segments.
5. base64url-decode the header segment, JSON-parse, require
   `alg=HS256`. Refusing `alg=none` closes the well-known JWT
   bypass path that has been the root of every JWT CVE since 2015.
6. Recompute HMAC-SHA-256 over `<headerSeg>.<payloadSeg>` with
   the configured secret. Compare in constant time
   (`hmac.Equal`). Mismatch → 401.
7. base64url-decode the payload, JSON-parse into
   `map[string]json.RawMessage`. For each of `exp` / `nbf` that
   the payload carries, re-decode as `int64` and check
   against `time.Now().Unix()` with optional leeway.

The plugin sends 401 (configurable) with empty body and
`WWW-Authenticate: <scheme>` per RFC 6750 § 3 — the fixture
asserts on status code only, so we deliberately ship no error
body.

## Why we ship a custom plugin

Every public Traefik JWT plugin we vetted (the
`traefik-plugin-jwt-validate`,
`traefik-plugin-jwt`, …, families on plugins.traefik.io)
either:

- Bundled extra knobs the canonical p02 fixture does not exercise
  (audience, issuer, RS256 fallback) — extra config branches we
  would have to test even though the fixture asks none of them.
- Carried unknown maintenance posture (last commit > 12 months
  old) we couldn't sign off on for the benchmark.
- Or pulled in cryptographic helpers outside Yaegi's stdlib
  whitelist (`crypto/rsa`, `golang.org/x/crypto/...`).

Shipping ~250 lines of stdlib-only Go inside the repo is cheaper
to audit than vendoring any of those dependencies, and it stays
HS256-only on purpose so it maps 1:1 onto the canonical p02
contract. The plugin shape mirrors the lua counterparts in
`gateways/nginx/_shared/lualib/jwt_hs256.lua` and
`gateways/envoy/_shared/lualib/jwt_hs256.lua` — same secret
path, same alg gate, same exp/nbf semantics. A reviewer can read
any one column's implementation and trust the fixture semantics
across the whole matrix.

## Implementation note: Yaegi quirk on custom UnmarshalJSON

The first cut of the plugin used a `flexInt` helper struct with a
custom `UnmarshalJSON` method to accept either `"exp": 1234567` or
`"exp": "1234567"`. Native Go: works. Yaegi: silently fails with
`"json: cannot unmarshal number into Go struct field .exp of type
struct { Xvalue int64; Xset bool }"` — the interpreter's
reflect-driven JSON decoder skips method dispatch on
user-declared types, so the custom UnmarshalJSON never fires and
the fallback decoder bombs.

Workaround in `jwt_hs256.go`: decode the payload into
`map[string]json.RawMessage`, then re-decode each claim
individually as `int64`. Sticks to plain stdlib types Yaegi
hands back byte-for-byte — no method dispatch needed. Documented
in `docs/GATEWAYS.md § Deviations § yaegi-json-no-method-dispatch`.

## Cold-start

Traefik compiles every Yaegi plugin declared under
`experimental.localPlugins` at process start, even profiles that
don't reference them in their dynamic config. This profile mounts
both `body_rewrite` and `jwt_hs256` (uniform across p01..p12), so
expect ~3-5 s before the first 401 lands. `setup.sh` polls
`/anything` (no Authorization) until it observes 401 — the signal
that the JWT middleware is the first link in the chain.

## Probe-by-probe

| # | Probe                                          | Expected | Observed | Status |
|---|------------------------------------------------|----------|----------|--------|
| 1 | no Authorization header                        | 401      | 401      | PASS   |
| 2 | garbage bearer (`Bearer not.a.jwt`)            | 401      | 401      | PASS   |
| 3 | malformed scheme (`Basic Zm9vOmJhcg==`)        | 401      | 401      | PASS   |
| 4 | valid HS256 token                              | 200      | 200      | PASS   |
| 5 | expired HS256 token (signed right, exp < now)  | 401      | 401      | PASS   |
| 6 | wrong-secret HS256 token (signed with tamper)  | 401      | 401      | PASS   |

`PASS 6/6`. Reproduce with:

```bash
make parity-gateway PARITY_GATEWAY=traefik PARITY_PROFILE=p02-jwt
```
