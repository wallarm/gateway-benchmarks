-- gateways/nginx/_shared/lualib/jwt_rs256_jwks.lua
--
-- High-level JWT verifier for the `p03-jwks-rs256-basic`
-- scenario. Sits on top of `jwt_rs256_verify.lua` (FFI to libcrypto)
-- and adds the JWT-layer semantics:
--
--   * Authorization: Bearer <token> parsing
--   * JWT header / payload base64url decode
--   * kid → EVP_PKEY* dispatch (this is the JWKS axis)
--   * RS256 signature verify via FFI
--   * `exp` claim freshness check
--
-- JWKS ingestion model (v1 of this scenario)
-- ------------------------------------------
-- The module takes:
--
--   * `jwks_str`  — the raw JWKS JSON, exactly as committed at
--                   `gateways/_reference/jwks-rs256/jwks.json`. We
--                   parse it to enumerate `kid`s.
--   * `pem_map`   — Lua table { [kid] = pem_string, ... } whose
--                   PEMs have already been materialised on disk
--                   beside the JWKS (same directory, same key
--                   pair). The caller reads each file from the
--                   bind-mounted reference directory in
--                   `init_by_lua_block` before calling `init`.
--
-- Why not derive PEM from the JWK in Lua:
--
--   * JWK `{kty:RSA, n, e}` → PEM would require an ASN.1 SPKI
--     encoder (SEQUENCE { AlgorithmIdentifier { OID rsaEncryption,
--     NULL }, BIT STRING { SEQUENCE { INTEGER(n), INTEGER(e) } } }).
--     That is ~100 LoC of byte-plumbing we would then have to audit.
--   * Every other JWKS-aware column in this bench mounts or inlines
--     the reference material verbatim (envoy: inline_string; apisix:
--     bind-mount under oidc-server; tyk: bind-mount). The setup.sh
--     drift guard proves the two reference files (jwks.json and
--     public.pem) describe the same key pair, so feeding the PEM to
--     libcrypto is semantically identical to deriving it from the
--     JWK. Doing less work here keeps the module focused on the
--     request hot path.
--
-- The result is a map `kid -> EVP_PKEY*` built once at worker start
-- in `init_by_lua_block`. No per-request parsing of the JWKS, no
-- per-request PEM parsing — each request does one b64url decode
-- pair, one table lookup, one `EVP_DigestVerifyFinal`.

local _M = {}

local cjson_safe = require("cjson.safe")
local rsa        = require("jwt_rs256_verify")

-- -----------------------------------------------------------------------------
-- base64url decode helper — mirrors the one in `jwt_hs256.lua` so the
-- two modules share conventions.
--
-- JWTs use RFC 4648 §5 base64url without padding. `ngx.decode_base64`
-- speaks RFC 4648 §4 (standard base64, with padding). The transform is
-- purely character-level.
-- -----------------------------------------------------------------------------
local function b64url_decode(s)
    if not s or s == "" then return nil end
    s = s:gsub("-", "+"):gsub("_", "/")
    local pad = (4 - (#s % 4)) % 4
    if pad > 0 then s = s .. string.rep("=", pad) end
    return ngx.decode_base64(s)
end

-- -----------------------------------------------------------------------------
-- _M.init(jwks_str, pem_map) -> _M
--
-- Builds the kid → EVP_PKEY* map. Call once in `init_by_lua_block`.
-- Errors are fatal (via Lua `error()`) — a misconfigured JWKS is a
-- boot-time problem, not a request-time problem.
--
-- Contract on `pem_map`:
--   every `kid` listed in `jwks_str`'s `.keys[]` with `kty=RSA` and
--   `alg=RS256` MUST have a corresponding PEM entry. A missing entry
--   is fatal. Extra PEMs beyond what the JWKS declares are allowed
--   (this lets a future JWKS rotation stage new PEMs without
--   re-deploying code).
-- -----------------------------------------------------------------------------
function _M.init(jwks_str, pem_map)
    if type(jwks_str) ~= "string" or jwks_str == "" then
        error("jwt_rs256_jwks.init: jwks_str must be a non-empty string")
    end
    if type(pem_map) ~= "table" then
        error("jwt_rs256_jwks.init: pem_map must be a table { [kid] = pem }")
    end

    local jwks = cjson_safe.decode(jwks_str)
    if type(jwks) ~= "table" or type(jwks.keys) ~= "table" then
        error("jwt_rs256_jwks.init: malformed JWKS (expected object with .keys[])")
    end

    local key_by_kid = {}
    local count = 0
    for i, k in ipairs(jwks.keys) do
        if type(k) ~= "table" then
            error("jwt_rs256_jwks.init: jwks.keys[" .. i .. "] is not an object")
        end
        if type(k.kid) ~= "string" or k.kid == "" then
            error("jwt_rs256_jwks.init: jwks.keys[" .. i .. "] has no .kid")
        end

        -- Only RS256 is in scope for this scenario. Non-RS256 JWKS
        -- entries (e.g., an HS256 oct key mingled in) are silently
        -- ignored so the module can share a JWKS with a mixed-alg
        -- corpus in a future scenario. Current canonical JWKS has
        -- exactly one RSA key; nothing silent happens.
        if k.kty == "RSA" and k.alg == "RS256" then
            local pem = pem_map[k.kid]
            if type(pem) ~= "string" or pem == "" then
                error("jwt_rs256_jwks.init: no PEM provided for kid='" ..
                      k.kid .. "' (jwks.keys[" .. i .. "])")
            end
            local pkey, err = rsa.load_pubkey_pem(pem)
            if not pkey then
                error("jwt_rs256_jwks.init: failed to load PEM for kid='" ..
                      k.kid .. "': " .. tostring(err))
            end
            key_by_kid[k.kid] = pkey
            count = count + 1
        end
    end

    if count == 0 then
        error("jwt_rs256_jwks.init: JWKS carries no usable RS256 RSA keys")
    end

    _M._keys = key_by_kid
    _M._count = count
    return _M
end

-- -----------------------------------------------------------------------------
-- _M.verify(authz) -> ok, err
--
-- Entry point called from `access_by_lua_block`. Returns
-- (true, nil) on a good token, (false, reason) otherwise. `reason`
-- is diagnostic-only — the caller translates any false return into
-- 401 without echoing the reason to the client.
--
-- Rejection axes (each produces a false return with its own reason):
--
--   1. Missing Authorization header
--   2. Not a `Bearer <token>` scheme
--   3. Token not three base64url segments separated by `.`
--   4. Header segment not valid base64url / not JSON / missing alg
--   5. `alg` not RS256 (alg-confusion / alg:none defense)
--   6. `kid` absent from the header
--   7. `kid` not present in the JWKS → "unknown kid"  (this is the
--       axis probe 3 in the fixture exercises)
--   8. Signature fails PKCS#1 v1.5 verify against the kid's public
--       key (tampered token)
--   9. Payload not valid base64url / not JSON
--   10. No `exp` claim, or `exp` <= now (replay defense)
--
-- Conspicuously absent: `iss` / `aud` / `sub` / `nbf` / `iat`
-- validation. The canonical p03-jwks-rs256-basic fixture does not assert
-- them (see fixtures/p03-jwks-rs256-basic.jsonl). Adding them would
-- over-constrain the scenario and drift from what every other
-- column measures.
-- -----------------------------------------------------------------------------
function _M.verify(authz)
    if not _M._keys then
        -- Caller forgot to call _M.init. Loud fail keeps production-
        -- shaped code paths intact.
        return false, "jwks not initialised"
    end

    if not authz or authz == "" then
        return false, "missing Authorization header"
    end

    -- RFC 6750 §2.1: the scheme token is case-insensitive.
    local token = authz:match("^[Bb][Ee][Aa][Rr][Ee][Rr]%s+(.+)$")
    if not token then
        return false, "not a Bearer scheme"
    end

    -- Three segments: header.payload.signature
    local h_b64, p_b64, s_b64 = token:match("^([^.]+)%.([^.]+)%.([^.]+)$")
    if not h_b64 then
        return false, "malformed JWT (expected 3 segments)"
    end

    -- Header --------------------------------------------------------------
    local header_json = b64url_decode(h_b64)
    if not header_json then
        return false, "base64url decode failed (header)"
    end
    local header = cjson_safe.decode(header_json)
    if type(header) ~= "table" then
        return false, "header not an object"
    end
    if header.alg ~= "RS256" then
        return false, "unexpected alg (only RS256 accepted)"
    end
    if type(header.kid) ~= "string" or header.kid == "" then
        return false, "no kid in header"
    end

    -- kid → pubkey dispatch (the JWKS axis) -------------------------------
    local pkey = _M._keys[header.kid]
    if not pkey then
        return false, "unknown kid"
    end

    -- Payload -------------------------------------------------------------
    local payload_json = b64url_decode(p_b64)
    if not payload_json then
        return false, "base64url decode failed (payload)"
    end
    local payload = cjson_safe.decode(payload_json)
    if type(payload) ~= "table" then
        return false, "payload not an object"
    end

    -- Signature -----------------------------------------------------------
    local sig = b64url_decode(s_b64)
    if not sig then
        return false, "base64url decode failed (signature)"
    end

    local signing_input = h_b64 .. "." .. p_b64
    local ok, err = rsa.verify_rs256(pkey, signing_input, sig)
    if not ok then
        return false, err or "signature mismatch"
    end

    -- exp claim (replay defense) — REQUIRED by the canonical payload
    -- template (gateways/_reference/jwt/payload-template.json is
    -- augmented with {iat, exp} by gen-jwt-rs256.sh on every mint).
    local now = ngx.time()
    if type(payload.exp) ~= "number" then
        return false, "no exp claim"
    end
    if now >= payload.exp then
        return false, "token expired"
    end

    return true, nil
end

-- Exposed for tests / debugging. Nothing in the request hot path
-- should touch these.
_M._b64url_decode = b64url_decode

return _M
