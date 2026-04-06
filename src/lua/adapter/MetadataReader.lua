--- MetadataReader: fetches Qdrant collection names and maps them to
-- Virtual Schema table metadata. Contains no query-rewrite logic.

local http = require("util.http")

local MetadataReader = {}
MetadataReader.__index = MetadataReader

-- Column schema shared by every virtual table (matches the Java adapter).
local COLUMNS = {
    {name = "ID",    dataType = {type = "VARCHAR", size = 2000000, characterSet = "UTF8"}},
    {name = "TEXT",  dataType = {type = "VARCHAR", size = 2000000, characterSet = "UTF8"}},
    {name = "SCORE", dataType = {type = "DOUBLE"}},
    {name = "QUERY", dataType = {type = "VARCHAR", size = 2000000, characterSet = "UTF8"}},
}

--- Creates a new MetadataReader.
-- @param qdrant_url         string  Qdrant base URL (no trailing slash)
-- @param api_key            string  Qdrant API key, or "" if not required
-- @param collection_filter  string  Comma-separated list of collection names or
--                                   glob patterns (e.g. "bank_*,products"), or nil for all
function MetadataReader:new(qdrant_url, api_key, collection_filter)
    return setmetatable({
        _qdrant_url        = qdrant_url,
        _api_key           = api_key or "",
        _collection_filter = collection_filter,
    }, self)
end

--- Converts a simple glob pattern (supporting * and ?) to a Lua pattern.
local function _glob_to_pattern(glob)
    local pattern = glob:gsub("([%.%+%-%^%$%(%)%%])", "%%%1")
    pattern = pattern:gsub("%*", ".*")
    pattern = pattern:gsub("%?", ".")
    return "^" .. pattern .. "$"
end

--- Tests whether a collection name matches the filter string.
-- The filter is a comma-separated list of names or glob patterns.
-- Returns true if any pattern matches, or if filter is nil/empty.
function MetadataReader:_matches_filter(name)
    if not self._collection_filter or type(self._collection_filter) ~= "string" or self._collection_filter == "" then
        return true
    end
    for entry in self._collection_filter:gmatch("[^,]+") do
        local pattern = entry:match("^%s*(.-)%s*$")  -- trim whitespace
        if pattern ~= "" then
            local lua_pattern = _glob_to_pattern(pattern)
            if name:match(lua_pattern) then
                return true
            end
        end
    end
    return false
end

--- Reads collection names from Qdrant and returns a list of table metadata tables.
-- Returns an empty list when Qdrant has no collections.
-- Raises an error if the HTTP call fails.
-- If a COLLECTION_FILTER was provided, only matching collections are included.
-- @return table  List of {name=string, columns=list} tables
function MetadataReader:read()
    local headers = {}
    if self._api_key ~= "" then
        headers["api-key"] = self._api_key
    end

    local response = http.get_json(self._qdrant_url .. "/collections", headers)

    local tables = {}
    local collections = (response.result or {}).collections or {}
    for _, col in ipairs(collections) do
        if col.name and self:_matches_filter(col.name) then
            tables[#tables + 1] = {
                name    = col.name:upper(),
                columns = COLUMNS,
            }
        end
    end
    return tables
end

return MetadataReader
