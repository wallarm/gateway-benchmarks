-- gateways/nginx/_shared/lualib/jwt_hs256.lua
--
-- Minimal HS256 JWT verifier for the gateway-benchmarks nginx cell.
-- Pure Lua — uses only primitives that ship in the stock
-- openresty/openresty:1.27.1.2-alpine image:
--
--   * `resty.sha256`  (bundled `lua-resty-core`)
--   * `cjson.safe`    (bundled `lua-cjson`)
--   * `bit`           (LuaJIT built-in)
--   * `ngx.*`         (encode_base64 / decode_base64 / time)
--
-- We deliberately do NOT depend on `lua-resty-jwt` or
-- `lua-resty-hmac`, which are not bundled with stock OpenResty and
-- would require a custom Dockerfile / out-of-band install step. The
-- HS256 implementation here is small (~60 lines of real code), is
-- fully visible to anyone reading the config, and is good enough for
-- benchmark purposes — performance is dominated by nginx request
-- dispatch and backend roundtrip, not by HMAC-SHA-256 throughput.
--
-- What this module verifies on each call:
--
--   * the Authorization header starts with "Bearer " (RFC 6750)
--   * the JWT has three base64url-encoded segments separated by "."
--   * the header decodes to {"alg":"HS256","typ":"JWT"} (or typ="JWT"
--     omitted is also accepted; strict alg match is required)
--   * the signature matches HMAC-SHA-256 of (header_b64 "." payload_b64)
--     using the configured shared secret, in constant time
--   * the payload's `exp` claim is >= current epoch second (when exp
--     is present; the canonical fixture always mints it)
--
-- What this module explicitly does NOT do:
--
--   * `iss` / `aud` / `sub` / `nbf` / `iat` validation — out of
--     scope for the p02 fixture (see fixtures/p02-jwt.jsonl).
--   * RS256 / ES256 / EdDSA — the canonical bench is HS256-only.
--   * JWKS fetching — the secret is a static shared string (see
--     docs/POLICIES.md § p02).
--
-- The same module is reused by gateways/nginx/p12-full-pipeline.

local _M = {}

local cjson_safe = require("cjson.safe")
local sha256_mod = require("resty.sha256")
local bit = require("bit")
local str_byte = string.byte
local str_char = string.char
local str_sub  = string.sub
local tbl_concat = table.concat
local bxor = bit.bxor

-- HMAC-SHA-256 block size and digest size (RFC 4868).
local HMAC_BLOCK = 64

-- -----------------------------------------------------------------------------
-- base64url encode/decode helpers.
--
-- `ngx.encode_base64` / `ngx.decode_base64` speak RFC 4648 §4
-- (standard base64, with padding). JWTs use base64url (§5) without
-- padding. The transform is purely character-level: `-` ↔ `+`,
-- `_` ↔ `/`, strip/restore trailing `=`.
-- -----------------------------------------------------------------------------

local function b64url_decode(s)
    if not s or s == "" then return nil end
    -- standard → url-compat restore
    s = s:gsub("-", "+"):gsub("_", "/")
    local pad = (4 - (#s % 4)) % 4
    if pad > 0 then s = s .. string.rep("=", pad) end
    return ngx.decode_base64(s)
end

local function b64url_encode(raw)
    if not raw then return "" end
    local s = ngx.encode_base64(raw)
    -- strip padding, url-compat chars
    s = s:gsub("=+$", ""):gsub("+", "-"):gsub("/", "_")
    return s
end

-- -----------------------------------------------------------------------------
-- HMAC-SHA-256 via the bundled `resty.sha256` primitive.
--
-- Classic RFC 2104 construction:
--   K' = sha256(K) if len(K) > B
--        K           otherwise
--   K' is then zero-padded on the right to B bytes.
--   ipad = K' XOR (0x36 repeated B times)
--   opad = K' XOR (0x5c repeated B times)
--   HMAC(K, m) = sha256(opad || sha256(ipad || m))
-- -----------------------------------------------------------------------------

local function sha256_raw(msg)
    local h = sha256_mod:new()
    h:update(msg)
    return h:final()
end

local function pad_key(key, pad_byte)
    local out = {}
    local n = #key
    for i = 1, HMAC_BLOCK do
        local kb = (i <= n) and str_byte(key, i) or 0
        out[i] = str_char(bxor(kb, pad_byte))
    end
    return tbl_concat(out)
end

local function hmac_sha256(key, msg)
    if #key > HMAC_BLOCK then
        key = sha256_raw(key)
    end
    local inner = sha256_raw(pad_key(key, 0x36) .. msg)
    return sha256_raw(pad_key(key, 0x5c) .. inner)
end

-- -----------------------------------------------------------------------------
-- Constant-time byte-string equality.
--
-- A naive `a == b` leaks timing through Lua's string interning
-- short-circuit — not exploitable in this benchmark context, but
-- cheap to avoid and keeps the code production-shaped.
-- -----------------------------------------------------------------------------
local function consttime_eq(a, b)
    if not a or not b or #a ~= #b then return false end
    local diff = 0
    for i = 1, #a do
        diff = bit.bor(diff, bxor(str_byte(a, i), str_byte(b, i)))
    end
    return diff == 0
end

-- -----------------------------------------------------------------------------
-- Public entry point.
--
-- _M.verify(authz_header, secret) -> ok, err
--
-- Returns (true, nil) on a good token, (false, "reason") otherwise.
-- Caller is expected to translate a false return into 401. See
-- `access_by_lua_block` in gateways/nginx/p02-jwt/nginx.conf.
-- -----------------------------------------------------------------------------

function _M.verify(authz, secret)
    if not authz or authz == "" then
        return false, "missing Authorization header"
    end

    -- "Bearer <token>" — the scheme check is case-insensitive per RFC 7235.
    local token = authz:match("^[Bb][Ee][Aa][Rr][Ee][Rr]%s+(.+)$")
    if not token then
        return false, "not a Bearer scheme"
    end

    -- Three segments separated by '.': header.payload.signature
    local h_b64, p_b64, s_b64 = token:match("^([^.]+)%.([^.]+)%.([^.]+)$")
    if not h_b64 then
        return false, "malformed JWT (expected 3 segments)"
    end

    local header_json = b64url_decode(h_b64)
    if not header_json then return false, "base64url decode failed (header)" end
    local header = cjson_safe.decode(header_json)
    if type(header) ~= "table" or header.alg ~= "HS256" then
        return false, "unexpected alg (only HS256 accepted)"
    end

    local payload_json = b64url_decode(p_b64)
    if not payload_json then return false, "base64url decode failed (payload)" end
    local payload = cjson_safe.decode(payload_json)
    if type(payload) ~= "table" then return false, "payload not an object" end

    local sig = b64url_decode(s_b64)
    if not sig then return false, "base64url decode failed (signature)" end

    -- Recompute HMAC over the signing input.
    local signing_input = h_b64 .. "." .. p_b64
    local expected = hmac_sha256(secret, signing_input)
    if not consttime_eq(sig, expected) then
        return false, "signature mismatch"
    end

    -- exp is REQUIRED by docs/POLICIES.md § p02 and by gen-jwt.sh;
    -- rejecting tokens without exp closes a whole class of replay
    -- attacks and matches the canonical fixture (p02 probe 5).
    local now = ngx.time()
    if type(payload.exp) == "number" then
        if now >= payload.exp then
            return false, "token expired"
        end
    else
        return false, "no exp claim"
    end

    return true, nil
end

-- Exposed for tests / debugging.
_M._hmac_sha256 = hmac_sha256
_M._b64url_decode = b64url_decode
_M._b64url_encode = b64url_encode

return _M
