-- gateways/nginx/_shared/lualib/body_rewrite.lua
--
-- Shared JSON body-rewrite helpers for the nginx cell.
-- Used by:
--   * gateways/nginx/p10-req-body   — request-side  inject + drop
--   * gateways/nginx/p11-resp-body  — response-side inject + drop
--   * gateways/nginx/p12-full-pipeline — composed of p09 + p10 paths
--
-- The wallarm counterpart does the same transform via `lua_runner` +
-- `cjson.safe` (see gateways/wallarm/p10-req-body and
-- gateways/wallarm/p11-resp-body NOTES.md). On OpenResty
-- we call this module directly from `access_by_lua_block` /
-- `body_filter_by_lua_block`.

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
-- _M.rewrite_request(raw_body, add_path, drop_path) -> new_body, err
--
-- Semantics:
--   * raw_body is a (possibly empty) string as read from the client.
--   * The body is parsed as JSON; a non-JSON or empty body is
--     coerced to {} so the "inject" invariant still produces a
--     well-formed JSON object.
--   * add_path = {"bench","injected"} means set data.bench.injected
--     = true; the intermediate table is created if absent.
--   * drop_path = {"secret"} means data.secret = nil.
--
-- Returns the re-encoded JSON string and a nil error.
-- -----------------------------------------------------------------------------

function _M.rewrite_request(raw_body, add_path, add_value, drop_path)
    local data = cjson_safe.decode(raw_body or "")
    data = to_table(data)

    -- Walk the add_path, coercing intermediate non-tables to tables
    -- so e.g. `"bench": "hi"` can't crash the rewrite.
    local cursor = data
    for i = 1, #add_path - 1 do
        local k = add_path[i]
        if type(cursor[k]) ~= "table" then cursor[k] = {} end
        cursor = cursor[k]
    end
    cursor[add_path[#add_path]] = add_value

    -- Drop path is currently always single-level ($.secret / $.origin)
    -- per docs/POLICIES.md § p09/p10, but walk it as a list anyway
    -- so the helper stays generic.
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
-- verbatim; we only rewrite well-formed JSON objects. This matches
-- the wallarm cell behaviour (gateways/wallarm/p11-resp-body/NOTES.md).
function _M.rewrite_response_if_json(raw_body, add_path, add_value, drop_path)
    local data = cjson_safe.decode(raw_body or "")
    if type(data) ~= "table" then return raw_body end
    return _M.rewrite_request(raw_body, add_path, add_value, drop_path)
end

return _M
