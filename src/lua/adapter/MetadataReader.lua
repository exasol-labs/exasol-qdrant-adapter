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
-- @param qdrant_url string  Qdrant base URL (no trailing slash)
-- @param api_key    string  Qdrant API key, or "" if not required
function MetadataReader:new(qdrant_url, api_key)
    return setmetatable({
        _qdrant_url = qdrant_url,
        _api_key    = api_key or "",
    }, self)
end

--- Reads collection names from Qdrant and returns a list of table metadata tables.
-- Returns an empty list when Qdrant has no collections.
-- Raises an error if the HTTP call fails.
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
        if col.name then
            tables[#tables + 1] = {
                name    = col.name:upper(),
                columns = COLUMNS,
            }
        end
    end
    return tables
end

return MetadataReader
