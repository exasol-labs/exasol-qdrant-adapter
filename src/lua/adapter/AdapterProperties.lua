--- Adapter properties for the Qdrant Virtual Schema Lua adapter.
-- Extends exasol.vscl.AdapterProperties with Qdrant-specific property
-- access, validation, and merge semantics.

local base_props = require("exasol.vscl.AdapterProperties")

local AdapterProperties = {}
AdapterProperties.__index = AdapterProperties
setmetatable(AdapterProperties, {__index = base_props})

-- Property key constants
AdapterProperties.CONNECTION_NAME    = "CONNECTION_NAME"
AdapterProperties.QDRANT_MODEL       = "QDRANT_MODEL"
AdapterProperties.QDRANT_URL         = "QDRANT_URL"
AdapterProperties.COLLECTION_FILTER  = "COLLECTION_FILTER"

-- Properties that have been removed and SHALL be rejected if encountered.
-- Maps key → migration message.
local REMOVED_PROPERTIES = {
    OLLAMA_URL = "OLLAMA_URL is no longer supported — the query path now embeds "
        .. "in-database via ADAPTER.SEARCH_QDRANT_LOCAL (no Ollama process is required). "
        .. "Drop and re-create the virtual schema without OLLAMA_URL after running "
        .. "scripts/install_all.sql.",
}

--- Creates a new AdapterProperties instance.
-- @param raw table  Raw properties map (string → string), or nil for an empty set.
-- @return AdapterProperties
function AdapterProperties:new(raw)
    local instance = base_props.new(self, raw or {})
    -- Keep our own reference to the raw map for merge semantics.
    instance._raw = raw or {}
    return setmetatable(instance, self)
end

--- Validates that all required properties are present and non-empty,
-- and that no removed properties (e.g. OLLAMA_URL) are present.
-- Raises an error with an actionable message on the first problem found.
function AdapterProperties:validate()
    for key, msg in pairs(REMOVED_PROPERTIES) do
        local val = self:get(key)
        if val ~= nil and val ~= "" then
            error(msg, 2)
        end
    end

    local function require_property(key, hint)
        local val = self:get(key)
        if val == nil or val == "" then
            local err = ("Required virtual schema property '%s' is missing or empty."):format(key)
            if hint then err = err .. " " .. hint end
            error(err, 2)
        end
    end
    require_property(self.CONNECTION_NAME)
    require_property(self.QDRANT_MODEL)
end

--- Returns the value of the named property, or nil if absent.
function AdapterProperties:get(key)
    return self._raw[key]
end

--- Returns the Exasol CONNECTION object name.
function AdapterProperties:get_connection_name()
    return self:get(self.CONNECTION_NAME)
end

--- Returns the embedding model name (informational only — the actual model
-- is hard-coded inside ADAPTER.SEARCH_QDRANT_LOCAL, but this is surfaced in diagnostics).
function AdapterProperties:get_qdrant_model()
    return self:get(self.QDRANT_MODEL)
end

--- Returns the COLLECTION_FILTER value, or nil if not set.
-- Comma-separated list of collection names or glob patterns (e.g. "bank_*,products").
function AdapterProperties:get_collection_filter()
    local val = self:get(self.COLLECTION_FILTER)
    if val and val ~= "" then return val end
    return nil
end

--- Returns an explicit Qdrant URL override, or nil if not set.
-- When nil, the URL is derived from the CONNECTION object address.
function AdapterProperties:get_qdrant_url_override()
    local val = self:get(self.QDRANT_URL)
    if val and val ~= "" then return val end
    return nil
end

--- Merges these properties with new_raw, returning a fresh AdapterProperties.
-- New values override old ones. A new value of "" removes the property.
-- Removed properties (e.g. OLLAMA_URL) raise an error if set to a non-empty
-- value — operators must drop and re-create the virtual schema.
-- @param new_raw table  New property key-value pairs
-- @return AdapterProperties  Merged instance
function AdapterProperties:merge(new_raw)
    for key, msg in pairs(REMOVED_PROPERTIES) do
        local val = new_raw[key]
        if val ~= nil and val ~= "" then
            error(msg, 2)
        end
    end

    local merged = {}
    for k, v in pairs(self._raw) do
        merged[k] = v
    end
    for k, v in pairs(new_raw) do
        if v == "" then
            merged[k] = nil
        else
            merged[k] = v
        end
    end
    return AdapterProperties:new(merged)
end

return AdapterProperties
