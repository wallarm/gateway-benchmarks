-- gateways/envoy/_shared/lualib/json.lua
--
-- Minimal pure-Lua JSON decoder + encoder for Envoy's Lua filter.
--
-- Envoy does NOT bundle `lua-cjson`, and the only alternative is
-- dropping a 2-4 KB module into `_shared/lualib`. This is that
-- module. Handles:
--
--   * `null`       → `_M.null` sentinel (distinct from Lua `nil`)
--   * `true/false` → Lua booleans
--   * numbers      → Lua numbers (integer-preserving up to 2^53 — the
--                    fixtures never exceed that)
--   * strings      → Lua strings (UTF-8 byte-identical; `\uXXXX`
--                    escapes re-encoded to UTF-8)
--   * arrays       → Lua tables with `_M.array` metatable tag
--   * objects      → Lua tables with `_M.object` metatable tag
--
-- The decoder is strict enough for JWT + go-httpbin responses: it
-- rejects trailing garbage, unterminated strings, bad escapes, and
-- bare values (objects/arrays as top-level are both accepted; so are
-- primitives, matching RFC 8259 §2). Comments are not accepted.
--
-- The encoder distinguishes array from object on serialisation:
-- tables tagged `_M.array` / `_M.object` are forced; unmarked tables
-- fall back to the "all keys 1..n integers → array, else object"
-- heuristic (same as `cjson`). Empty unmarked tables serialise as
-- `{}` (the nginx column's body_rewrite.lua relies on the same
-- defaulting).

local _M = {}

local string_byte   = string.byte
local string_char   = string.char
local string_sub    = string.sub
local string_format = string.format
local table_concat  = table.concat
local setmetatable  = setmetatable
local getmetatable  = getmetatable
local tostring      = tostring
local tonumber      = tonumber
local math_floor    = math.floor
local math_huge     = math.huge

-- -----------------------------------------------------------------------------
-- Type sentinels. `null` is a unique, shared table so callers can do
-- `v == json.null`. The array/object metatables are used as tags
-- (no behaviour beyond identity comparison).
-- -----------------------------------------------------------------------------
local NULL = {}
_M.null = NULL

local ARRAY_MT  = { __jsontype = "array"  }
local OBJECT_MT = { __jsontype = "object" }
_M.array_mt     = ARRAY_MT
_M.object_mt    = OBJECT_MT

function _M.new_array(t)  return setmetatable(t or {}, ARRAY_MT)  end
function _M.new_object(t) return setmetatable(t or {}, OBJECT_MT) end

-- -----------------------------------------------------------------------------
-- Decoder.
-- -----------------------------------------------------------------------------

local parse_value  -- forward declaration (mutual recursion with array/object)

local function skip_ws(s, i)
    while true do
        local c = string_byte(s, i)
        if c == 0x20 or c == 0x09 or c == 0x0A or c == 0x0D then
            i = i + 1
        else
            return i
        end
    end
end

-- Emit the Unicode code point `cp` as UTF-8 bytes. Called from the
-- `\uXXXX` branch of parse_string.
local function utf8_encode(cp)
    if cp < 0x80 then
        return string_char(cp)
    elseif cp < 0x800 then
        return string_char(0xC0 + math_floor(cp / 0x40),
                           0x80 + (cp % 0x40))
    elseif cp < 0x10000 then
        return string_char(0xE0 + math_floor(cp / 0x1000),
                           0x80 + math_floor((cp % 0x1000) / 0x40),
                           0x80 + (cp % 0x40))
    else
        return string_char(0xF0 + math_floor(cp / 0x40000),
                           0x80 + math_floor((cp % 0x40000) / 0x1000),
                           0x80 + math_floor((cp % 0x1000) / 0x40),
                           0x80 + (cp % 0x40))
    end
end

local ESCAPE = {
    ['"']  = '"', ['\\'] = '\\', ['/']  = '/',
    ['b']  = '\b', ['f']  = '\f',
    ['n']  = '\n', ['r']  = '\r', ['t']  = '\t',
}

local function parse_string(s, i)
    -- Assumes s[i] == '"'.
    local out, j = {}, i + 1
    while true do
        local c = string_byte(s, j)
        if not c then error("unterminated string", 0) end
        if c == 0x22 then       -- '"' — end of string
            return table_concat(out), j + 1
        elseif c == 0x5C then   -- '\\' — escape
            local esc = string_sub(s, j + 1, j + 1)
            if ESCAPE[esc] then
                out[#out + 1] = ESCAPE[esc]
                j = j + 2
            elseif esc == 'u' then
                local hex = string_sub(s, j + 2, j + 5)
                local cp = tonumber(hex, 16)
                if not cp then error("bad \\u escape", 0) end
                -- Surrogate pairs: decode `\uD8xx\uDCxx` into a single
                -- astral code point. JWTs and go-httpbin don't emit
                -- astrals but the fixture surface could conceivably
                -- gain non-BMP text later.
                if cp >= 0xD800 and cp <= 0xDBFF then
                    local lo = string_sub(s, j + 6, j + 11)
                    if lo:sub(1, 2) ~= "\\u" then
                        error("bad surrogate pair", 0)
                    end
                    local lo_cp = tonumber(lo:sub(3, 6), 16)
                    if not lo_cp then error("bad surrogate pair", 0) end
                    cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo_cp - 0xDC00)
                    j = j + 12
                else
                    j = j + 6
                end
                out[#out + 1] = utf8_encode(cp)
            else
                error("bad escape", 0)
            end
        else
            out[#out + 1] = string_sub(s, j, j)
            j = j + 1
        end
    end
end

local function parse_number(s, i)
    local j = i
    local c = string_byte(s, j)
    if c == 0x2D then j = j + 1 end         -- optional leading '-'
    while true do
        c = string_byte(s, j)
        if not c then break end
        -- digit / '.' / 'e' / 'E' / '+' / '-' (the last two only make sense
        -- after an exponent marker, but accept liberally and let tonumber
        -- validate the full slice).
        if (c >= 0x30 and c <= 0x39) or c == 0x2E or c == 0x45 or c == 0x65
           or c == 0x2B or c == 0x2D then
            j = j + 1
        else
            break
        end
    end
    local raw = string_sub(s, i, j - 1)
    local n = tonumber(raw)
    if not n then error("bad number: " .. raw, 0) end
    return n, j
end

local function parse_object(s, i)
    local t = _M.new_object({})
    i = skip_ws(s, i + 1)
    if string_byte(s, i) == 0x7D then return t, i + 1 end    -- empty '{}'
    while true do
        if string_byte(s, i) ~= 0x22 then error("expected string key", 0) end
        local key
        key, i = parse_string(s, i)
        i = skip_ws(s, i)
        if string_byte(s, i) ~= 0x3A then error("expected ':'", 0) end
        i = skip_ws(s, i + 1)
        local v
        v, i = parse_value(s, i)
        t[key] = v
        i = skip_ws(s, i)
        local c = string_byte(s, i)
        if c == 0x7D then return t, i + 1 end
        if c ~= 0x2C then error("expected ',' or '}'", 0) end
        i = skip_ws(s, i + 1)
    end
end

local function parse_array(s, i)
    local t = _M.new_array({})
    i = skip_ws(s, i + 1)
    if string_byte(s, i) == 0x5D then return t, i + 1 end    -- empty '[]'
    local idx = 1
    while true do
        local v
        v, i = parse_value(s, i)
        t[idx] = v
        idx = idx + 1
        i = skip_ws(s, i)
        local c = string_byte(s, i)
        if c == 0x5D then return t, i + 1 end
        if c ~= 0x2C then error("expected ',' or ']'", 0) end
        i = skip_ws(s, i + 1)
    end
end

parse_value = function(s, i)
    i = skip_ws(s, i)
    local c = string_byte(s, i)
    if c == 0x22 then
        return parse_string(s, i)
    elseif c == 0x7B then
        return parse_object(s, i)
    elseif c == 0x5B then
        return parse_array(s, i)
    elseif c == 0x74 and string_sub(s, i, i + 3) == "true"  then
        return true, i + 4
    elseif c == 0x66 and string_sub(s, i, i + 4) == "false" then
        return false, i + 5
    elseif c == 0x6E and string_sub(s, i, i + 3) == "null"  then
        return NULL, i + 4
    else
        return parse_number(s, i)
    end
end

-- Public: decode. Returns (value, nil) on success, (nil, err) on failure.
function _M.decode(s)
    if type(s) ~= "string" then return nil, "input not a string" end
    if s == "" then return nil, "empty input" end
    local ok, val, rest = pcall(parse_value, s, 1)
    if not ok then return nil, val end
    if rest == nil then return nil, "internal: no end position" end
    -- Allow trailing whitespace but nothing else — a stray byte past
    -- the root value is rejected as malformed.
    rest = skip_ws(s, rest)
    if rest <= #s then return nil, "trailing garbage at offset " .. tostring(rest) end
    return val, nil
end

-- -----------------------------------------------------------------------------
-- Encoder.
-- -----------------------------------------------------------------------------

local encode_value  -- forward declaration

-- Map of simple escape replacements. Everything outside this table
-- AND outside the printable ASCII range is emitted as `\uXXXX`.
local STRING_ESCAPES = {
    ['\\'] = '\\\\', ['"'] = '\\"', ['\b'] = '\\b', ['\f'] = '\\f',
    ['\n'] = '\\n',  ['\r'] = '\\r', ['\t'] = '\\t',
}

local function escape_char(c)
    return STRING_ESCAPES[c] or string_format("\\u%04x", string_byte(c))
end

local function encode_string(s)
    -- The gsub pattern covers the 7 well-known escapes AND any C0
    -- control character (0x00..0x1F). UTF-8 continuation bytes
    -- (0x80..0xBF) pass through unchanged — we are encoding bytes,
    -- not code points.
    return '"' .. s:gsub('[%z\1-\31\\"]', escape_char) .. '"'
end

-- Decide whether a Lua table should serialise as a JSON array or
-- object. Explicit metatable tag wins; otherwise apply the
-- "all keys are 1..n integers, n == table size" test.
local function is_array(t)
    local mt = getmetatable(t)
    if mt == ARRAY_MT  then return true  end
    if mt == OBJECT_MT then return false end
    local n = 0
    for k in pairs(t) do
        if type(k) ~= "number" then return false end
        n = n + 1
    end
    for i = 1, n do
        if t[i] == nil then return false end
    end
    return n > 0
end

local function encode_number(n)
    if n ~= n then error("cannot encode NaN", 0) end
    if n == math_huge or n == -math_huge then error("cannot encode Inf", 0) end
    if n == math_floor(n) and n < 1e15 and n > -1e15 then
        return string_format("%d", n)
    end
    return string_format("%.14g", n)
end

local function encode_array(t)
    local n = #t
    if n == 0 then return "[]" end
    local parts = {}
    for i = 1, n do parts[i] = encode_value(t[i]) end
    return "[" .. table_concat(parts, ",") .. "]"
end

local function encode_object(t)
    local parts = {}
    for k, v in pairs(t) do
        parts[#parts + 1] = encode_string(tostring(k)) .. ":" .. encode_value(v)
    end
    if #parts == 0 then return "{}" end
    return "{" .. table_concat(parts, ",") .. "}"
end

encode_value = function(v)
    if v == nil or v == NULL then
        return "null"
    end
    local t = type(v)
    if t == "boolean" then
        return v and "true" or "false"
    elseif t == "number" then
        return encode_number(v)
    elseif t == "string" then
        return encode_string(v)
    elseif t == "table" then
        if is_array(v) then return encode_array(v) else return encode_object(v) end
    end
    error("cannot encode value of type " .. t, 0)
end

function _M.encode(v)
    local ok, r = pcall(encode_value, v)
    if not ok then return nil, r end
    return r
end

return _M
