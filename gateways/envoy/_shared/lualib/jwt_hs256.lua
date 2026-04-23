-- gateways/envoy/_shared/lualib/jwt_hs256.lua
--
-- Minimal HS256 JWT verifier for Envoy's Lua filter sandbox.
--
-- API contract (kept identical to the nginx column's
-- `gateways/nginx/_shared/lualib/jwt_hs256.lua`):
--
--     local jwt = require("jwt_hs256")
--     local ok, err = jwt.verify(authz_header_value, shared_secret)
--     if not ok then /* reject request 401 */ end
--
-- What this module verifies on each call:
--   * the Authorization header starts with "Bearer " (case-insensitive
--     per RFC 7235 §2.1)
--   * the JWT has three base64url-encoded segments separated by "."
--   * the header decodes to `{"alg":"HS256", ...}` — strict alg match,
--     rejecting `none` and any non-HS256 value as a defence against
--     the classic alg-confusion attack
--   * the signature matches HMAC-SHA-256 of
--     `base64url(header) || "." || base64url(payload)` computed with
--     the shared secret, compared in constant time
--   * the payload's `exp` claim is strictly greater than `os.time()`
--     (we REQUIRE `exp` to be present — the canonical generator always
--     mints it, and a missing `exp` is a replay vector)
--
-- What this module deliberately does NOT check:
--   * `iss` / `aud` / `sub` / `nbf` / `iat` — out of scope for the
--     p02 fixture (see `fixtures/p02-jwt.jsonl`)
--   * RS256 / ES256 / EdDSA — canonical benchmark is HS256-only;
--     RSA is the `p03-jwks-rs256-basic` scenario and ships
--     via envoy's native `jwt_authn` filter
--   * JWKS fetching / rotation — the secret is a static shared
--     string, documented in `docs/POLICIES.md § p02`
--
-- The library is 100 % pure Lua, assumes only `os.time()` + LuaJIT's
-- `bit` module (both always available in Envoy's Lua sandbox), and
-- composes the other `_shared/lualib/*.lua` modules for its
-- primitives. No external dependencies.

local _M = {}

local base64 = require("base64")
local sha256 = require("sha256")
local json   = require("json")
local bit    = require("bit")

local band          = bit.band
local bxor          = bit.bxor
local bor           = bit.bor
local string_byte   = string.byte
local string_sub    = string.sub
local os_time       = os.time

-- -----------------------------------------------------------------------------
-- Constant-time byte-string equality.
-- -----------------------------------------------------------------------------
local function consttime_eq(a, b)
    if not a or not b or #a ~= #b then return false end
    local diff = 0
    for i = 1, #a do
        diff = bor(diff, bxor(string_byte(a, i), string_byte(b, i)))
    end
    return diff == 0
end

-- -----------------------------------------------------------------------------
-- Public entry point.
--
-- Returns (true, nil) on a good token, (false, "reason") otherwise.
-- The caller (envoy Lua filter) is expected to call
-- `request_handle:respond({ [":status"] = "401" }, "")` on a false
-- return. We do NOT short-circuit here because _M.verify has no
-- access to the handle.
-- -----------------------------------------------------------------------------
function _M.verify(authz, secret)
    if not authz or authz == "" then
        return false, "missing Authorization header"
    end

    -- "Bearer <token>" — case-insensitive scheme per RFC 7235 §2.1.
    local token = authz:match("^[Bb][Ee][Aa][Rr][Ee][Rr]%s+(.+)$")
    if not token then
        return false, "not a Bearer scheme"
    end

    -- Three segments separated by `.`: `header.payload.signature`.
    local h_b64, p_b64, s_b64 = token:match("^([^.]+)%.([^.]+)%.([^.]+)$")
    if not h_b64 then
        return false, "malformed JWT (expected 3 segments)"
    end

    -- Header.
    local header_json, err = base64.url_decode(h_b64)
    if not header_json then
        return false, "base64url decode failed (header): " .. (err or "?")
    end
    local header
    header, err = json.decode(header_json)
    if not header or type(header) ~= "table" then
        return false, "header JSON decode failed: " .. (err or "not a JSON object")
    end
    if header.alg ~= "HS256" then
        -- Explicit list of rejections covers `none`, `RS256`, `ES256`,
        -- etc. — the alg-confusion defence has no secondary tests.
        return false, "unexpected alg (only HS256 accepted, got " ..
                      tostring(header.alg) .. ")"
    end

    -- Payload (needed for `exp`).
    local payload_json
    payload_json, err = base64.url_decode(p_b64)
    if not payload_json then
        return false, "base64url decode failed (payload): " .. (err or "?")
    end
    local payload
    payload, err = json.decode(payload_json)
    if not payload or type(payload) ~= "table" then
        return false, "payload JSON decode failed: " .. (err or "not a JSON object")
    end

    -- Signature.
    local sig
    sig, err = base64.url_decode(s_b64)
    if not sig then
        return false, "base64url decode failed (signature): " .. (err or "?")
    end

    -- Recompute HMAC over `header_b64 "." payload_b64`.
    local signing_input = h_b64 .. "." .. p_b64
    local expected = sha256.hmac(secret, signing_input)
    if not consttime_eq(sig, expected) then
        return false, "signature mismatch"
    end

    -- `exp` is REQUIRED by docs/POLICIES.md § p02 and by gen-jwt.sh;
    -- rejecting tokens without `exp` closes a whole class of replay
    -- attacks and matches the canonical fixture (probe 5 in
    -- `fixtures/p02-jwt.jsonl` exercises the `expired` path).
    local now = os_time()
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
_M._consttime_eq = consttime_eq

return _M
