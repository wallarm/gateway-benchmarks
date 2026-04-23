-- gateways/apisix/_shared/lualib/jwt_hs256.lua
--
-- Port of gateways/nginx/_shared/lualib/jwt_hs256.lua for the APISIX
-- column. Same shape, same external contract, same constant-time
-- equality. Loaded by the per-profile `serverless-pre-function`
-- snippets (p02-jwt, p12-full-pipeline) that run in the `access`
-- phase and short-circuit with `ngx.exit(401)` on any rejection.
--
-- Pure Lua — uses only primitives that ship inside the
-- `apache/apisix:3.15.0-debian` image:
--
--   * `resty.sha256`  (bundled `lua-resty-core`)
--   * `cjson.safe`    (bundled `lua-cjson`)
--   * `bit`           (LuaJIT built-in)
--   * `ngx.*`         (encode_base64 / decode_base64 / time)
--
-- We deliberately do NOT depend on `lua-resty-jwt` or
-- `lua-resty-hmac`, which aren't bundled with APISIX and would require
-- a custom image build. The HS256 implementation here is ~60 lines of
-- real code, fully visible to anyone reading the config, and benchmark
-- performance is dominated by APISIX request dispatch + backend
-- roundtrip, not by HMAC-SHA-256 throughput.
--
-- What this module verifies on each call:
--
--   * the Authorization header starts with "Bearer " (RFC 6750)
--   * the JWT has three base64url-encoded segments separated by "."
--   * the header decodes to {"alg":"HS256","typ":"JWT"} (typ=JWT
--     omitted is also accepted; strict alg match is required)
--   * the signature matches HMAC-SHA-256 of (header_b64 "." payload_b64)
--     using the configured shared secret, in constant time
--   * the payload's `exp` claim is >= current epoch second
--
-- What this module explicitly does NOT do:
--
--   * `iss` / `aud` / `sub` / `nbf` / `iat` validation — out of
--     scope for the p02 fixture (see fixtures/p02-jwt.jsonl).
--   * RS256 / ES256 / EdDSA — the canonical bench is HS256-only.
--     (RS256 + JWKS lives in the `p03-jwks-rs256-basic`
--     scenario and is served by the native openid-connect plugin.)
--   * JWKS fetching — the secret is a static shared string (see
--     docs/POLICIES.md § p02).
--
-- The native `jwt-auth` plugin was NOT used for p02: APISIX's
-- jwt-auth looks up a Consumer by a `key` claim in the JWT payload,
-- and the canonical bench JWT carries only {sub, role, iss, exp}
-- (no `key` claim). Rather than reshape the canonical payload just
-- for APISIX, we verify the signature inline in serverless-pre-
-- function. Same trade-off as `gateways/nginx/p02-jwt` made
-- (mainline nginx has no JWT directive; OpenResty + pure-Lua HS256
-- is the natural answer).

local _M = {}

local cjson_safe = require("cjson.safe")
local sha256_mod = require("resty.sha256")
local bit = require("bit")
local str_byte = string.byte
local str_char = string.char
local tbl_concat = table.concat
local bxor = bit.bxor

local HMAC_BLOCK = 64

-- -----------------------------------------------------------------------------
-- base64url encode/decode helpers (RFC 7515 §2).
-- -----------------------------------------------------------------------------
local function b64url_decode(s)
    if not s or s == "" then return nil end
    s = s:gsub("-", "+"):gsub("_", "/")
    local pad = (4 - (#s % 4)) % 4
    if pad > 0 then s = s .. string.rep("=", pad) end
    return ngx.decode_base64(s)
end

-- -----------------------------------------------------------------------------
-- HMAC-SHA-256 via the bundled resty.sha256 primitive. Classic RFC 2104.
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
-- -----------------------------------------------------------------------------
function _M.verify(authz, secret)
    if not authz or authz == "" then
        return false, "missing Authorization header"
    end

    local token = authz:match("^[Bb][Ee][Aa][Rr][Ee][Rr]%s+(.+)$")
    if not token then
        return false, "not a Bearer scheme"
    end

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

    local signing_input = h_b64 .. "." .. p_b64
    local expected = hmac_sha256(secret, signing_input)
    if not consttime_eq(sig, expected) then
        return false, "signature mismatch"
    end

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

return _M
