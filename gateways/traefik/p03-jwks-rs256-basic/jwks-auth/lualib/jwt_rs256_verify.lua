-- gateways/nginx/_shared/lualib/jwt_rs256_verify.lua
--
-- Low-level RS256 signature-verify primitive for the gateway-benchmarks
-- nginx (OpenResty) p03-jwks-rs256-basic scenario. Pure LuaJIT FFI against
-- the OpenSSL 3.x `libcrypto` that OpenResty 1.27.1.2-alpine ships under
-- /usr/local/openresty/openssl3/lib/libcrypto.so (the same binary
-- OpenResty itself links against, so there is no ABI mismatch risk).
--
-- Why FFI and not pure Lua:
--
--   * Pure-Lua RS256 requires bigint modexp (c^e mod N for 2048-bit N)
--     — that is ~150 LoC of tight, error-prone LuaJIT arithmetic
--     that we would have to audit ourselves. Calling directly into
--     `EVP_DigestVerify*` is three ffi.cdef entries and a handful of
--     constants; the whole path goes through battle-tested code in
--     libcrypto.
--   * No opm install, no custom Dockerfile: libcrypto.so is already
--     in the pinned public image. This preserves the reproducibility
--     story that `jwt_hs256.lua` has.
--
-- What this module DOES:
--
--   * `load_pubkey_pem(pem_str) -> EVP_PKEY*` — parse a PEM-encoded
--     `-----BEGIN PUBLIC KEY-----` SPKI blob and return an
--     EVP_PKEY pointer with an attached ffi.gc finaliser. Caller
--     never has to manually free — the GC will do EVP_PKEY_free at
--     collection time.
--   * `verify_rs256(pkey, signing_input, signature) -> ok, err` —
--     compute SHA-256 over `signing_input` and RSASSA-PKCS1-v1_5
--     verify against `signature` using `pkey`. Returns
--     (true, nil) on a valid signature, (false, "reason") on
--     tampering or mismatch.
--
-- What this module does NOT do:
--
--   * JWK → PEM conversion. Callers pass a PEM directly. This is
--     deliberate: the p03-jwks-rs256-basic fixture ships a canonical PEM
--     next to the JWKS under gateways/_reference/jwks-rs256/, and
--     the drift guard in setup.sh keeps them in sync. Doing an
--     ASN.1 SPKI construction in Lua would re-implement half of
--     OpenSSL's public-key encoder for no win.
--   * `alg` / `kid` / `exp` parsing. That is the JWT layer's job
--     (see `jwt_rs256_jwks.lua`).
--   * HS256 signatures. Use `jwt_hs256.lua` for those.
--
-- ABI stability: the EVP_DigestVerify* entry points used here are
-- unchanged between OpenSSL 1.1, 3.0, 3.2, and 3.5. The ffi.cdef
-- covers only the minimal subset needed; no structure layouts are
-- exposed.

local ffi = require("ffi")

-- Pinned absolute path — we want the libcrypto OpenResty itself was
-- linked against, not whatever `libcrypto.so` happens to be first
-- on the dynamic-linker search path. On the pinned
-- openresty/openresty:1.27.1.2-alpine image that is OpenSSL 3.5.5.
local OPENSSL_LIB = "/usr/local/openresty/openssl3/lib/libcrypto.so"

local crypto = ffi.load(OPENSSL_LIB)

ffi.cdef[[
typedef struct bio_st           BIO;
typedef struct evp_pkey_st      EVP_PKEY;
typedef struct evp_md_ctx_st    EVP_MD_CTX;
typedef struct evp_md_st        EVP_MD;
typedef struct engine_st        ENGINE;

BIO       *BIO_new_mem_buf(const void *buf, int len);
int        BIO_free(BIO *a);

EVP_PKEY  *PEM_read_bio_PUBKEY(BIO *bp, EVP_PKEY **x, void *cb, void *u);
void       EVP_PKEY_free(EVP_PKEY *pkey);

EVP_MD_CTX *EVP_MD_CTX_new(void);
void        EVP_MD_CTX_free(EVP_MD_CTX *ctx);

const EVP_MD *EVP_sha256(void);

int EVP_DigestVerifyInit(EVP_MD_CTX *ctx, void **pctx,
                          const EVP_MD *type, ENGINE *e, EVP_PKEY *pkey);
int EVP_DigestVerifyUpdate(EVP_MD_CTX *ctx, const void *d, size_t cnt);
int EVP_DigestVerifyFinal (EVP_MD_CTX *ctx, const unsigned char *sig,
                           size_t siglen);

void ERR_clear_error(void);
]]

local _M = {}

-- -----------------------------------------------------------------------------
-- load_pubkey_pem(pem_str) -> EVP_PKEY* (GC-managed) | nil, err
--
-- The returned cdata is an `EVP_PKEY *` whose __gc calls EVP_PKEY_free,
-- so the caller can hand it to `verify_rs256` directly, cache it in
-- a module-level table, or discard it without manual cleanup.
-- -----------------------------------------------------------------------------
function _M.load_pubkey_pem(pem_str)
    if type(pem_str) ~= "string" or pem_str == "" then
        return nil, "empty PEM string"
    end

    local bio = crypto.BIO_new_mem_buf(pem_str, #pem_str)
    if bio == nil then
        return nil, "BIO_new_mem_buf returned NULL"
    end

    local pkey = crypto.PEM_read_bio_PUBKEY(bio, nil, nil, nil)
    crypto.BIO_free(bio)

    if pkey == nil then
        crypto.ERR_clear_error()
        return nil, "PEM_read_bio_PUBKEY failed (malformed PEM or unsupported key type)"
    end

    return ffi.gc(pkey, crypto.EVP_PKEY_free), nil
end

-- -----------------------------------------------------------------------------
-- verify_rs256(pkey, signing_input, signature) -> ok, err
--
-- pkey            : EVP_PKEY* from load_pubkey_pem.
-- signing_input   : string — the base64url(header) "." base64url(payload)
--                   (JWT signing input; ASCII bytes).
-- signature       : string — the RAW (already base64url-decoded) signature
--                   bytes from the JWT's third segment. For RS256 this
--                   is 256 bytes for a 2048-bit key.
--
-- Returns (true, nil) on a signature that passes PKCS#1 v1.5 verify;
-- (false, reason) otherwise. The reason string is diagnostic only —
-- callers should never echo it to a client (it may leak whether a
-- signature "almost" matched, which is not our threat model for a
-- benchmark but is the responsible default).
-- -----------------------------------------------------------------------------
function _M.verify_rs256(pkey, signing_input, signature)
    if pkey == nil then return false, "nil pkey" end
    if type(signing_input) ~= "string" or signing_input == "" then
        return false, "empty signing_input"
    end
    if type(signature) ~= "string" or signature == "" then
        return false, "empty signature"
    end

    local ctx = crypto.EVP_MD_CTX_new()
    if ctx == nil then
        return false, "EVP_MD_CTX_new returned NULL"
    end

    -- EVP_DigestVerifyInit(ctx, pctx, type, engine, pkey) -> 1 on success
    local ok_init = crypto.EVP_DigestVerifyInit(ctx, nil, crypto.EVP_sha256(),
                                                nil, pkey)
    if ok_init ~= 1 then
        crypto.EVP_MD_CTX_free(ctx)
        crypto.ERR_clear_error()
        return false, "EVP_DigestVerifyInit failed"
    end

    local ok_upd = crypto.EVP_DigestVerifyUpdate(ctx, signing_input,
                                                 #signing_input)
    if ok_upd ~= 1 then
        crypto.EVP_MD_CTX_free(ctx)
        crypto.ERR_clear_error()
        return false, "EVP_DigestVerifyUpdate failed"
    end

    -- EVP_DigestVerifyFinal returns:
    --   1  - signature verified
    --   0  - signature NOT verified (tampering; NOT an error)
    --   <0 - error (e.g., bad parameters)
    local rc = crypto.EVP_DigestVerifyFinal(ctx, signature, #signature)
    crypto.EVP_MD_CTX_free(ctx)
    crypto.ERR_clear_error()

    if rc == 1 then
        return true, nil
    elseif rc == 0 then
        return false, "signature mismatch"
    else
        return false, "EVP_DigestVerifyFinal error (rc=" .. tostring(rc) .. ")"
    end
end

-- Exposed for tests / debugging only. Nothing inside the request hot
-- path should look at these.
_M._openssl_lib = OPENSSL_LIB

return _M
