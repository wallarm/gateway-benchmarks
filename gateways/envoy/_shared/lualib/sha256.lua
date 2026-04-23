-- gateways/envoy/_shared/lualib/sha256.lua
--
-- Pure-Lua SHA-256 (FIPS PUB 180-4) + HMAC-SHA-256 (RFC 2104).
--
-- Lives under the envoy column because Envoy's Lua filter runs on a
-- vanilla LuaJIT sandbox with NO access to OpenResty's
-- `resty.sha256` / `resty.string` modules. The nginx column has its
-- own, simpler version that leans on those bundled helpers; this
-- file is the envoy-native equivalent and keeps the same API
-- contract (raw bytes in, 32-byte raw digest out).
--
-- LuaJIT's `bit` module gives us 32-bit unsigned arithmetic on
-- signed-int values; every `band`/`bor`/`bxor`/`rshift`/`rrotate`
-- call below is well-defined on the low 32 bits regardless of the
-- Lua number sign. `bit.tobit(x)` normalises an arbitrary-precision
-- result back to a 32-bit int so the addition accumulators in the
-- compression loop stay tight.
--
-- The implementation is straightforward FIPS 180-4 §6.2 (SHA-256
-- compression) + §5.1.1 (padding) + §5.3.3 (initial hash values) +
-- RFC 2104 §2 (HMAC construction). No clever tricks; the whole file
-- is ~140 lines of documented code the reviewer can eyeball against
-- the spec. Performance is plenty for the benchmark: the signing
-- input on a canonical JWT is ~220 bytes, and we do at most one
-- HMAC per request.

local _M = {}

local bit           = require("bit")
local band          = bit.band
local bor           = bit.bor
local bxor          = bit.bxor
local bnot          = bit.bnot
local lshift        = bit.lshift
local rshift        = bit.rshift
local rrotate       = bit.ror
local tobit         = bit.tobit
local string_byte   = string.byte
local string_char   = string.char
local string_sub    = string.sub
local string_rep    = string.rep
local table_concat  = table.concat

-- FIPS 180-4 §4.2.2 — first 32 bits of the fractional parts of the cube
-- roots of the first 64 primes.
local K = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

-- FIPS 180-4 §5.3.3 — first 32 bits of the fractional parts of the square
-- roots of the first 8 primes. These are the SHA-256 initial hash values.
local H0 = {
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
}

-- Pack four bytes (big-endian) into a 32-bit word.
local function bytes_to_word(b1, b2, b3, b4)
    return bor(lshift(b1, 24), lshift(b2, 16), lshift(b3, 8), b4)
end

-- Serialise a 32-bit word as 4 big-endian bytes.
local function word_to_bytes(w)
    return string_char(band(rshift(w, 24), 0xFF),
                       band(rshift(w, 16), 0xFF),
                       band(rshift(w,  8), 0xFF),
                       band(w,             0xFF))
end

-- FIPS 180-4 §5.1.1 — append `0x80`, zero-pad, then the original bit
-- length as a 64-bit big-endian integer. For our use cases (JWT
-- signing input + 1 MiB request bodies at the very most) the length
-- comfortably fits in 32 bits, so we set the high 32 bits of the
-- length field to zero.
local function pad(msg)
    local len_bits = #msg * 8
    msg = msg .. "\128"
    while (#msg % 64) ~= 56 do msg = msg .. "\0" end
    msg = msg .. "\0\0\0\0" .. word_to_bytes(len_bits)
    return msg
end

-- FIPS 180-4 §4.1.2 — the six logical functions used in the
-- compression step. They combine with `tobit` in the accumulator
-- additions because Lua number arithmetic can temporarily exceed 32
-- bits even when every operand is a 32-bit int.
local function ch(x, y, z)   return bxor(band(x, y), band(bnot(x), z)) end
local function maj(x, y, z)  return bxor(band(x, y), band(x, z), band(y, z)) end
local function bsig0(x)      return bxor(rrotate(x, 2),  rrotate(x, 13), rrotate(x, 22)) end
local function bsig1(x)      return bxor(rrotate(x, 6),  rrotate(x, 11), rrotate(x, 25)) end
local function ssig0(x)      return bxor(rrotate(x, 7),  rrotate(x, 18), rshift(x, 3))   end
local function ssig1(x)      return bxor(rrotate(x, 17), rrotate(x, 19), rshift(x, 10))  end

-- Public: compute the raw 32-byte SHA-256 digest of `msg`.
function _M.sum(msg)
    msg = pad(msg)
    local h = { H0[1], H0[2], H0[3], H0[4], H0[5], H0[6], H0[7], H0[8] }
    local block_count = #msg / 64

    for blk = 0, block_count - 1 do
        local base = blk * 64
        local w = {}
        for t = 0, 15 do
            local o = base + t * 4 + 1
            w[t] = bytes_to_word(
                string_byte(msg, o),
                string_byte(msg, o + 1),
                string_byte(msg, o + 2),
                string_byte(msg, o + 3))
        end
        for t = 16, 63 do
            w[t] = tobit(ssig1(w[t - 2]) + w[t - 7] + ssig0(w[t - 15]) + w[t - 16])
        end

        local a, b, c, d, e, f, g, hh =
            h[1], h[2], h[3], h[4], h[5], h[6], h[7], h[8]
        for t = 0, 63 do
            local t1 = tobit(hh + bsig1(e) + ch(e, f, g) + K[t + 1] + w[t])
            local t2 = tobit(bsig0(a) + maj(a, b, c))
            hh = g
            g  = f
            f  = e
            e  = tobit(d + t1)
            d  = c
            c  = b
            b  = a
            a  = tobit(t1 + t2)
        end

        h[1] = tobit(h[1] + a);  h[2] = tobit(h[2] + b)
        h[3] = tobit(h[3] + c);  h[4] = tobit(h[4] + d)
        h[5] = tobit(h[5] + e);  h[6] = tobit(h[6] + f)
        h[7] = tobit(h[7] + g);  h[8] = tobit(h[8] + hh)
    end

    return table_concat({
        word_to_bytes(h[1]), word_to_bytes(h[2]), word_to_bytes(h[3]), word_to_bytes(h[4]),
        word_to_bytes(h[5]), word_to_bytes(h[6]), word_to_bytes(h[7]), word_to_bytes(h[8]),
    })
end

-- Public: hex-encoded digest. Debug-only; the verifier compares raw
-- bytes via `_M.hmac` + constant-time eq, never the hex form.
function _M.hex(msg)
    local digest = _M.sum(msg)
    local hex = {}
    for i = 1, #digest do hex[i] = ("%02x"):format(string_byte(digest, i)) end
    return table_concat(hex)
end

-- RFC 2104 §2 — HMAC(K, m) = H((K' XOR opad) || H((K' XOR ipad) || m)),
-- where K' = H(K) if #K > block size else K, zero-padded to block size.
-- Block size for SHA-256 is 64 bytes.
function _M.hmac(key, msg)
    local BLOCK = 64
    if #key > BLOCK then key = _M.sum(key) end
    local kpad = key .. string_rep("\0", BLOCK - #key)

    local ipad, opad = {}, {}
    for i = 1, BLOCK do
        local b = string_byte(kpad, i)
        ipad[i] = string_char(bxor(b, 0x36))
        opad[i] = string_char(bxor(b, 0x5c))
    end

    local inner = _M.sum(table_concat(ipad) .. msg)
    return _M.sum(table_concat(opad) .. inner)
end

return _M
