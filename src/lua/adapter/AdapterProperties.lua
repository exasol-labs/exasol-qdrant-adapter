--- Adapter properties for the Qdrant Virtual Schema Lua adapter.
-- Extends exasol.vscl.AdapterProperties with Qdrant-specific property
-- access, validation, and merge semantics.

local base_props = require("exasol.vscl.AdapterProperties")

local AdapterProperties = {}
AdapterProperties.__index = AdapterProperties
setmetatable(AdapterProperties, {__index = base_props})

-- Property key constants
AdapterProperties.CONNECTION_NAME = "CONNECTION_NAME"
AdapterProperties.QDRANT_MODEL    = "QDRANT_MODEL"
AdapterProperties.OLLAMA_URL      = "OLLAMA_URL"
AdapterProperties.QDRANT_URL      = "QDRANT_URL"

local DEFAULT_OLLAMA_URL = "http://localhost:11434"

--- Creates a new AdapterProperties instance.
-- @param raw table  Raw properties map (string → string), or nil for an empty set.
-- @return AdapterProperties
function AdapterProperties:new(raw)
    local instance = base_props.new(self, raw or {})
    -- Keep our own reference to the raw map for merge semantics.
    instance._raw = raw or {}
    return setmetatable(instance, self)
end

--- Validates that all required properties are present and non-empty.
-- Raises an error with an actionable message on the first missing property.
function AdapterProperties:validate()
    local function require_property(key)
        local val = self:get(key)
        if val == nil or val == "" then
            error(("Required virtual schema property '%s' is missing or empty."):format(key), 2)
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

--- Returns the Ollama model name used for embeddings.
function AdapterProperties:get_qdrant_model()
    return self:get(self.QDRANT_MODEL)
end

--- Returns the Ollama base URL, defaulting to http://localhost:11434 if not set.
function AdapterProperties:get_ollama_url()
    local val = self:get(self.OLLAMA_URL)
    if val and val ~= "" then return val end
    return DEFAULT_OLLAMA_URL
end

--- Returns an explicit Qdrant URL override, or nil if not set.
-- When nil, the URL is derived from the CONNECTION object address.
function AdapterProperties:get_qdrant_url_override()
    local val = self:get(self.QDRANT_URL)
    if val and val ~= "" then return val end
    return nil
end

--- Merges these properties with new_raw, returning a fresh AdapterProperties.
-- New values override old ones. A new value of "" removes the property
-- (it will revert to its default or fail validation if required).
-- @param new_raw table  New property key-value pairs
-- @return AdapterProperties  Merged instance
function AdapterProperties:merge(new_raw)
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
