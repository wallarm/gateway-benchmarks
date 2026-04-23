# `nginx / p03-jwks-rs256-basic` — p03-jwks-rs256-basic scenario notes

**Verdict on `openresty/openresty:1.27.1.2-alpine@sha256:761047d6…`**:
`PASS (3/3)`.

## What this scenario is — and is NOT

`p03-jwks-rs256-basic` is a policy profile in the 12-profile matrix that exercises the
**RS256 + JWKS-shaped `kid` lookup** axis. It is deliberately kept
outside the 12-profile matrix:

- The canonical [`p02-jwt`](../p02-jwt/NOTES.md) profile stays
  **HS256** — that is the profile every gateway is compared on.
- This p03-jwks-rs256-basic scenario lives parallel to p02 so nginx's RS256 /
  JWKS capability can be measured **without reshaping p02's question**
  across every other gateway.
- It does not appear in `make parity-gateway-all`. It is invoked
  explicitly:

  ```bash
  make parity-gateway \
      PARITY_GATEWAY=nginx \
      PARITY_PROFILE=p03-jwks-rs256-basic
  ```

The first iteration is deliberately minimal — **one kid, one PEM,
three probes**. A future iteration may add an N-key JWKS rotation
(multiple PEMs mounted under `/etc/nginx/jwks-rs256/keys/*.pem`,
each keyed by its `kid`) and an `unknown-kid-with-forged-signature`
probe.

## Realisation: OpenResty + LuaJIT FFI → libcrypto

Mainline nginx has no Lua and no directive-level JWT primitive. This
profile runs on **OpenResty** (same image every other Lua-dependent
nginx profile pins — see `.env`) and uses two small Lua modules
dropped into `_shared/lualib/`:

| Module                                      | Role                                                          | LoC  |
|---------------------------------------------|---------------------------------------------------------------|------|
| [`jwt_rs256_verify.lua`](../_shared/lualib/jwt_rs256_verify.lua) | FFI wrapper over OpenSSL 3.x `libcrypto` (`EVP_DigestVerify*`). Exposes `load_pubkey_pem(pem) -> EVP_PKEY*` and `verify_rs256(pkey, signing_input, sig) -> ok, err`. | ~140 |
| [`jwt_rs256_jwks.lua`](../_shared/lualib/jwt_rs256_jwks.lua) | JWT layer: parse header, dispatch by `kid` to an in-memory `{kid → EVP_PKEY*}` map, RS256 verify, `exp` check. | ~160 |

The request hot path is:

1. `ngx.var.http_authorization` → strip `Bearer ` prefix,
2. split on `.` into three base64url segments,
3. b64url-decode header, cjson-parse, read `alg` / `kid`,
4. table lookup: `key_by_kid[kid]` (the JWKS axis),
5. b64url-decode signature, call `EVP_DigestVerifyFinal` via FFI,
6. parse payload, check `exp`,
7. pass request through to `proxy_pass http://backend_pool;`.

No per-request PEM parsing, no per-request JWKS parsing — `init_by_lua_block`
slurps the three reference files once per worker and builds the
`kid → EVP_PKEY*` map.

### Why FFI, not pure Lua

Pure-Lua RS256 requires bigint modexp over a 2048-bit modulus
(`c^e mod N` with `e = 65537`, which is 17 squarings + 1 multiplication
of ~64-word bigints). That is ~150 LoC of tight, error-prone LuaJIT
arithmetic we would have to audit ourselves against CVE-grade
side-channel and correctness bugs. Calling directly into
`EVP_DigestVerify*` is three ffi.cdef entries plus a handful of
pointer juggles; the verification goes through battle-tested code in
libcrypto.

### Why this doesn't break the reproducibility story

`libcrypto.so` is already inside the pinned
`openresty/openresty:1.27.1.2-alpine` image at
`/usr/local/openresty/openssl3/lib/libcrypto.so` (OpenSSL 3.5.5 at
the time of this iteration — the image bundles its own OpenSSL
distinct from Alpine's `/usr/lib/libcrypto.so.3`). We `ffi.load` the
absolute path, which pins us to the exact library OpenResty itself
was linked against — no ABI-mismatch risk, no dependence on the
dynamic-linker search order. This is the same reproducibility
posture that [`jwt_hs256.lua`](../_shared/lualib/jwt_hs256.lua) has
(pure-Lua, bundled modules, nothing from opm).

## JWKS ingestion model

The JWKS is NOT embedded in `nginx.conf`. Instead, the reference
material at
[`gateways/_reference/jwks-rs256/`](../../_reference/jwks-rs256/README.md)
is bind-mounted read-only at `/etc/nginx/jwks-rs256/` via the shared
[`gateways/nginx/docker-compose.yaml`](../docker-compose.yaml):

```yaml
volumes:
  - ../_reference/jwks-rs256:/etc/nginx/jwks-rs256:ro
```

`init_by_lua_block` slurps three files once per worker:

| File                                | Role                                                               |
|-------------------------------------|--------------------------------------------------------------------|
| `/etc/nginx/jwks-rs256/jwks.json`   | Canonical JWKS. Parsed to enumerate valid `kid`s.                  |
| `/etc/nginx/jwks-rs256/public.pem`  | Reference RSA public key, PEM-encoded SPKI. Same key pair as JWKS. |
| `/etc/nginx/jwks-rs256/kid.txt`     | Canonical `kid` string. Used to bind the PEM to its JWKS entry.    |

Why the PEM mount in addition to the JWKS:

- Reading the JWKS *and* computing the PEM from `{n, e}` in Lua
  would require an ASN.1 SPKI encoder: `SEQUENCE { AlgorithmIdentifier
  { OID rsaEncryption, NULL }, BIT STRING { SEQUENCE { INTEGER(n),
  INTEGER(e) } } }`. That is ~100 LoC of byte-plumbing we would
  then have to audit against DER encoding quirks.
- Every other JWKS-aware column in the bench mounts or inlines the
  reference material verbatim
  ([envoy: `local_jwks.inline_string`](../../envoy/p03-jwks-rs256-basic/envoy.yaml);
  [apisix: bind-mount under `oidc-server`](../../apisix/p03-jwks-rs256-basic/NOTES.md);
  [tyk: bind-mount](../../tyk/p03-jwks-rs256-basic/NOTES.md);
  [kong: embedded PEM in declarative config](../../kong/p03-jwks-rs256-basic/kong.yml)).
  Feeding the PEM to libcrypto is semantically equivalent to
  deriving it from the JWK — [`setup.sh`](./setup.sh)'s drift guard
  pins the two references to the same key pair.

Removing the shared mount path would require moving the reference
material into the profile directory, which is the opposite of
"canonical reference assets live under `_reference/`". The mount
is **inert** for the 12 profiles — no other `nginx.conf`
references `/etc/nginx/jwks-rs256/`, so the bind has zero effect on
the matrix.

## Probes

The three probes in
[`../../../fixtures/p03-jwks-rs256-basic.jsonl`](../../../fixtures/p03-jwks-rs256-basic.jsonl):

| # | Probe                                                        | Expected | nginx response body (401 probes)                                 |
|---|--------------------------------------------------------------|----------|------------------------------------------------------------------|
| 1 | No `Authorization` header                                    | `401`    | `{"error":"unauthorized","reason":"jwks_rs256_validation_failed"}` |
| 2 | `Authorization: Bearer <RS256 token, kid=bench-rs256-2026>`  | `200`    | — (proxied from backend)                                         |
| 3 | `Authorization: Bearer <RS256 token, kid=unknown-kid-2026>`  | `401`    | `{"error":"unauthorized","reason":"jwks_rs256_validation_failed"}` |

Probe 3 is the one that makes this scenario meaningful: the token's
signature IS valid against the canonical private key, so a verifier
that just tries every key in the store would accept it. Our module
keys the dispatch strictly on `header.kid` — unknown kid rejects
before any signature work — which matches what every other
JWKS-aware column in this bench does.

## Drift guard (setup.sh)

The drift guard in [`setup.sh`](./setup.sh) runs at every boot:

1. Waits for the data plane (the proxy returns 401 as soon as
   nginx finishes loading — `init_by_lua_block` would have crashed
   the worker if any of the three reference files failed to
   parse, so answering 401 at all is a strong readiness signal).
2. Asserts the canonical `kid` in `_reference/jwks-rs256/kid.txt`
   matches `jwks.json`'s `.keys[0].kid` (prevents a partial
   rotation where kid.txt moves but jwks.json doesn't, or vice
   versa).
3. Asserts `public.pem` carries a `BEGIN PUBLIC KEY` marker (basic
   shape check — a zero-byte or malformed PEM would already have
   crashed `init_by_lua_block`, but belt-and-suspenders).
4. Smokes the three mini-probes that mirror the fixture before the
   parity runner starts.

There is no `FEATURE-MISSING` fallback: the FFI-to-libcrypto path
is guaranteed to work on the pinned image (libcrypto.so is shipped
in the image itself). If it breaks this is a FAIL, not a
FEATURE-MISSING.

## See also

- [`docs/POLICIES.md § p03-jwks-rs256-basic`](../../../docs/POLICIES.md)
  — canonical description of this scenario and why it is separate
  from p02.
- [`gateways/_reference/jwks-rs256/README.md`](../../_reference/jwks-rs256/README.md)
  — reference assets (private/public key, JWKS, canonical kid) and
  regeneration procedure.
- [`scripts/gen-jwt-rs256.sh`](../../../scripts/gen-jwt-rs256.sh)
  — RS256 token generator for `valid` and `unknown-kid`.
- [`../p02-jwt/NOTES.md`](../p02-jwt/NOTES.md) — canonical HS256
  JWT profile on the same OpenResty image.
- [`../../envoy/p03-jwks-rs256-basic/NOTES.md`](../../envoy/p03-jwks-rs256-basic/NOTES.md),
  [`../../kong/p03-jwks-rs256-basic/NOTES.md`](../../kong/p03-jwks-rs256-basic/NOTES.md),
  [`../../apisix/p03-jwks-rs256-basic/NOTES.md`](../../apisix/p03-jwks-rs256-basic/NOTES.md),
  [`../../tyk/p03-jwks-rs256-basic/NOTES.md`](../../tyk/p03-jwks-rs256-basic/NOTES.md),
  [`../../wallarm/p03-jwks-rs256-basic/NOTES.md`](../../wallarm/p03-jwks-rs256-basic/NOTES.md)
  — sibling scenarios on other gateway columns.
