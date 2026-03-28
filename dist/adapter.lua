do
local _ENV = _ENV
package.preload[ "adapter.AdapterProperties" ] = function( ... ) local arg = _G.arg;
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
end
end

do
local _ENV = _ENV
package.preload[ "adapter.MetadataReader" ] = function( ... ) local arg = _G.arg;
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
end
end

do
local _ENV = _ENV
package.preload[ "adapter.QdrantAdapter" ] = function( ... ) local arg = _G.arg;
--- QdrantAdapter: the main Virtual Schema adapter for Qdrant.
-- Inherits from AbstractVirtualSchemaAdapter (virtual-schema-common-lua).
-- Implements the full VS lifecycle: createVirtualSchema, refresh,
-- setProperties, pushDown, getCapabilities.

local AbstractVSAdapter = require("exasol.vscl.AbstractVirtualSchemaAdapter")
local AdapterProperties = require("adapter.AdapterProperties")
local MetadataReader    = require("adapter.MetadataReader")
local QueryRewriter     = require("adapter.QueryRewriter")
local capabilities_mod  = require("adapter.capabilities")

local QdrantAdapter = {}
QdrantAdapter.__index = QdrantAdapter
setmetatable(QdrantAdapter, {__index = AbstractVSAdapter})

-- ─────────────────────────────────────────────
-- Constructor

--- Creates a new QdrantAdapter instance.
function QdrantAdapter:new()
    local instance = AbstractVSAdapter.new(self)
    return setmetatable(instance, self)
end

-- ─────────────────────────────────────────────
-- Capability declaration

function QdrantAdapter:_define_capabilities()
    -- EXCLUDED_CAPABILITIES is handled inside capabilities_mod.create().
    -- Properties are not yet available at capability-declaration time,
    -- so we always return the full set here; exclusions are handled per-request.
    return capabilities_mod.create(nil)
end

-- ─────────────────────────────────────────────
-- Lifecycle methods

--- Handles createVirtualSchema: validate props, read Qdrant metadata, return schema.
function QdrantAdapter:create_virtual_schema(request)
    local props = self:_load_properties(request)
    props:validate()
    local tables = self:_read_metadata(props)
    return {schemaMetadata = {tables = tables}}
end

--- Handles refresh: re-read Qdrant collections and return updated schema metadata.
function QdrantAdapter:refresh(request)
    local props = self:_load_properties(request)
    props:validate()
    local tables = self:_read_metadata(props)
    return {schemaMetadata = {tables = tables}}
end

--- Handles setProperties: merge old+new props, validate, re-read metadata.
-- Returns the updated schema so Exasol keeps its catalog in sync.
function QdrantAdapter:set_properties(request)
    local old_props = self:_load_properties(request)
    local new_raw   = (request.properties or {})
    local merged    = old_props:merge(new_raw)
    merged:validate()
    local tables = self:_read_metadata(merged)
    return {schemaMetadata = {tables = tables}}
end

--- Handles pushDown: embed the query via Ollama, search Qdrant, return VALUES SQL.
function QdrantAdapter:push_down(request)
    local props = self:_load_properties(request)
    props:validate()

    local qdrant_url, api_key = self:_resolve_connection(props)
    local ollama_url = props:get_ollama_url()
    local model      = props:get_qdrant_model()

    local rewriter = QueryRewriter:new(qdrant_url, ollama_url, model, api_key)
    local sql = rewriter:rewrite(request)
    return {sql = sql}
end

--- Handles dropVirtualSchema: no-op, nothing to clean up.
function QdrantAdapter:drop_virtual_schema(_request)
    return {}
end

-- ─────────────────────────────────────────────
-- Private helpers

--- Builds an AdapterProperties instance from the request's schemaMetadataInfo.
function QdrantAdapter:_load_properties(request)
    local info = request.schemaMetadataInfo or {}
    return AdapterProperties:new(info.properties or {})
end

--- Resolves the Qdrant base URL and API key from properties / CONNECTION object.
-- Uses the QDRANT_URL override when set; otherwise reads ADDRESS from the
-- Exasol CONNECTION object. API key comes from the CONNECTION object PASSWORD.
-- @return qdrant_url string, api_key string
function QdrantAdapter:_resolve_connection(props)
    local conn_name = props:get_connection_name()
    local conn      = exa.get_connection(conn_name)

    local url = props:get_qdrant_url_override() or conn.address
    -- Strip trailing slash for consistent URL construction.
    url = url:gsub("/$", "")

    local api_key = conn.password or ""
    return url, api_key
end

--- Reads Qdrant collections and returns table metadata list.
function QdrantAdapter:_read_metadata(props)
    local qdrant_url, api_key = self:_resolve_connection(props)
    return MetadataReader:new(qdrant_url, api_key):read()
end

return QdrantAdapter
end
end

do
local _ENV = _ENV
package.preload[ "adapter.QueryRewriter" ] = function( ... ) local arg = _G.arg;
--- QueryRewriter: embeds a query string via Ollama, searches Qdrant for
-- similar vectors, and returns a VALUES-based SELECT statement that
-- Exasol can materialise as a result set.

local http = require("util.http")

local QueryRewriter = {}
QueryRewriter.__index = QueryRewriter

local DEFAULT_LIMIT = 10

--- Creates a new QueryRewriter.
-- @param qdrant_url  string  Qdrant base URL (no trailing slash)
-- @param ollama_url  string  Ollama base URL (no trailing slash)
-- @param model       string  Ollama model name for embeddings
-- @param api_key     string  Qdrant API key, or "" if not required
function QueryRewriter:new(qdrant_url, ollama_url, model, api_key)
    return setmetatable({
        _qdrant_url = qdrant_url,
        _ollama_url = ollama_url,
        _model      = model,
        _api_key    = api_key or "",
    }, self)
end

--- Rewrites a push-down request to a SQL string.
-- @param request table  Parsed pushDown request (from virtual-schema-common-lua)
-- @return string        SQL suitable for the pushDown response
function QueryRewriter:rewrite(request)
    local collection = self:_extract_collection(request)
    local query_text = self:_extract_query_text(request)
    local limit      = self:_extract_limit(request)

    local embedding = self:_embed(query_text)
    local results   = self:_search(collection, embedding, limit)

    return self:_build_sql(query_text, results)
end

-- ─────────────────────────────────────────────
-- Request parsing helpers

function QueryRewriter:_extract_collection(request)
    local tables = request.involvedTables or {}
    if not tables[1] then
        error("pushDown request contains no involved tables")
    end
    -- Qdrant collection names are lowercase; virtual table names are uppercase.
    return tables[1].name:lower()
end

function QueryRewriter:_extract_query_text(request)
    local push = request.pushDownRequest or {}
    if not push.filter then return "" end
    return self:_walk_filter(push.filter) or ""
end

--- Walks the filter AST looking for QUERY = '<literal>' (or '<literal>' = QUERY).
function QueryRewriter:_walk_filter(node)
    if not node then return nil end
    if node.type == "predicate_equal" then
        local left  = node.left  or {}
        local right = node.right or {}
        -- QUERY = 'text'
        if left.type == "column" and left.name and left.name:upper() == "QUERY"
           and right.type == "literal_string" then
            return right.value
        end
        -- 'text' = QUERY
        if right.type == "column" and right.name and right.name:upper() == "QUERY"
           and left.type == "literal_string" then
            return left.value
        end
    end
    return nil
end

function QueryRewriter:_extract_limit(request)
    local push = request.pushDownRequest or {}
    if push.limit and push.limit.numElements then
        return tonumber(push.limit.numElements) or DEFAULT_LIMIT
    end
    return DEFAULT_LIMIT
end

-- ─────────────────────────────────────────────
-- HTTP calls

--- Calls Ollama /api/embeddings and returns the embedding float array.
function QueryRewriter:_embed(query_text)
    local url = self._ollama_url .. "/api/embeddings"
    local response = http.post_json(url, {
        model  = self._model,
        prompt = query_text,
    })
    local embedding = response.embedding
    if not embedding or type(embedding) ~= "table" then
        error("Ollama response missing 'embedding' array for model '" .. self._model .. "'")
    end
    return embedding
end

--- Serialises a float array from a cjson-decoded table into a JSON array string.
-- cjson.encode on a sub-table decoded from another cjson.decode call can
-- produce {} instead of [...].  Building the string manually is reliable.
local function embedding_to_json(embedding)
    local keys = {}
    for k, _ in pairs(embedding) do
        if type(k) == "number" then keys[#keys + 1] = k end
    end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do parts[#parts + 1] = tostring(embedding[k]) end
    if #parts == 0 then error("embedding array is empty after serialisation") end
    return "[" .. table.concat(parts, ",") .. "]"
end

--- Calls Qdrant /collections/{name}/points/query and returns result rows.
function QueryRewriter:_search(collection, vector, limit)
    local url = string.format("%s/collections/%s/points/query",
                              self._qdrant_url, collection)
    local headers = {}
    if self._api_key ~= "" then
        headers["api-key"] = self._api_key
    end

    local body = string.format(
        '{"query":%s,"using":"text","limit":%d,"with_payload":true}',
        embedding_to_json(vector), limit
    )
    local response = http.post_raw(url, body, headers)

    local rows = {}
    for _, point in ipairs((response.result or {}).points or {}) do
        local payload = point.payload or {}
        rows[#rows + 1] = {
            id    = tostring(payload._original_id or point.id or ""),
            text  = tostring(payload.text or ""),
            score = tonumber(point.score) or 0.0,
        }
    end
    return rows
end

-- ─────────────────────────────────────────────
-- SQL builders

local function sql_escape(s)
    return (s or ""):gsub("'", "''")
end

--- Builds the push-down SQL for non-empty results (VALUES clause).
-- For zero results, returns an empty-result query that preserves column types.
function QueryRewriter:_build_sql(query_text, results)
    if #results == 0 then
        return "SELECT"
            .. " CAST('' AS VARCHAR(36) UTF8) AS ID,"
            .. " CAST('' AS VARCHAR(2000000) UTF8) AS TEXT,"
            .. " CAST(0 AS DOUBLE) AS SCORE,"
            .. " CAST('' AS VARCHAR(2000000) UTF8) AS QUERY"
            .. " FROM DUAL WHERE FALSE"
    end

    local rows = {}
    local q = sql_escape(query_text)
    for _, r in ipairs(results) do
        rows[#rows + 1] = string.format(
            "(CAST('%s' AS VARCHAR(2000000) UTF8),"
            .. "CAST('%s' AS VARCHAR(2000000) UTF8),"
            .. "CAST(%s AS DOUBLE),"
            .. "CAST('%s' AS VARCHAR(2000000) UTF8))",
            sql_escape(r.id),
            sql_escape(r.text),
            tostring(r.score),
            q
        )
    end

    return "SELECT * FROM VALUES " .. table.concat(rows, ",") .. " AS t(ID, TEXT, SCORE, QUERY)"
end

return QueryRewriter
end
end

do
local _ENV = _ENV
package.preload[ "adapter.capabilities" ] = function( ... ) local arg = _G.arg;
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
end
end

do
local _ENV = _ENV
package.preload[ "util.http" ] = function( ... ) local arg = _G.arg;
--- HTTP utility module for the Qdrant Virtual Schema Lua adapter.
-- Provides JSON GET and POST helpers built on LuaSocket (bundled in Exasol).
-- All functions return a decoded Lua table on success and raise an error on failure.

local socket_http = require("socket.http")
local ltn12       = require("ltn12")
local cjson       = require("cjson")

local M = {}

--- Executes an HTTP request and returns (status_code, body_string).
-- @param opts table passed directly to socket.http.request
local function do_request(opts)
    local chunks = {}
    opts.sink = ltn12.sink.table(chunks)
    local _, code, _ = socket_http.request(opts)
    local body = table.concat(chunks)
    if type(code) ~= "number" then
        error("HTTP request to " .. (opts.url or "?") .. " failed: " .. tostring(code))
    end
    return code, body
end

--- Makes an HTTP GET request and returns the decoded JSON response body.
-- @param url     string  Full URL to GET
-- @param headers table   Optional extra headers (e.g. {"api-key": "..."})
-- @return table  Decoded JSON response
function M.get_json(url, headers)
    local code, body = do_request({
        url     = url,
        method  = "GET",
        headers = headers or {},
    })
    if code >= 400 then
        error(string.format("HTTP GET %s returned %d: %s", url, code, body))
    end
    return cjson.decode(body)
end

--- Makes an HTTP POST request with a JSON-encoded payload.
-- @param url     string  Full URL to POST to
-- @param payload table   Lua table to encode as JSON body
-- @param headers table   Optional extra headers merged with Content-Type/Content-Length
-- @return table  Decoded JSON response
function M.post_json(url, payload, headers)
    local body    = cjson.encode(payload)
    local req_headers = headers or {}
    req_headers["Content-Type"]   = "application/json"
    req_headers["Content-Length"] = tostring(#body)

    local code, resp_body = do_request({
        url     = url,
        method  = "POST",
        headers = req_headers,
        source  = ltn12.source.string(body),
    })
    if code >= 400 then
        error(string.format("HTTP POST %s returned %d: %s", url, code, resp_body))
    end
    return cjson.decode(resp_body)
end

--- Makes an HTTP POST request with a pre-encoded string body.
-- Use this when the body must be built manually (e.g. to avoid cjson
-- encoding a decoded sub-table as {} instead of [...]).
-- @param url     string  Full URL to POST to
-- @param body    string  Already-encoded request body
-- @param headers table   Optional extra headers merged with Content-Type/Content-Length
-- @return table  Decoded JSON response
function M.post_raw(url, body, headers)
    local req_headers = headers or {}
    req_headers["Content-Type"]   = "application/json"
    req_headers["Content-Length"] = tostring(#body)

    local code, resp_body = do_request({
        url     = url,
        method  = "POST",
        headers = req_headers,
        source  = ltn12.source.string(body),
    })
    if code >= 400 then
        error(string.format("HTTP POST %s returned %d: %s", url, code, resp_body))
    end
    return cjson.decode(resp_body)
end

return M
end
end

--- Thin entrypoint for the Qdrant Virtual Schema Lua adapter.
-- Defines the global adapter_call() function required by Exasol.
-- Contains no business logic — all requests are delegated to RequestDispatcher.

local QdrantAdapter    = require("adapter.QdrantAdapter")
local AdapterProperties = require("adapter.AdapterProperties")
local RequestDispatcher = require("exasol.vscl.RequestDispatcher")

function adapter_call(request_json)
    local adapter    = QdrantAdapter:new()
    local properties = AdapterProperties:new()
    local dispatcher = RequestDispatcher:new(adapter, properties)
    return dispatcher:adapter_call(request_json)
end
