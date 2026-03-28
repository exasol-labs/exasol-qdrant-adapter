--- Capability definitions for the Qdrant Virtual Schema Lua adapter.
-- Declares the minimum conservative set that matches the previous Java adapter.

local AdapterCapabilities = require("exasol.vscl.AdapterCapabilities")

local M = {}

--- Creates and returns the adapter's capability set.
-- Honors EXCLUDED_CAPABILITIES: a comma-separated list of capability names
-- to omit (e.g. "LIMIT,LIMIT_WITH_OFFSET").
-- @param excluded_str string|nil  Value of the EXCLUDED_CAPABILITIES property
-- @return AdapterCapabilities
function M.create(excluded_str)
    local excluded = {}
    if excluded_str and excluded_str ~= "" then
        for cap in excluded_str:gmatch("[^,]+") do
            excluded[cap:match("^%s*(.-)%s*$")] = true
        end
    end

    local caps = AdapterCapabilities:new()

    local function add_main(cap)
        if not excluded[cap] then caps:add_main_capability(cap) end
    end
    local function add_predicate(cap)
        if not excluded[cap] then caps:add_predicate_capability(cap) end
    end
    local function add_literal(cap)
        if not excluded[cap] then caps:add_literal_capability(cap) end
    end

    add_main("SELECTLIST_EXPRESSIONS")
    add_main("FILTER_EXPRESSIONS")
    add_main("LIMIT")
    add_main("LIMIT_WITH_OFFSET")
    add_predicate("EQUAL")
    add_literal("STRING")

    return caps
end

return M
