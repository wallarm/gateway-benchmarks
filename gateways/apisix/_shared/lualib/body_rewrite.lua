-- gateways/apisix/_shared/lualib/body_rewrite.lua
--
-- Port of gateways/nginx/_shared/lualib/body_rewrite.lua for APISIX.
-- Same shape, same cjson.safe primitive, same Content-Length
-- invariant, so p09/p10/p11 behave byte-for-byte identically across
-- the two OpenResty-based columns (nginx + APISIX).
--
-- Used by:
--   * gateways/apisix/p10-req-body    — request-side  inject + drop
--   * gateways/apisix/p11-resp-body   — response-side inject + drop
--   * gateways/apisix/p12-full-pipeline — composed of p09 + p10 paths
--
-- The serverless-pre-function binds (p09, p11 request side) call
-- `_M.rewrite_request()` after `ngx.req.read_body()` and then
-- `ngx.req.set_body_data()` to publish the transformed body.
-- set_body_data patches Content-Length on the upstream-bound request
-- so the backend never sees a stale length.
--
-- The serverless-post-function binds (p10, p11 response side) call
-- `_M.rewrite_response_if_json()` from `body_filter`. Non-JSON
-- upstream responses (HTML errors, binary streams) are returned
-- verbatim — we only rewrite well-formed JSON objects.

local _M = {}

local cjson_safe = require("cjson.safe")

-- Normalise a decoded value to a table. cjson may return cjson.null
-- for JSON null, which is neither nil nor a table; treat it as a
-- missing object so the "inject" invariant still holds.
local function to_table(v)
    if type(v) ~= "table" then return {} end
    if getmetatable(v) == cjson_safe.array_mt then return v end
    return v
end

-- -----------------------------------------------------------------------------
-- _M.rewrite_request(raw_body, add_path, add_value, drop_path) -> new_body
--
-- Semantics:
--   * raw_body is a (possibly empty) string.
--   * The body is parsed as JSON; a non-JSON or empty body is
--     coerced to {} so the "inject" invariant still produces a
--     well-formed JSON object.
--   * add_path = {"bench","injected"} means set data.bench.injected
--     = true; the intermediate table is created if absent.
--   * drop_path = {"secret"} means data.secret = nil.
-- -----------------------------------------------------------------------------
function _M.rewrite_request(raw_body, add_path, add_value, drop_path)
    local data = cjson_safe.decode(raw_body or "")
    data = to_table(data)

    local cursor = data
    for i = 1, #add_path - 1 do
        local k = add_path[i]
        if type(cursor[k]) ~= "table" then cursor[k] = {} end
        cursor = cursor[k]
    end
    cursor[add_path[#add_path]] = add_value

    if drop_path and #drop_path > 0 then
        cursor = data
        for i = 1, #drop_path - 1 do
            local k = drop_path[i]
            if type(cursor[k]) ~= "table" then return cjson_safe.encode(data) end
            cursor = cursor[k]
        end
        cursor[drop_path[#drop_path]] = nil
    end

    return cjson_safe.encode(data)
end

-- Response bodies can legitimately be non-JSON (HTML error pages,
-- streamed files). In that case the upstream payload is returned
-- verbatim; we only rewrite well-formed JSON objects.
function _M.rewrite_response_if_json(raw_body, add_path, add_value, drop_path)
    local data = cjson_safe.decode(raw_body or "")
    if type(data) ~= "table" then return raw_body end
    return _M.rewrite_request(raw_body, add_path, add_value, drop_path)
end

return _M
