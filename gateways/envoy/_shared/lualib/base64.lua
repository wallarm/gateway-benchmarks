-- gateways/envoy/_shared/lualib/base64.lua
--
-- Minimal pure-Lua base64 / base64url encoder + decoder for Envoy's
-- bundled LuaJIT runtime.
--
-- Envoy's `envoy.filters.http.lua` ships a sandboxed LuaJIT with the
-- standard library (`string`, `table`, `math`, `os`, `bit`) but does
-- NOT bundle OpenResty's `ngx.encode_base64` / `ngx.decode_base64`
-- helpers or `lua-cjson`. The JWT cell (p02-jwt, p12-full-pipeline)
-- needs base64url decode for header+payload segments and base64url
-- encode for round-trip verification; pure Lua is the only option
-- that respects the "public pinned image, no Dockerfile" contract.
--
-- Implementation follows RFC 4648:
--   §4 — standard base64, alphabet `A-Za-z0-9+/`, pad with `=`.
--   §5 — URL/filename-safe base64, alphabet `A-Za-z0-9-_`, no pad.
--
-- Uses LuaJIT's `bit` module for 32-bit arithmetic (shift, and, or),
-- which is itself a standard LuaJIT primitive and always available
-- inside Envoy's Lua sandbox.

local _M = {}

local bit          = require("bit")
local band, bor    = bit.band, bit.bor
local lshift       = bit.lshift
local rshift       = bit.rshift
local string_byte  = string.byte
local string_char  = string.char
local string_sub   = string.sub
local string_rep   = string.rep
local table_concat = table.concat

-- RFC 4648 §4 (standard) and §5 (url-safe) alphabets.
local B64_STD = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

-- Build a fast lookup table for decoding once, at module load. The
-- same table handles both alphabets because we normalise URL input
-- (`-` → `+`, `_` → `/`) before decoding.
local DECODE = {}
for i = 1, #B64_STD do DECODE[string_byte(B64_STD, i)] = i - 1 end

-- -----------------------------------------------------------------------------
-- Low-level encode. Outputs either with or without `=` padding, with
-- either the standard or URL-safe alphabet.
-- -----------------------------------------------------------------------------
local function encode_impl(input, alphabet, pad_output)
    if not input or input == "" then return "" end
    local out, n = {}, #input
    local i = 1
    while i <= n do
        local b1 = string_byte(input, i)
        local b2 = i + 1 <= n and string_byte(input, i + 1) or 0
        local b3 = i + 2 <= n and string_byte(input, i + 2) or 0
        local s1 = rshift(b1, 2)
        local s2 = bor(lshift(band(b1, 0x03), 4), rshift(b2, 4))
        local s3 = bor(lshift(band(b2, 0x0F), 2), rshift(b3, 6))
        local s4 = band(b3, 0x3F)
        out[#out + 1] = string_sub(alphabet, s1 + 1, s1 + 1)
        out[#out + 1] = string_sub(alphabet, s2 + 1, s2 + 1)
        if i + 1 <= n then
            out[#out + 1] = string_sub(alphabet, s3 + 1, s3 + 1)
        elseif pad_output then
            out[#out + 1] = "="
        end
        if i + 2 <= n then
            out[#out + 1] = string_sub(alphabet, s4 + 1, s4 + 1)
        elseif pad_output then
            out[#out + 1] = "="
        end
        i = i + 3
    end
    return table_concat(out)
end

-- -----------------------------------------------------------------------------
-- Low-level decode. Consumes standard base64 (with or without
-- padding). Callers that come in via the URL-safe flavour must
-- normalise `-/_` → `+//` before calling us.
-- -----------------------------------------------------------------------------
local function decode_impl(input)
    if not input or input == "" then return "", nil end
    -- Strip trailing pad; we track segment length by remainder instead.
    input = input:gsub("=+$", "")
    local n = #input
    if n == 0 then return "", nil end
    -- A 1-char trailing group is never valid base64 (minimum 2 chars
    -- encode a single byte; 3 chars encode two bytes; 4 chars encode
    -- three bytes). Reject early.
    if (n % 4) == 1 then return nil, "invalid length" end
    local out = {}
    local i = 1
    while i <= n do
        local c1 = string_byte(input, i)
        local c2 = i + 1 <= n and string_byte(input, i + 1) or nil
        local c3 = i + 2 <= n and string_byte(input, i + 2) or nil
        local c4 = i + 3 <= n and string_byte(input, i + 3) or nil
        local v1 = c1 and DECODE[c1] or nil
        local v2 = c2 and DECODE[c2] or nil
        if not v1 or not v2 then return nil, "invalid character" end
        out[#out + 1] = string_char(band(bor(lshift(v1, 2), rshift(v2, 4)), 0xFF))
        if c3 then
            local v3 = DECODE[c3]
            if not v3 then return nil, "invalid character" end
            out[#out + 1] = string_char(band(bor(lshift(v2, 4), rshift(v3, 2)), 0xFF))
            if c4 then
                local v4 = DECODE[c4]
                if not v4 then return nil, "invalid character" end
                out[#out + 1] = string_char(band(bor(lshift(v3, 6), v4), 0xFF))
            end
        end
        i = i + 4
    end
    return table_concat(out), nil
end

-- -----------------------------------------------------------------------------
-- Public API.
-- -----------------------------------------------------------------------------

function _M.encode(raw)
    return encode_impl(raw, B64_STD, true)
end

function _M.decode(s)
    return decode_impl(s)
end

-- URL-safe base64 per RFC 4648 §5. No padding on encode; accept pad
-- on decode (some issuers still emit it). Character substitution is
-- `+` → `-`, `/` → `_`.
function _M.url_encode(raw)
    local enc = encode_impl(raw, B64_STD, false)
    enc = enc:gsub("+", "-"):gsub("/", "_")
    return enc
end

function _M.url_decode(s)
    if not s or s == "" then return nil, "empty" end
    s = s:gsub("-", "+"):gsub("_", "/")
    local pad = (4 - (#s % 4)) % 4
    if pad > 0 then s = s .. string_rep("=", pad) end
    return decode_impl(s)
end

return _M
