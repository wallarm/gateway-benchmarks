-- gateways/envoy/_shared/lualib/body_rewrite.lua
--
-- Shared JSON body-rewrite helpers for the envoy column.
-- Used by:
--   * gateways/envoy/p10-req-body   — request-side  inject + drop
--   * gateways/envoy/p11-resp-body  — response-side inject + drop
--   * gateways/envoy/p12-full-pipeline — composition of p09 + p10
--
-- The API is deliberately identical to the nginx version at
-- `gateways/nginx/_shared/lualib/body_rewrite.lua` so the two columns
-- can reason about bodies with the same vocabulary:
--
--     local body = require("body_rewrite")
--     local new = body.rewrite_request(raw_body,
--                                      { "bench", "injected" }, true,
--                                      { "secret" })
--
-- The only runtime difference: envoy's Lua has no `cjson` bundled, so
-- the parser is the pure-Lua `json` module in this directory. The
-- nginx version leans on `cjson.safe` from bundled OpenResty. The
-- contract (same inputs, same outputs, same handling of non-JSON
-- bodies) is unchanged.

local _M = {}

local json = require("json")

-- Normalise a decoded value to a table. `json.decode` of `null`
-- yields our sentinel, which is neither nil nor a plain table; treat
-- it as a missing object so the "inject" invariant still holds.
local function to_table(v)
    if type(v) ~= "table" or v == json.null then
        return json.new_object({})
    end
    return v
end

-- -----------------------------------------------------------------------------
-- _M.rewrite_request(raw_body, add_path, add_value, drop_path)
--   -> new_body, err
--
-- Semantics:
--   * raw_body is a (possibly empty) string as read from the client.
--   * The body is parsed as JSON; a non-JSON or empty body is
--     coerced to `{}` so the "inject" invariant still produces a
--     well-formed JSON object.
--   * add_path  = {"bench","injected"} => set data.bench.injected
--     = add_value; intermediate objects are created as needed.
--   * drop_path = {"secret"}           => set data.secret = nil.
--
-- Returns (new_body, nil) or, if JSON encoding fails for some
-- exotic reason (Inf/NaN etc. — never produced by the fixtures),
-- (nil, err).
-- -----------------------------------------------------------------------------
function _M.rewrite_request(raw_body, add_path, add_value, drop_path)
    local data
    if raw_body and raw_body ~= "" then
        data = json.decode(raw_body)
    end
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

    -- drop_path is single-level in the canonical fixtures
    -- ($.secret / $.origin) but we walk it as a list to stay
    -- generic for future profiles.
    if drop_path and #drop_path > 0 then
        cursor = data
        for i = 1, #drop_path - 1 do
            local k = drop_path[i]
            if type(cursor[k]) ~= "table" then
                -- Intermediate segment does not exist; nothing to drop.
                return json.encode(data)
            end
            cursor = cursor[k]
        end
        cursor[drop_path[#drop_path]] = nil
    end

    local encoded, err = json.encode(data)
    if not encoded then return nil, err end
    return encoded, nil
end

-- -----------------------------------------------------------------------------
-- Response bodies can legitimately be non-JSON (HTML error pages,
-- streamed binary). In that case the upstream payload is returned
-- verbatim; we only rewrite well-formed JSON objects.
-- -----------------------------------------------------------------------------
function _M.rewrite_response_if_json(raw_body, add_path, add_value, drop_path)
    if not raw_body or raw_body == "" then return raw_body end
    local decoded = json.decode(raw_body)
    if type(decoded) ~= "table" or decoded == json.null then
        return raw_body
    end
    local new, err = _M.rewrite_request(raw_body, add_path, add_value, drop_path)
    if not new then
        -- Rewrite failed — pass the original through rather than
        -- returning a broken body that would confuse the client.
        return raw_body, err
    end
    return new
end

return _M
