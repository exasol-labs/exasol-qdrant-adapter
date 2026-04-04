-- Exasol's built-in require() ignores package.preload. Patch it so that
-- amalg-bundled modules are found before falling back to the original loader.
local _original_require = require
require = function(modname)
    if package.loaded[modname] then return package.loaded[modname] end
    local preload_fn = package.preload[modname]
    if preload_fn then
        local ok, result = pcall(preload_fn, modname)
        if not ok then
            error("Failed loading bundled module [" .. modname .. "]: " .. tostring(result), 2)
        end
        package.loaded[modname] = result == nil and true or result
        return package.loaded[modname]
    end
    return _original_require(modname)
end
do
local _ENV = _ENV
package.preload[ "ExaError" ] = function( ... ) local arg = _G.arg;
--- This class provides a uniform way to define errors in a Lua application.
-- @classmod ExaError
local ExaError = {
    VERSION = "2.0.1",
}
ExaError.__index = ExaError

local MessageExpander = require("MessageExpander")

-- Lua 5.1 backward compatibility
-- luacheck: push ignore 122
if not table.unpack then table.unpack = _G.unpack end
-- luacheck: pop

local function expand(message, parameters)
    return MessageExpander:new(message, parameters):expand()
end

--- Convert error to a string representation.
-- Note that `__tostring` is the metamethod called by Lua's global `tostring` function.
-- This allows using the error message in places where Lua expects a string.
-- @return string representation of the error object
function ExaError:__tostring()
    local lines = {}
    if self._code then
        if self._message then
            table.insert(lines, self._code .. ": " .. self:get_message())
        else
            table.insert(lines, self._code)
        end
    else
        if self._message then
            table.insert(lines, self:get_message())
        else
            table.insert(lines, "<Missing error message. This should not happen. Please contact the software maker.>")
        end
    end
    if (self._mitigations ~= nil) and (#self._mitigations > 0) then
        table.insert(lines, "\nMitigations:\n")
        for _, mitigation in ipairs(self._mitigations) do
            table.insert(lines, "* " .. expand(mitigation, self._parameters))
        end
    end
    return table.concat(lines, "\n")
end

--- Concatenate an error object with another object.
-- @return String representing the concatenation.
function ExaError.__concat(left, right)
    return tostring(left) .. tostring(right)
end

--- Create a new instance of an error message.
-- @param code error code
-- @param message error message, optionally with placeholders
-- @param[opt={}] parameters parameter definitions used to replace the placeholders
-- @param[opt={}] mitigations mitigations users can try to solve the error
-- @return created object
function ExaError:new(code, message, parameters, mitigations)
    local instance = setmetatable({}, self)
    instance:_init(code, message, parameters, mitigations)
    return instance
end

function ExaError:_init(code, message, parameters, mitigations)
    self._code = code
    self._message = message
    self._parameters = parameters or {}
    self._mitigations = mitigations or {}
end

--- Add mitigations.
-- @param ... one or more mitigation descriptions
-- @return error message object
function ExaError:add_mitigations(...)
    for _, mitigation in ipairs({...}) do
        table.insert(self._mitigations, mitigation)
    end
    return self
end

--- Add issue ticket mitigation
-- This is a special kind of mitigation which you should use in case of internal software errors that should not happen.
-- For example when a path in the code is reached that should be unreachable if the code is correct.
-- @return error message object
function ExaError:add_ticket_mitigation()
    table.insert(self._mitigations,
        "This is an internal software error. Please report it via the project's ticket tracker.")
    return self
end

--- Get the error code.
-- @return error code
function ExaError:get_code()
    return self._code
end

--- Get the error message.
-- Placeholders in the raw message are replaced by the parameters given when building the error message object.
-- For fault tolerance, this method returns the raw message in case the parameters are missing.
-- @return error message
function ExaError:get_message()
    return expand(self._message, self._parameters)
end

function ExaError:get_raw_message()
    return self._message or ""
end

--- Get parameter definitions.
-- @return parameter defintions
function ExaError:get_parameters()
    return self._parameters
end

--- Get the description of a parameter.
-- @param parameter_name name of the parameter
-- @return parameter description or the string "`<missing parameter description>`"
function ExaError:get_parameter_description(parameter_name)
    return self._parameters[parameter_name].description or "<missing parameter description>"
end

--- Get the mitigations for the error.
-- @return list of mitigations
function ExaError:get_mitigations()
    return table.unpack(self._mitigations)
end

--- Raise the error.
-- Like in Lua's `error` function, you can optionally specify if and from which level down the stack trace
-- is included in the error message.
-- <ul>
-- <li>0: no stack trace</li>
-- <li>1: stack trace starts at the point inside `exaerror` where the error is raised
-- <li>2: stack trace starts at the calling function (default)</li>
-- <li>3+: stack trace starts below the calling function</li>
-- </ul>
-- @param level (optional) level from which down the stack trace will be displayed
-- @raise Lua error for the given error object
function ExaError:raise(level)
    level = (level == nil) and 2 or level
    error(tostring(self), level)
end

--- Raise an error that represents the error object's contents.
-- @param code error code
-- @param message error message, optionally with placeholders
-- @param[opt={}] parameters parameter definitions used to replace the placeholders
-- @param[opt={}] mitigations mitigations users can try to solve the error
-- @see M.create
-- @see M:new
-- @raise Lua error for the given error object
function ExaError.error(code, message, parameters, mitigations)
     ExaError:new(code, message, parameters, mitigations):raise()
end

return ExaError
end
end

do
local _ENV = _ENV
package.preload[ "MessageExpander" ] = function( ... ) local arg = _G.arg;
--- This class provides a parser for messages with named parameters and can expand the message using the parameter
-- values.
-- @classmod MessageExpander
local MessageExpander = {}
MessageExpander.__index = MessageExpander

local FROM_STATE_INDEX = 1
local GUARD_INDEX = 2
local ACTION_INDEX = 3
local TO_STATE_INDEX = 4

--- Create a new instance of a message expander.
-- @param message to be expanded
-- @param parameters parameter definitions
-- @return message expander instance
function MessageExpander:new(message, parameters)
    local instance = setmetatable({}, self)
    instance:_init(message, parameters)
    return instance
end

function MessageExpander:_init(message, parameters)
    self._message = message
    self._parameters = parameters
    self._tokens = {}
    self._last_parameter = {characters = {}, quote = true}
end

local function tokenize(text)
    return string.gmatch(text, ".")
end

--- Expand the message.
-- Note that if no parameter values are supplied, the message will be returned as is, without any replacements.
-- @return expanded message
function MessageExpander:expand()
    if (self._parameters == nil) or (not next(self._parameters)) then
        return self._message
    else
        self:_run()
    end
    return table.concat(self._tokens)
end

function MessageExpander:_run()
    self.state = "TEXT"
    local token_iterator = tokenize(self._message)
    for token in token_iterator do
        self.state = self:_transit(token)
    end
end

function MessageExpander:_transit(token)
    for _, transition in ipairs(MessageExpander._transitions) do
        local from_state = transition[FROM_STATE_INDEX]
        local guard = transition[GUARD_INDEX]
        if(from_state == self.state and guard(token)) then
            local action = transition[ACTION_INDEX]
            action(self, token)
            local to_state = transition[TO_STATE_INDEX]
            return to_state
        end
    end
end

local function is_any()
    return true
end

local function is_opening_bracket(token)
    return token == "{"
end

local function is_closing_bracket(token)
    return token == "}"
end

-- We are intentionally not using the symbol itself here for compatibility reasons.
-- See https://github.com/exasol/error-reporting-lua/issues/15 for details.
local function is_pipe(token)
    return token == string.char(124)
end

local function is_u(token)
    return token == "u"
end

local function is_not_bracket(token)
    return not is_opening_bracket(token) and not is_closing_bracket(token)
end

local function add_token(self, token)
    table.insert(self._tokens, token)
end

local function add_open_plus_token(self, token)
    table.insert(self._tokens, "{")
    table.insert(self._tokens, token)
end

local function add_parameter_name(self, token)
    table.insert(self._last_parameter.characters, token)
end

local function set_unquoted(self)
    self._last_parameter.quote = false
end

local function unwrap_parameter_value(parameter)
    if parameter ~= nil and type(parameter) == "table" then
        return parameter.value
    else
        return parameter
    end
end

local function insert_parameter_value_into_token_list(self, value)
    if value == nil then
        table.insert(self._tokens, "<missing value>")
    else
        local type = type(value)
        if (type == "string") and (self._last_parameter.quote) then
            table.insert(self._tokens, "'")
            table.insert(self._tokens, value)
            table.insert(self._tokens, "'")
        elseif type == "boolean" then
            table.insert(self._tokens, tostring(value))
        elseif type == "table" or type == "thread" or type == "userdata" then
            table.insert(self._tokens, "<")
            table.insert(self._tokens, tostring(value))
            table.insert(self._tokens, ">")
        else
            table.insert(self._tokens, value)
        end
    end
end

local function replace_parameter(self)
    local parameter_name = table.concat(self._last_parameter.characters)
    local value = unwrap_parameter_value(self._parameters[parameter_name])
    insert_parameter_value_into_token_list(self, value)
    self._last_parameter.characters = {}
    self._last_parameter.quote = true
end

local function replace_and_add(self, token)
    replace_parameter(self)
    add_token(self, token)
end

local function do_nothing() end

MessageExpander._transitions = {
    {"TEXT"     , is_not_bracket    , add_token          , "TEXT"     },
    {"TEXT"     , is_opening_bracket, do_nothing         , "OPEN_1"   },
    {"OPEN_1"   , is_opening_bracket, do_nothing         , "PARAMETER"},
    {"OPEN_1"   , is_any            , add_open_plus_token, "TEXT"     },
    {"PARAMETER", is_closing_bracket, do_nothing         , "CLOSE_1"  },
    {"PARAMETER", is_pipe           , do_nothing         , "SWITCH"   },
    {"PARAMETER", is_any            , add_parameter_name , "PARAMETER"},
    {"SWITCH"   , is_closing_bracket, do_nothing         , "CLOSE_1"  },
    {"SWITCH"   , is_u              , set_unquoted       , "SWITCH"   },
    {"SWITCH"   , is_any            , do_nothing         , "SWITCH"   },
    {"CLOSE_1"  , is_closing_bracket, replace_parameter  , "TEXT"     },
    {"CLOSE_1"  , is_any            , replace_and_add    , "TEXT"     }
}

return MessageExpander
end
end

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
local CAPABILITIES      = require("adapter.capabilities")

local QdrantAdapter = {}
QdrantAdapter.__index = QdrantAdapter
setmetatable(QdrantAdapter, {__index = AbstractVSAdapter})

-- ─────────────────────────────────────────────
-- Constructor

--- Creates a new QdrantAdapter instance.
function QdrantAdapter:new()
    local instance = setmetatable({}, self)
    instance:_init()
    return instance
end

-- ─────────────────────────────────────────────
-- Adapter identity (required by RequestDispatcher for logging)

function QdrantAdapter:get_name()
    return "Exasol Qdrant Virtual Schema"
end

function QdrantAdapter:get_version()
    return "1.0.0"
end

-- ─────────────────────────────────────────────
-- Capability declaration

function QdrantAdapter:_define_capabilities()
    return CAPABILITIES
end

-- ─────────────────────────────────────────────
-- Lifecycle methods

--- Handles createVirtualSchema: validate props, read Qdrant metadata, return schema.
function QdrantAdapter:create_virtual_schema(request)
    local props = self:_load_properties(request)
    props:validate()
    local tables = self:_read_metadata(props)
    return {type = "createVirtualSchema", schemaMetadata = {tables = tables}}
end

--- Handles refresh: re-read Qdrant collections and return updated schema metadata.
function QdrantAdapter:refresh(request)
    local props = self:_load_properties(request)
    props:validate()
    local tables = self:_read_metadata(props)
    return {type = "refresh", schemaMetadata = {tables = tables}}
end

--- Handles setProperties: merge old+new props, validate, re-read metadata.
-- Returns the updated schema so Exasol keeps its catalog in sync.
function QdrantAdapter:set_properties(request)
    local old_props = self:_load_properties(request)
    local new_raw   = (request.properties or {})
    local merged    = old_props:merge(new_raw)
    merged:validate()
    local tables = self:_read_metadata(merged)
    return {type = "setProperties", schemaMetadata = {tables = tables}}
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
    return {type = "pushdown", sql = sql}
end

--- Handles dropVirtualSchema: no-op, nothing to clean up.
function QdrantAdapter:drop_virtual_schema(_request)
    return {type = "dropVirtualSchema"}
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
    local push = request.pushdownRequest or {}
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
    local push = request.pushdownRequest or {}
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
    if not embedding or type(embedding) ~= "table" or #embedding == 0 then
        error("Ollama returned no embedding for model '" .. self._model .. "'")
    end
    return embedding
end

--- Serialises a float array from a cjson-decoded table into a JSON array string.
local function embedding_to_json(embedding)
    local n = #embedding
    if n == 0 then
        -- Diagnostic: check actual table contents
        local info = "len=" .. tostring(n) .. " type=" .. type(embedding)
        local cnt = 0
        for k, _ in pairs(embedding) do cnt = cnt + 1 end
        info = info .. " pairs_count=" .. cnt
        if cnt > 0 then
            for k, v in pairs(embedding) do
                info = info .. " sample_k=" .. tostring(k) .. "(" .. type(k) .. ")"
                break
            end
        end
        error("embedding array is empty: " .. info)
    end
    local parts = {}
    for i = 1, n do parts[i] = tostring(embedding[i]) end
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
-- Returns a plain list of capability name strings as expected by the
-- virtual-schema-common-lua framework (AbstractVirtualSchemaAdapter).
-- EXCLUDED_CAPABILITIES is handled by the base class's get_capabilities().

local CAPABILITIES = {
    "SELECTLIST_EXPRESSIONS",
    "FILTER_EXPRESSIONS",
    "LIMIT",
    "LIMIT_WITH_OFFSET",
    "FN_PRED_EQUAL",
    "LITERAL_STRING",
}

return CAPABILITIES
end
end

do
local _ENV = _ENV
package.preload[ "exasol.vscl.AbstractVirtualSchemaAdapter" ] = function( ... ) local arg = _G.arg;
--- This class implements an abstract base adapter with common behavior for some of the request callback functions.
--
-- When you derive a concrete adapter from this base class, we recommend keeping it stateless. This makes
-- parallelization easier, reduces complexity and saves you the trouble of cleaning up in the drop-virtual-schema
-- request.
--
-- [impl -> dsn~lua-virtual-schema-adapter-abstraction~0]
--
---@class AbstractVirtualSchemaAdapter
local AbstractVirtualSchemaAdapter = {}

local ExaError = require("ExaError")

function AbstractVirtualSchemaAdapter:_init()
    -- Intentionally empty
end

local function raise_abstract_method_call_error(method_name)
    ExaError:new("E-VSCL-8", "Attempted to call the abstract method AbstractVirtualSchemaAdapter:{{method|u}}.",
                 {method = {value = method_name, description = "abstract method that was called"}})
            :add_ticket_mitigation():raise()
end

--- Get the adapter name.
---@return string adapter_name name of the adapter
function AbstractVirtualSchemaAdapter:get_name()
    raise_abstract_method_call_error("get_name")
end

--- Get the adapter version.
---@return string version version of the adapter
function AbstractVirtualSchemaAdapter:get_version()
    raise_abstract_method_call_error("get_version")
end

--- Define the list of all capabilities this adapter supports.
-- Override this method in derived adapter class. Note that this differs from `get_capabilities` because
-- the later takes exclusions defined by the user into consideration.
---@return string[] capabilities list of all capabilities supported by this adapter
function AbstractVirtualSchemaAdapter:_define_capabilities()
    raise_abstract_method_call_error("_define_capabilities")
end

--- Create the Virtual Schema.
-- Create the virtual schema and provide the corresponding metadata.
---@param _request any virtual schema request
---@param _properties any user-defined properties
---@return any response metadata representing the structure and datatypes of the data source from Exasol's point of view
function AbstractVirtualSchemaAdapter:create_virtual_schema(_request, _properties)
    raise_abstract_method_call_error("create_virtual_schema")
end
--- Set new adapter properties.
-- This request provides two sets of user-defined properties. The old ones (i.e. the ones that where set before this
-- request) and the properties that the user changed.
-- A new property with a key that is not present in the old set of properties means the user added a new property.
-- New properties with existing keys override or unset existing properties. An unset property contains the special
-- value `AdapterProperties.null`.
---@param _request any virtual schema request
---@param _old_properties any old user-defined properties
---@param _new_properties any new user-defined properties
---@return any response same response as if you created a new Virtual Schema
function AbstractVirtualSchemaAdapter:set_properties(_request, _old_properties, _new_properties)
    raise_abstract_method_call_error("set_properties'")
end

--- Refresh the Virtual Schema.
-- This method reevaluates the metadata (structure and data types) that represents the data source.
---@param _request any virtual schema request
---@param _properties any user-defined properties
---@return any response same response as if you created a new Virtual Schema
function AbstractVirtualSchemaAdapter:refresh(_request, _properties)
    raise_abstract_method_call_error("refresh")
end

---@param original_capabilities string[]
---@param excluded_capabilities string[]
---@return string[]
-- [impl -> dsn~excluding-capabilities~0]
local function subtract_capabilities(original_capabilities, excluded_capabilities)
    local filtered_capabilities = {}
    for _, capability in ipairs(original_capabilities) do
        local is_excluded = false
        for _, excluded_capability in ipairs(excluded_capabilities) do
            if excluded_capability == capability then
                is_excluded = true
            end
        end
        if not is_excluded then
            table.insert(filtered_capabilities, capability)
        end
    end
    return filtered_capabilities
end

--- Get the adapter capabilities.
-- The basic `get_capabilities` handler in this class will out-of-the-box fit all derived adapters with the
-- rare exception of those that decide on capabilities at runtime depending on for example the version number of the
-- remote data source.
---@param _request any virtual schema request
---@param properties any user-defined properties
---@return table<string, any> capabilities list of non-excluded adapter capabilities
function AbstractVirtualSchemaAdapter:get_capabilities(_request, properties)
    if properties:has_excluded_capabilities() then
        return {
            type = "getCapabilities",
            capabilities = subtract_capabilities(self:_define_capabilities(), properties:get_excluded_capabilities())
        }
    else
        return {type = "getCapabilities", capabilities = self:_define_capabilities()}
    end
end

--- Push a query down to the data source
---@param _request any virtual schema request
---@param _properties any user-defined properties
---@return string rewritten_query rewritten query to be executed by the ExaLoader (`IMPORT`), value providing query
-- `SELECT ... FROM VALUES`, not recommended) or local Exasol query (`SELECT`).
function AbstractVirtualSchemaAdapter:push_down(_request, _properties)
    raise_abstract_method_call_error("push_down")
end

--- Drop the virtual schema.
-- Override this method to implement clean-up if the adapter is not stateless.
---@param _request any virtual schema request (not used)
---@param _properties any user-defined properties
---@return any response response confirming the request (otherwise empty)
function AbstractVirtualSchemaAdapter:drop_virtual_schema(_request, _properties)
    return {type = "dropVirtualSchema"}
end

return AbstractVirtualSchemaAdapter
end
end

do
local _ENV = _ENV
package.preload[ "exasol.vscl.AdapterProperties" ] = function( ... ) local arg = _G.arg;
--- This class abstracts access to the user-defined properties of the Virtual Schema.
---@class AdapterProperties
---@field _raw_properties table<string, string>
local AdapterProperties = {null = {}}
AdapterProperties.__index = AdapterProperties

local text = require("exasol.vscl.text")
local ExaError = require("ExaError")

local EXCLUDED_CAPABILITIES_PROPERTY<const> = "EXCLUDED_CAPABILITIES"
local LOG_LEVEL_PROPERTY<const> = "LOG_LEVEL"
local DEBUG_ADDRESS_PROPERTY<const> = "DEBUG_ADDRESS"
local DEFAULT_LOG_PORT<const> = 3000

--- Create a new instance of adapter properties.
---@param raw_properties table<string, string> properties as key-value pairs
---@return AdapterProperties properties new instance
function AdapterProperties:new(raw_properties)
    local instance = setmetatable({}, self)
    instance:_init(raw_properties)
    return instance
end

function AdapterProperties:_init(raw_properties)
    self._raw_properties = raw_properties
end

--- Get the class of the object
---@return table class
function AdapterProperties:class()
    return AdapterProperties
end

--- Get the value of a property.
---@param property_name string name of the property to get
---@return string property_value
function AdapterProperties:get(property_name)
    return self._raw_properties[property_name]
end

--- Check if the property is set.
---@param property_name string name of the property to check
---@return boolean property_set `true` if the property is set (i.e. not `nil`)
function AdapterProperties:is_property_set(property_name)
    return self:get(property_name) ~= nil
end

--- Check if the property has a non-empty value.
---@param property_name string name of the property to check
---@return boolean has_value `true` if the property has a non-empty value (i.e. not `nil` or an empty string)
function AdapterProperties:has_value(property_name)
    local value = self:get(property_name)
    return value ~= nil and value ~= ""
end

--- Check if the property value is empty.
---@param property_name string name of the property to check
---@return boolean is_empty `true` if the property's value is empty (i.e. the property is set to an empty string)
function AdapterProperties:is_empty(property_name)
    return self:get(property_name) == ""
end

--- Check if the property contains the string `true` (case-sensitive).
---@param property_name string name of the property to check
---@return boolean is_true `true` if the property's value is the string `true`
function AdapterProperties:is_true(property_name)
    return self:get(property_name) == "true"
end

--- Check if the property evaluates to `false`.
---@param property_name string name of the property to check
---@return boolean is_false `true` if the property's value is anything else than the string `true`
function AdapterProperties:is_false(property_name)
    return not self:is_true(property_name)
end

function AdapterProperties:_validate_debug_address()
    if self:has_value(DEBUG_ADDRESS_PROPERTY) then
        local address = self:get(DEBUG_ADDRESS_PROPERTY)
        if not string.match(address, "^.-:[0-9]+$") then
            ExaError:new("F-VSCL-PROP-3", "Expected log address in " .. DEBUG_ADDRESS_PROPERTY
                                 .. " to look like '<ip>|<host>[:<port>]', but got {{address}} instead",
                         {address = address}):add_mitigations("Provide an valid IP address or host name")
                    :add_mitigations("Make sure host/ip and port number are separated by a colon"):add_mitigations(
                            "Optionally add a port number (default is 3000)"):add_mitigations(
                            "Don't add any whitespace characters"):raise(0)
        end
    end
end

function AdapterProperties:_validate_log_level()
    if self:has_value(LOG_LEVEL_PROPERTY) then
        local level = self:get_log_level()
        local allowed_levels = {"FATAL", "ERROR", "WARNING", "INFO", "CONFIG", "DEBUG", "TRACE"}
        local found = false
        for _, allowed in ipairs(allowed_levels) do
            if level == allowed then
                found = true
                break
            end
        end
        if not found then
            ExaError:new("F-VSCL-PROP-2", "Unknown log level {{level}} in " .. LOG_LEVEL_PROPERTY .. " property",
                         {level = level}):add_mitigations("Pick one of: " .. table.concat(allowed_levels, ", "))
                    :raise(0)
        end
    end
end

function AdapterProperties:_validate_excluded_capabilities()
    if self:has_value(EXCLUDED_CAPABILITIES_PROPERTY) then
        local value = self:get(EXCLUDED_CAPABILITIES_PROPERTY)
        if not string.match(value, "^[ A-Za-z0-9_,]*$") then
            ExaError:new("F-VSCL-PROP-1",
                         "Invalid character(s) in " .. EXCLUDED_CAPABILITIES_PROPERTY .. " property: {{value}}",
                         {value = value}):add_mitigations(
                    "Use only the following characters: ASCII letter, digit, underscore, comma, space"):raise(0)
        end
    end
end

--- Validate the adapter properties.
---@raise validation error
function AdapterProperties:validate()
    self:_validate_debug_address()
    self:_validate_log_level()
    self:_validate_excluded_capabilities()
end

--- Validate a boolean property.
---Allowed values are `true`, `false` or an unset variable.
---@raise validation error
function AdapterProperties:validate_boolean(property_name)
    local value = self:get(property_name)
    if not (value == nil or value == "true" or value == "false") then
        ExaError:new("F-VSCL-PROP-4", "Property '" .. property_name .. "' contains an illegal value: '" .. value .. "'")
                :add_mitigations("Either leave the property unset or choose one of 'true', 'false' (case-sensitive).")
                :raise(0)
    end
end

--- Get the log level
---@return string log_level
function AdapterProperties:get_log_level()
    return self:get(LOG_LEVEL_PROPERTY)
end

--- Check if the log level is set
---@return boolean has_log_level `true` if the log level is set
function AdapterProperties:has_log_level()
    return self:has_value(LOG_LEVEL_PROPERTY)
end

--- Get the list of names of the excluded capabilities.
---@return string[]? excluded_capabilities
function AdapterProperties:get_excluded_capabilities()
    return text.split(self:get(EXCLUDED_CAPABILITIES_PROPERTY))
end

--- Check if excluded capabilities are set
---@return boolean has_excluded_capabilities `true` if the excluded capabilities are set
function AdapterProperties:has_excluded_capabilities()
    return self:has_value(EXCLUDED_CAPABILITIES_PROPERTY)
end

--- Get the debug address (host and port)
---@return string? host, integer? port or `nil` if the property has no value
function AdapterProperties:get_debug_address()
    if self:has_value(DEBUG_ADDRESS_PROPERTY) then
        local debug_address = self:get(DEBUG_ADDRESS_PROPERTY)
        local colon_position = string.find(debug_address, ":", 1, true)
        if colon_position == nil then
            return debug_address, DEFAULT_LOG_PORT
        else
            local host = string.sub(debug_address, 1, colon_position - 1)
            local port = math.tointeger(tonumber(string.sub(debug_address, colon_position + 1)))
            return host, port
        end
    else
        return nil, nil
    end
end

--- Check if log address is set
---@return boolean has_debug_address `true` if the log address is set
function AdapterProperties:has_debug_address()
    return self:has_value(DEBUG_ADDRESS_PROPERTY)
end

--- Merge new properties into a set of existing ones
---@param new_properties AdapterProperties set of new properties to merge into the existing ones
---@return AdapterProperties merge_product
-- [impl -> dsn~merging-user-defined-properties~0]
function AdapterProperties:merge(new_properties)
    local merged_list = {}
    for key, value in pairs(new_properties._raw_properties) do
        if (value ~= nil) and (value ~= AdapterProperties.null) then
            merged_list[key] = value
        end
    end
    for key, value in pairs(self._raw_properties) do
        if new_properties._raw_properties[key] == nil then
            merged_list[key] = value
        end
    end
    local merged_properties = self:class():new(merged_list)
    return merged_properties
end

--- Create a string representation
---@return string string_representation
function AdapterProperties:__tostring()
    local keys = {}
    local i = 0
    for key, _ in pairs(self._raw_properties) do
        i = i + 1
        keys[i] = key
    end
    table.sort(keys)
    local str = {"("}
    for _, key in ipairs(keys) do
        if (#str > 1) then
            str[#str + 1] = ", "
        end
        str[#str + 1] = key
        str[#str + 1] = " = "
        str[#str + 1] = self._raw_properties[key]
    end
    str[#str + 1] = ")"
    return table.concat(str)
end

return AdapterProperties
end
end

do
local _ENV = _ENV
package.preload[ "exasol.vscl.ImportQueryBuilder" ] = function( ... ) local arg = _G.arg;
--- Builder for an IMPORT query that wraps push-down query
---@class ImportQueryBuilder
---@field _column_types ExasolTypeDefinition[]
---@field _source_type SourceType default: "EXA"
---@field _connection string
---@field _statement SelectSqlStatement
local ImportQueryBuilder = {}
ImportQueryBuilder.__index = ImportQueryBuilder

--- Create a new instance of an `ImportQueryBuilder`.
---@return ImportQueryBuilder new_instance new query builder
function ImportQueryBuilder:new()
    local instance = setmetatable({}, self)
    instance:_init()
    return instance
end

function ImportQueryBuilder:_init()
    -- intentionally empty
    self._source_type = "EXA"
end

--- Set the result set column data types.
---@param column_types ExasolTypeDefinition[] column types as list of data type structures
---@return ImportQueryBuilder self for fluent programming
function ImportQueryBuilder:column_types(column_types)
    self._column_types = column_types
    return self
end

--- Set the source type to one of `EXA`, `JDBC`, `ORA`. Default: `EXA`.
---@param source_type SourceType type of the source from which to import
---@return ImportQueryBuilder self for fluent programming
function ImportQueryBuilder:source_type(source_type)
    self._source_type = source_type
    return self
end

--- Set the connection.
---@param connection string connection over which the remote query should be run
---@return ImportQueryBuilder self for fluent programming
function ImportQueryBuilder:connection(connection)
    self._connection = connection
    return self
end

--- Set the push-down statement.
---@param statement SelectSqlStatement push-down statement to be wrapped by the `IMPORT` statement.
---@return ImportQueryBuilder self for fluent programming
function ImportQueryBuilder:statement(statement)
    self._statement = statement
    return self
end

--- Build the `IMPORT` query structure.
---@return ImportSqlStatement import_statement that represents the `IMPORT` statement
function ImportQueryBuilder:build()
    return {
        type = "import",
        into = self._column_types,
        source_type = self._source_type,
        connection = self._connection,
        statement = self._statement
    }
end

return ImportQueryBuilder

---@alias SourceType "EXA"|"JDBC"|"ORA"
end
end

do
local _ENV = _ENV
package.preload[ "exasol.vscl.Query" ] = function( ... ) local arg = _G.arg;
---@alias Token string|number
--- This class implements an abstraction for a query string including its tokens.
---@class Query
---@field _tokens Token[]
local Query = {}
Query.__index = Query

--- Create a new instance of a `Query`.
---@param tokens Token[]? list of tokens that make up the query
---@return Query query_object
function Query:new(tokens)
    local instance = setmetatable({}, self)
    instance:_init(tokens)
    return instance
end

---@param tokens Token[]?
function Query:_init(tokens)
    self._tokens = tokens or {}
end

--- Append a single token.
--- While the same can be achieved with calling `append_all` with a single parameter, this method is faster.
---@param token Token token to append
function Query:append(token)
    self._tokens[#self._tokens + 1] = token
end

--- Append all tokens.
---@param ... Token tokens to append
function Query:append_all(...)
    for _, token in ipairs(table.pack(...)) do
        self._tokens[#self._tokens + 1] = token
    end
end

--- Get the tokens this query consists of
---@return Token[] tokens
function Query:get_tokens()
    return self._tokens
end

--- Return the whole query as string.
---@return string query query as string
function Query:to_string()
    return table.concat(self._tokens)
end

return Query
end
end

do
local _ENV = _ENV
package.preload[ "exasol.vscl.QueryRenderer" ] = function( ... ) local arg = _G.arg;
--- Renderer for SQL queries.
---@class QueryRenderer
---@field _original_query QueryStatement
---@field _appender_config AppenderConfig
local QueryRenderer = {}
QueryRenderer.__index = QueryRenderer

local Query = require("exasol.vscl.Query")
local SelectAppender = require("exasol.vscl.queryrenderer.SelectAppender")
local ImportAppender = require("exasol.vscl.queryrenderer.ImportAppender")

--- Create a new query renderer.
---@param original_query QueryStatement query structure as provided through the Virtual Schema API
---@param appender_config AppenderConfig configuration for the query renderer containing identifier quoting
---@return QueryRenderer query_renderer instance
function QueryRenderer:new(original_query, appender_config)
    local instance = setmetatable({}, self)
    instance:_init(original_query, appender_config)
    return instance
end

---@param original_query QueryStatement query structure as provided through the Virtual Schema API
---@param appender_config AppenderConfig configuration for the query renderer containing identifier quoting
function QueryRenderer:_init(original_query, appender_config)
    self._original_query = original_query
    self._appender_config = appender_config
end

---@param query QueryStatement
---@return ImportAppender|SelectAppender
local function get_appender_class(query)
    if query.type == "import" then
        return ImportAppender
    else
        return SelectAppender
    end
end

--- Render the query to a string.
---@return string rendered_query query as string
function QueryRenderer:render()
    local out_query = Query:new()
    local appender_class = get_appender_class(self._original_query)
    local appender = appender_class:new(out_query, self._appender_config)
    appender:append(self._original_query)
    return out_query:to_string()
end

return QueryRenderer
end
end

do
local _ENV = _ENV
package.preload[ "exasol.vscl.RequestDispatcher" ] = function( ... ) local arg = _G.arg;
--- This class dispatches Virtual Schema requests to a Virtual Schema adapter.
-- It is independent of the use case of the VS adapter and offers functionality that each Virtual Schema needs, like
-- JSON decoding and encoding and setting up remote logging.
-- To use the dispatcher, you need to inject the concrete adapter the dispatcher should send the prepared requests to.
---@class RequestDispatcher
---@field _adapter AbstractVirtualSchemaAdapter
---@field _properties_reader AdapterProperties
local RequestDispatcher = {}
RequestDispatcher.__index = RequestDispatcher
local TRUNCATE_ERRORS_AFTER<const> = 3000

local log = require("remotelog")
local cjson = require("cjson")
local ExaError = require("ExaError")

--- Create a new `RequestDispatcher`.
---@param adapter AbstractVirtualSchemaAdapter adapter that receives the dispatched requests
---@param properties_reader AdapterProperties properties reader
---@return RequestDispatcher dispatcher_instance
function RequestDispatcher:new(adapter, properties_reader)
    assert(adapter ~= nil, "Request Dispatcher requires an adapter to dispatch too")
    local instance = setmetatable({}, self)
    instance:_init(adapter, properties_reader)
    return instance
end

---@param adapter AbstractVirtualSchemaAdapter adapter that receives the dispatched requests
---@param properties_reader AdapterProperties properties reader
function RequestDispatcher:_init(adapter, properties_reader)
    self._adapter = adapter
    self._properties_reader = properties_reader or require("exasol.vscl.AdapterProperties")
    -- Replace the `cjson` null object to decouple the adapter properties from the `cjson` library.
    cjson.null = properties_reader.null
end

-- [impl -> dsn~dispatching-push-down-requests~0]
-- [impl -> dsn~dispatching-create-virtual-schema-requests~0]
-- [impl -> dsn~dispatching-drop-virtual-schema-requests~0]
-- [impl -> dsn~dispatching-refresh-requests~0]
-- [impl -> dsn~dispatching-get-capabilities-requests~0]
-- [impl -> dsn~dispatching-set-properties-requests~0]
function RequestDispatcher:_handle_request(request, properties)
    local handlers = {
        pushdown = self._adapter.push_down,
        createVirtualSchema = self._adapter.create_virtual_schema,
        dropVirtualSchema = self._adapter.drop_virtual_schema,
        refresh = self._adapter.refresh,
        getCapabilities = self._adapter.get_capabilities,
        setProperties = self._adapter.set_properties
    }
    log.info('Received "%s" request.', request.type)
    local handler = handlers[request.type]
    if (handler ~= nil) then
        if request.type == "setProperties" then
            local new_properties = self:_extract_new_properties(request)
            return handler(self._adapter, request, properties, new_properties)
        else
            return handler(self._adapter, request, properties)
        end
    else
        ExaError:new("F-RQD-1", "Unknown Virtual Schema request type {{request_type}} received.",
                     {request_type = request.type}):add_ticket_mitigation():raise(0)
    end
end

local function log_error(message)
    local error_type = string.sub(message, 1, 2)
    if error_type == "F-" then
        log.fatal(message)
    else
        log.error(message)
    end
end

local function handle_error(message)
    if string.len(message) > TRUNCATE_ERRORS_AFTER then
        message = string.sub(message, 1, TRUNCATE_ERRORS_AFTER) .. "\n... (error message truncated after "
                          .. TRUNCATE_ERRORS_AFTER .. " characters)"
    end
    log_error(message)
    return message
end

-- [impl -> dsn~reading-user-defined-properties~0]
function RequestDispatcher:_extract_properties(request)
    local raw_properties = (request.schemaMetadataInfo or {}).properties or {}
    return self._properties_reader:new(raw_properties)
end

-- The "set properties" request contains the new properties in the `properties` element directly under the root element.
function RequestDispatcher:_extract_new_properties(request)
    local raw_properties = request.properties or {}
    return self._properties_reader:new(raw_properties)
end

function RequestDispatcher:_init_logging(properties)
    log.set_client_name(self._adapter:get_name() .. " " .. self._adapter:get_version())
    if properties:has_log_level() then
        log.set_level(string.upper(properties:get_log_level()))
    end
    local host, port = properties:get_debug_address()
    if host then
        log.connect(host, port)
    end
end

---
-- RLS adapter entry point.
-- <p>
-- This global function receives the request from the Exasol core database.
-- </p>
--
---@param request_as_json string JSON-encoded adapter request
--
---@return string response JSON-encoded adapter response
--
-- [impl -> dsn~translating-json-request-to-lua-tables~0]
-- [impl -> dsn~translating-lua-tables-to-json-responses~0]
function RequestDispatcher:adapter_call(request_as_json)
    local request = cjson.decode(request_as_json)
    local properties = self:_extract_properties(request)
    self:_init_logging(properties)
    log.debug("Raw request:\n%s", request_as_json)
    local ok, result = xpcall(RequestDispatcher._handle_request, handle_error, self, request, properties)
    if ok then
        local response = cjson.encode(result)
        log.debug("Response:\n" .. response)
        log.disconnect()
        return response
    else
        log.disconnect()
        error(result)
    end
end

return RequestDispatcher
end
end

do
local _ENV = _ENV
package.preload[ "exasol.vscl.queryrenderer.AbstractQueryAppender" ] = function( ... ) local arg = _G.arg;
--- This class is the abstract base class of all query renderers.
--- It takes care of handling the temporary storage of the query to be constructed.
---@class AbstractQueryAppender
---@field _out_query Query query object that the appender appends to
---@field _appender_config AppenderConfig configuration for the query renderer (e.g. containing identifier quoting)
local AbstractQueryAppender = {}

local DEFAULT_IDENTIFIER_QUOTE<const> = '"'

---@type AppenderConfig Default configuration with double quotes for identifiers.
AbstractQueryAppender.DEFAULT_APPENDER_CONFIG = {identifier_quote = DEFAULT_IDENTIFIER_QUOTE}

local ExaError = require("ExaError")

---Initializes the query appender and verifies that all parameters are set.
---Raises an error if any of the parameters is missing.
---@param out_query Query query object that the appender appends to
---@param appender_config AppenderConfig configuration for the query renderer (e.g. containing identifier quoting)
function AbstractQueryAppender:_init(out_query, appender_config)
    assert(out_query ~= nil, "AbstractQueryAppender requires a query object that it can append to.")
    assert(appender_config ~= nil, "AbstractQueryAppender requires an appender configuration.")
    self._out_query = out_query
    self._appender_config = appender_config
end

--- Append a token to the query.
---@param token Token token to append
function AbstractQueryAppender:_append(token)
    self._out_query:append(token)
end

--- Append a list of tokens to the query.
---@param ... Token to append
function AbstractQueryAppender:_append_all(...)
    self._out_query:append_all(...)
end

---Append a comma in a comma-separated list where needed.
---Appends a comma if the list index is greater than one.
---@param index integer position in the comma-separated list
function AbstractQueryAppender:_comma(index)
    if index > 1 then
        self:_append(", ")
    end
end

---@param data_type DecimalTypeDefinition
function AbstractQueryAppender:_append_decimal_type_details(data_type)
    self:_append("(")
    self:_append(data_type.precision)
    self:_append(",")
    self:_append(data_type.scale)
    self:_append(")")
end

---@param data_type CharacterTypeDefinition
function AbstractQueryAppender:_append_character_type(data_type)
    self:_append("(")
    self:_append(data_type.size)
    self:_append(")")
    local character_set = data_type.characterSet
    if character_set then
        self:_append(" ")
        self:_append(character_set)
    end
end

---@param data_type TimestampTypeDefinition
function AbstractQueryAppender:_append_timestamp(data_type)
    if data_type.withLocalTimeZone then
        self:_append(" WITH LOCAL TIME ZONE")
    end
end

---@param data_type GeometryTypeDefinition
function AbstractQueryAppender:_append_geometry(data_type)
    local srid = data_type.srid
    if srid then
        self:_append("(")
        self:_append(srid)
        self:_append(")")
    end
end

---@param data_type IntervalTypeDefinition
function AbstractQueryAppender:_append_interval(data_type)
    if data_type.fromTo == "DAY TO SECONDS" then
        self:_append(" DAY")
        local precision = data_type.precision
        if precision then
            self:_append("(")
            self:_append(precision)
            self:_append(")")
        end
        self:_append(" TO SECOND")
        local fraction = data_type.fraction
        if fraction then
            self:_append("(")
            self:_append(fraction)
            self:_append(")")
        end
    else
        self:_append(" YEAR")
        local precision = data_type.precision
        if precision then
            self:_append("(")
            self:_append(precision)
            self:_append(")")
        end
        self:_append(" TO MONTH")
    end
end

---@param data_type HashtypeTypeDefinition
function AbstractQueryAppender:_append_hashtype(data_type)
    local byte_size = data_type.bytesize
    if byte_size then
        self:_append("(")
        self:_append(byte_size)
        self:_append(" BYTE)")
    end
end

---@param data_type ExasolTypeDefinition
function AbstractQueryAppender:_append_data_type(data_type)
    local type = data_type.type
    self:_append(type)
    if type == "DECIMAL" then
        self:_append_decimal_type_details(data_type)
    elseif type == "VARCHAR" or type == "CHAR" then
        self:_append_character_type(data_type)
    elseif type == "TIMESTAMP" then
        self:_append_timestamp(data_type)
    elseif type == "GEOMETRY" then
        self:_append_geometry(data_type)
    elseif type == "INTERVAL" then
        self:_append_interval(data_type)
    elseif type == "HASHTYPE" then
        self:_append_hashtype(data_type)
    elseif type == "DOUBLE" or type == "DATE" or type == "BOOLEAN" then
        return
    else
        ExaError:new("E-VSCL-4", "Unable to render unknown data type {{type}}.",
                     {type = {value = type, description = "data type that was not recognized"}}):add_ticket_mitigation()
                :raise()
    end
end

--- Append a string literal and enclose it in single quotes
---@param literal string string literal
function AbstractQueryAppender:_append_string_literal(literal)
    self:_append("'")
    self:_append(literal)
    self:_append("'")
end

---Append a quoted identifier, e.g. a schema, table or column name.
---@param identifier string identifier
function AbstractQueryAppender:_append_identifier(identifier)
    local quote_char = self._appender_config.identifier_quote or DEFAULT_IDENTIFIER_QUOTE
    self:_append(quote_char)
    self:_append(identifier)
    self:_append(quote_char)
end

return AbstractQueryAppender

---@class AppenderConfig
---@field identifier_quote string? quote character for identifiers, defaults to `"`
end
end

do
local _ENV = _ENV
package.preload[ "exasol.vscl.queryrenderer.AggregateFunctionAppender" ] = function( ... ) local arg = _G.arg;
--- Appender for aggregate functions in an SQL statement.
---@class AggregateFunctionAppender: AbstractQueryAppender
local AggregateFunctionAppender = {}
AggregateFunctionAppender.__index = AggregateFunctionAppender
local AbstractQueryAppender = require("exasol.vscl.queryrenderer.AbstractQueryAppender")
setmetatable(AggregateFunctionAppender, {__index = AbstractQueryAppender})

local ExpressionAppender = require("exasol.vscl.queryrenderer.ExpressionAppender")
local SelectAppender = require("exasol.vscl.queryrenderer.SelectAppender")
local ExaError = require("ExaError")

--- Create a new instance of a `AggregateFunctionAppender`.
---@param out_query Query query to which the function will be appended
---@param appender_config AppenderConfig
---@return AggregateFunctionAppender renderer for aggregate functions
function AggregateFunctionAppender:new(out_query, appender_config)
    local instance = setmetatable({}, self)
    instance:_init(out_query, appender_config)
    return instance
end

---@param out_query Query
---@param appender_config AppenderConfig
function AggregateFunctionAppender:_init(out_query, appender_config)
    AbstractQueryAppender._init(self, out_query, appender_config)
end

--- Append an aggregate function to an SQL query.
---@param aggregate_function AggregateFunctionExpression function to append
function AggregateFunctionAppender:append_aggregate_function(aggregate_function)
    local function_name = string.lower(aggregate_function.name)
    local implementation = AggregateFunctionAppender["_" .. function_name]
    if implementation ~= nil then
        implementation(self, aggregate_function)
    else
        ExaError:new("E-VSCL-3", "Unable to render unsupported aggregate function type {{function_name}}.", {
            function_name = {value = function_name, description = "name of the SQL function that is not yet supported"}
        }):add_ticket_mitigation():raise()
    end
end

-- Alias for main appender function for uniform appender invocation
AggregateFunctionAppender.append = AggregateFunctionAppender.append_aggregate_function

---@param expression Expression
function AggregateFunctionAppender:_append_expression(expression)
    local expression_renderer = ExpressionAppender:new(self._out_query, self._appender_config)
    expression_renderer:append_expression(expression)
end

function AggregateFunctionAppender:_append_function_argument_list(distinct, arguments)
    self:_append("(")
    self:_append_distinct_modifier(distinct)
    self:_append_comma_separated_arguments(arguments)
    self:_append(")")
end

function AggregateFunctionAppender:_append_distinct_modifier(distinct)
    if distinct then
        self:_append("DISTINCT ")
    end
end

function AggregateFunctionAppender:_append_comma_separated_arguments(arguments)
    if (arguments) then
        for i = 1, #arguments do
            self:_comma(i)
            self:_append_expression(arguments[i])
        end
    end
end

function AggregateFunctionAppender:_append_distinct_function(f)
    self:_append(string.upper(f.name))
    local distinct = f.distinct or false
    self:_append_function_argument_list(distinct, f.arguments)
end

function AggregateFunctionAppender:_append_simple_function(f)
    assert(not f.distinct, "Aggregate function '" .. (f.name or "unknown") .. "' must not have a DISTINCT modifier.")
    self:_append(string.upper(f.name))
    self:_append_function_argument_list(false, f.arguments)
end

-- AggregateFunctionAppender._any is not implemented since ANY is an alias for SOME
AggregateFunctionAppender._approximate_count_distinct = AggregateFunctionAppender._append_simple_function
AggregateFunctionAppender._avg = AggregateFunctionAppender._append_distinct_function
AggregateFunctionAppender._corr = AggregateFunctionAppender._append_simple_function
AggregateFunctionAppender._covar_pop = AggregateFunctionAppender._append_simple_function
AggregateFunctionAppender._covar_samp = AggregateFunctionAppender._append_simple_function

function AggregateFunctionAppender:_count(f)
    local distinct = f.distinct or false
    if (f.arguments == nil or next(f.arguments) == nil) then
        self:_append("COUNT(*)")
    elseif (#f.arguments == 1) then
        self:_append("COUNT")
        self:_append_function_argument_list(distinct, f.arguments)
    else
        self:_append("COUNT(")
        self:_append_distinct_modifier(distinct)
        -- Note the extra set of parenthesis that is required to count tuples!
        self:_append("(")
        self:_append_comma_separated_arguments(f.arguments)
        self:_append("))")
    end
end

AggregateFunctionAppender._every = AggregateFunctionAppender._append_distinct_function
AggregateFunctionAppender._first_value = AggregateFunctionAppender._append_simple_function

---@return SelectAppender
function AggregateFunctionAppender:_select_appender()
    return SelectAppender:new(self._out_query, self._appender_config)
end

function AggregateFunctionAppender:_group_concat(f)
    self:_append(string.upper(f.name))
    self:_append("(")
    if f.distinct then
        self:_append("DISTINCT ")
    end
    self:_append_comma_separated_arguments(f.arguments)
    if f.orderBy then
        self:_select_appender():_append_order_by(f.orderBy)
    end
    if f.separator then
        self:_append(" SEPARATOR ")
        self:_append_string_literal(f.separator)
    end
    self:_append(")")
end

AggregateFunctionAppender._grouping = AggregateFunctionAppender._append_simple_function
AggregateFunctionAppender._grouping_id = AggregateFunctionAppender._grouping
AggregateFunctionAppender._last_value = AggregateFunctionAppender._append_simple_function

function AggregateFunctionAppender:_listagg(f)
    self:_append("LISTAGG(")
    if f.distinct then
        self:_append("DISTINCT ")
    end
    self:_append_expression(f.arguments[1])
    if f.separator then
        self:_append(", ")
        self:_append_expression(f.separator)
    end
    local overflow = f.overflowBehavior
    if overflow then
        if overflow.type == "ERROR" then
            self:_append(" ON OVERFLOW ERROR")
        elseif overflow.type == "TRUNCATE" then
            self:_append(" ON OVERFLOW TRUNCATE")
            if overflow.truncationFiller then
                self:_append(" ")
                self:_append_expression(overflow.truncationFiller)
            end
            self:_append((overflow.truncationType == "WITH COUNT") and " WITH COUNT" or " WITHOUT COUNT")
        end
    end
    self:_append(")")
    if f.orderBy then
        self:_append(" WITHIN GROUP (")
        self:_select_appender():_append_order_by(f.orderBy, true)
        self:_append(")")
    end
end

AggregateFunctionAppender._max = AggregateFunctionAppender._append_distinct_function
AggregateFunctionAppender._median = AggregateFunctionAppender._append_simple_function
AggregateFunctionAppender._min = AggregateFunctionAppender._append_distinct_function
AggregateFunctionAppender._mul = AggregateFunctionAppender._append_distinct_function
AggregateFunctionAppender._regr_avgx = AggregateFunctionAppender._append_simple_function
AggregateFunctionAppender._regr_avgy = AggregateFunctionAppender._append_simple_function
AggregateFunctionAppender._regr_count = AggregateFunctionAppender._append_simple_function
AggregateFunctionAppender._regr_intercept = AggregateFunctionAppender._append_simple_function
AggregateFunctionAppender._regr_r2 = AggregateFunctionAppender._append_simple_function
AggregateFunctionAppender._regr_slope = AggregateFunctionAppender._append_simple_function
AggregateFunctionAppender._regr_sxx = AggregateFunctionAppender._append_simple_function
AggregateFunctionAppender._regr_sxy = AggregateFunctionAppender._append_simple_function
AggregateFunctionAppender._regr_syy = AggregateFunctionAppender._append_simple_function
AggregateFunctionAppender._st_intersection = AggregateFunctionAppender._append_simple_function
AggregateFunctionAppender._st_union = AggregateFunctionAppender._append_simple_function
AggregateFunctionAppender._stddev = AggregateFunctionAppender._append_distinct_function
AggregateFunctionAppender._stddev_pop = AggregateFunctionAppender._append_distinct_function
AggregateFunctionAppender._stddev_samp = AggregateFunctionAppender._append_distinct_function
AggregateFunctionAppender._sum = AggregateFunctionAppender._append_distinct_function
AggregateFunctionAppender._some = AggregateFunctionAppender._append_distinct_function
AggregateFunctionAppender._var_pop = AggregateFunctionAppender._append_distinct_function
AggregateFunctionAppender._var_samp = AggregateFunctionAppender._append_distinct_function
AggregateFunctionAppender._variance = AggregateFunctionAppender._append_distinct_function

return AggregateFunctionAppender
end
end

do
local _ENV = _ENV
package.preload[ "exasol.vscl.queryrenderer.ExpressionAppender" ] = function( ... ) local arg = _G.arg;
--- Appender for value expressions in a SQL query.
---@class ExpressionAppender: AbstractQueryAppender
local ExpressionAppender = {}
ExpressionAppender.__index = ExpressionAppender
local AbstractQueryAppender = require("exasol.vscl.queryrenderer.AbstractQueryAppender")
setmetatable(ExpressionAppender, {__index = AbstractQueryAppender})

local text = require("exasol.vscl.text")
local ExaError = require("ExaError")

local OPERATORS<const> = {
    predicate_equal = "=",
    predicate_notequal = "<>",
    predicate_less = "<",
    predicate_greater = ">",
    predicate_lessequal = "<=",
    predicate_greaterequal = ">=",
    predicate_between = "BETWEEN",
    predicate_is_not_null = "IS NOT NULL",
    predicate_is_null = "IS NULL",
    predicate_like = "LIKE",
    predicate_like_regexp = "REGEXP_LIKE",
    predicate_and = "AND",
    predicate_or = "OR",
    predicate_not = "NOT",
    predicate_is_json = "IS JSON",
    predicate_is_not_json = "IS NOT JSON"
}

---@param predicate_type string
---@return string
local function get_predicate_operator(predicate_type)
    local operator = OPERATORS[predicate_type]
    if operator ~= nil then
        return operator
    else
        ExaError:new("E-VSCL-7", "Cannot determine operator for unknown predicate type {{type}}.",
                     {type = {value = predicate_type, description = "predicate type that was not recognized"}})
                :add_ticket_mitigation():raise()
    end
end

--- Create a new instance of an `ExpressionRenderer`.
---@param out_query Query query that the rendered tokens should be appended too
---@param appender_config AppenderConfig
---@return ExpressionAppender expression_renderer new expression appender
function ExpressionAppender:new(out_query, appender_config)
    local instance = setmetatable({}, self)
    instance:_init(out_query, appender_config)
    return instance
end

---@param out_query Query
---@param appender_config AppenderConfig
function ExpressionAppender:_init(out_query, appender_config)
    AbstractQueryAppender._init(self, out_query, appender_config)
end

---@param column ColumnReference
function ExpressionAppender:_append_column_reference(column)
    self:_append_identifier(column.tableName)
    self:_append('.')
    self:_append_identifier(column.name)
end

---@param sub_select ExistsPredicate
function ExpressionAppender:_append_exists(sub_select)
    self:_append("EXISTS(")
    require("exasol.vscl.queryrenderer.SelectAppender"):new(self._out_query, self._appender_config):append_select(
            sub_select.query)
    self:_append(")")
end

---@param predicate UnaryPredicate
function ExpressionAppender:_append_unary_predicate(predicate)
    self:_append("(")
    self:_append(get_predicate_operator(predicate.type))
    self:_append(" ")
    self:append_expression(predicate.expression)
    self:_append(")")
end

---@param predicate BinaryPredicateExpression
function ExpressionAppender:_append_binary_predicate(predicate)
    self:_append("(")
    self:append_expression(predicate.left)
    self:_append(" ")
    self:_append(get_predicate_operator(predicate.type))
    self:_append(" ")
    self:append_expression(predicate.right)
    self:_append(")")
end

---@param predicate IteratedPredicate
function ExpressionAppender:_append_iterated_predicate(predicate)
    self:_append("(")
    local expressions = predicate.expressions
    for i = 1, #expressions do
        if i > 1 then
            self:_append(" ")
            self:_append(get_predicate_operator(predicate.type))
            self:_append(" ")
        end
        self:append_expression(expressions[i])
    end
    self:_append(")")
end

---@param predicate InPredicate
function ExpressionAppender:_append_predicate_in(predicate)
    self:_append("(")
    self:append_expression(predicate.expression)
    self:_append(" IN (")
    local arguments = predicate.arguments
    for i = 1, #arguments do
        self:_comma(i)
        self:append_expression(arguments[i])
    end
    self:_append("))")
end

---@param predicate LikePredicate
function ExpressionAppender:_append_predicate_like(predicate)
    self:_append("(")
    self:append_expression(predicate.expression)
    self:_append(" LIKE ")
    self:append_expression(predicate.pattern)
    local escape = predicate.escapeChar
    if escape then
        self:_append(" ESCAPE ")
        self:append_expression(escape)
    end
    self:_append(")")
end

---@param predicate LikeRegexpPredicate
function ExpressionAppender:_append_predicate_regexp_like(predicate)
    self:_append("(")
    self:append_expression(predicate.expression)
    self:_append(" REGEXP_LIKE ")
    self:append_expression(predicate.pattern)
    self:_append(")")
end

---@param predicate PostfixPredicate
function ExpressionAppender:_append_postfix_predicate(predicate)
    self:_append("(")
    self:append_expression(predicate.expression)
    self:_append(" ")
    self:_append(get_predicate_operator(predicate.type))
    self:_append(")")
end

---@param predicate BetweenPredicate
function ExpressionAppender:_append_between(predicate)
    self:_append("(")
    self:append_expression(predicate.expression)
    self:_append(" BETWEEN ")
    self:append_expression(predicate.left)
    self:_append(" AND ")
    self:append_expression(predicate.right)
    self:_append(")")
end

---@param predicate JsonPredicate
function ExpressionAppender:_append_predicate_is_json(predicate)
    self:append_expression(predicate.expression)
    self:_append(" ")
    self:_append(get_predicate_operator(predicate.type))
    local typeConstraint = predicate.typeConstraint
    if typeConstraint == "VALUE" then
        self:_append(" VALUE")
    elseif typeConstraint == "ARRAY" then
        self:_append(" ARRAY")
    elseif typeConstraint == "OBJECT" then
        self:_append(" OBJECT")
    elseif typeConstraint == "SCALAR" then
        self:_append(" SCALAR")
    end
    local keyUniquenessConstraint = predicate.keyUniquenessConstraint
    if (keyUniquenessConstraint == "WITH UNIQUE KEYS") or (keyUniquenessConstraint == "WITHOUT UNIQUE KEYS") then
        self:_append(" ")
        self:_append(keyUniquenessConstraint)
    end
end

--- Append a predicate to a query.
-- This method is public to allow nesting predicates in filters.
---@param predicate PredicateExpression predicate to append
function ExpressionAppender:append_predicate(predicate)
    local type = string.sub(predicate.type, 11)
    if type == "equal" or type == "notequal" or type == "greater" or type == "less" or type == "lessequal" or type
            == "greaterequal" then
        self:_append_binary_predicate(predicate)
    elseif type == "like" then
        self:_append_predicate_like(predicate)
    elseif type == "like_regexp" then
        self:_append_predicate_regexp_like(predicate)
    elseif type == "is_null" or type == "is_not_null" then
        self:_append_postfix_predicate(predicate)
    elseif type == "between" then
        self:_append_between(predicate)
    elseif type == "not" then
        self:_append_unary_predicate(predicate)
    elseif type == "and" or type == "or" then
        self:_append_iterated_predicate(predicate)
    elseif type == "in_constlist" then
        self:_append_predicate_in(predicate)
    elseif type == "exists" then
        self:_append_exists(predicate)
    elseif type == "is_json" or type == "is_not_json" then
        self:_append_predicate_is_json(predicate)
    else
        ExaError:new("E-VSCL-2", "Unable to render unknown SQL predicate type {{type}}.",
                     {type = {value = predicate.type, description = "predicate type that was not recognized"}})
                :add_ticket_mitigation():raise()
    end
end

---@param literal_expression StringBasedLiteral
function ExpressionAppender:_append_quoted_literal_expression(literal_expression)
    self:_append("'")
    self:_append(literal_expression.value)
    self:_append("'")
end

--- Append an expression to a query.
---@param expression Expression to append
function ExpressionAppender:append_expression(expression)
    local type = expression.type
    if type == "column" then
        self:_append_column_reference(expression)
    elseif type == "literal_null" then
        self:_append("null")
    elseif type == "literal_bool" then
        self:_append(expression.value and "true" or "false")
    elseif (type == "literal_exactnumeric") or (type == "literal_double") then
        self:_append(expression.value)
    elseif type == "literal_string" then
        self:_append_quoted_literal_expression(expression)
    elseif type == "literal_date" then
        self:_append("DATE ")
        self:_append_quoted_literal_expression(expression)
    elseif (type == "literal_timestamp") or (type == "literal_timestamputc") then
        self:_append("TIMESTAMP ")
        self:_append_quoted_literal_expression(expression)
    elseif type == "literal_interval" then
        self:_append("INTERVAL ")
        self:_append_quoted_literal_expression(expression)
        self:_append_interval(expression.dataType)
    elseif text.starts_with(type, "function_scalar") then
        require("exasol.vscl.queryrenderer.ScalarFunctionAppender"):new(self._out_query, self._appender_config):append(
                expression)
    elseif text.starts_with(type, "function_aggregate") then
        require("exasol.vscl.queryrenderer.AggregateFunctionAppender"):new(self._out_query, self._appender_config)
                :append(expression)
    elseif text.starts_with(type, "predicate_") then
        self:append_predicate(expression)
    elseif type == "sub_select" then
        require("exasol.vscl.queryrenderer.SelectAppender"):new(self._out_query, self._appender_config)
                :append_sub_select(expression)
    else
        ExaError:new("E-VSCL-1", "Unable to render unknown SQL expression type {{type}}.",
                     {type = {value = expression.type, description = "expression type provided"}})
                :add_ticket_mitigation():raise(3)
    end
end

-- Alias for main appender function to allow uniform appender calls from the outside
ExpressionAppender.append = ExpressionAppender.append_expression

return ExpressionAppender
end
end

do
local _ENV = _ENV
package.preload[ "exasol.vscl.queryrenderer.ImportAppender" ] = function( ... ) local arg = _G.arg;
--- Appender that can add top-level elements of a `SELECT` statement (or sub-select).
---@class ImportAppender: AbstractQueryAppender
local ImportAppender = {}
ImportAppender.__index = ImportAppender
local AbstractQueryAppender = require("exasol.vscl.queryrenderer.AbstractQueryAppender")
setmetatable(ImportAppender, {__index = AbstractQueryAppender})

local SelectAppender = require("exasol.vscl.queryrenderer.SelectAppender")
local Query = require("exasol.vscl.Query")

--- Create a new query renderer.
---@param out_query Query query structure as provided through the Virtual Schema API
---@param appender_config AppenderConfig
---@return ImportAppender query_renderer instance
function ImportAppender:new(out_query, appender_config)
    local instance = setmetatable({}, self)
    instance:_init(out_query, appender_config)
    return instance
end

---@param out_query Query
---@param appender_config AppenderConfig
function ImportAppender:_init(out_query, appender_config)
    AbstractQueryAppender._init(self, out_query, appender_config)
end

---@param connection string
function ImportAppender:_append_connection(connection)
    -- Using double quotes for connection identifier is OK, because this is only used for Exasol databases.
    self:_append(' AT "')
    self:_append(connection)
    self:_append('"')
end

--- Get the statement with extra-quotes where necessary as it will be embedded into the IMPORT statement.
---@param statement SelectSqlStatement statement for which to escape quotes
---@param appender_config AppenderConfig
---@return string statement statement with escaped single quotes
local function get_statement_with_escaped_quotes(statement, appender_config)
    local statement_out_query = Query:new()
    local select_appender = SelectAppender:new(statement_out_query, appender_config)
    select_appender:append(statement)
    local rendered_statement = statement_out_query:to_string()
    local escaped_statement, _ = rendered_statement:gsub("'", "''")
    return escaped_statement
end

---@param statement SelectSqlStatement
function ImportAppender:_append_statement(statement)
    self:_append(" STATEMENT '")
    self:_append(get_statement_with_escaped_quotes(statement, self._appender_config))
    self:_append("'")
end

---@param into ExasolTypeDefinition[]
function ImportAppender:_append_into_clause(into)
    if (into ~= nil) and (next(into) ~= nil) then
        self:_append(" INTO (")
        for i, data_type in ipairs(into) do
            self:_comma(i)
            self:_append("c")
            self:_append(i)
            self:_append(" ")
            self:_append_data_type(data_type)
        end
        self:_append(")")
    end
end

---@param source_type string?
function ImportAppender:_append_from_clause(source_type)
    self:_append(" FROM ")
    self:_append(source_type or "EXA")
end

--- Append an `IMPORT` statement.
---@param import_query ImportSqlStatement import query appended
function ImportAppender:append_import(import_query)
    self:_append("IMPORT")
    self:_append_into_clause(import_query.into)
    self:_append_from_clause(import_query.source_type)
    self:_append_connection(import_query.connection)
    self:_append_statement(import_query.statement)
end

-- Alias for the main entry point allows uniform appender invocation
ImportAppender.append = ImportAppender.append_import

return ImportAppender
end
end

do
local _ENV = _ENV
package.preload[ "exasol.vscl.queryrenderer.ScalarFunctionAppender" ] = function( ... ) local arg = _G.arg;
--- Appender for scalar functions in an SQL statement.
---@class ScalarFunctionAppender: AbstractQueryAppender
local ScalarFunctionAppender = {}
ScalarFunctionAppender.__index = ScalarFunctionAppender
local AbstractQueryAppender = require("exasol.vscl.queryrenderer.AbstractQueryAppender")
setmetatable(ScalarFunctionAppender, {__index = AbstractQueryAppender})

local ExpressionAppender = require("exasol.vscl.queryrenderer.ExpressionAppender")
local ExaError = require("ExaError")

--- Create a new instance of a `ScalarFunctionAppender`.
---@param out_query Query query to which the function will be appended
---@param appender_config AppenderConfig
---@return ScalarFunctionAppender renderer for scalar functions
function ScalarFunctionAppender:new(out_query, appender_config)
    local instance = setmetatable({}, self)
    instance:_init(out_query, appender_config)
    return instance
end

---@param out_query Query query to which the function will be appended
---@param appender_config AppenderConfig
function ScalarFunctionAppender:_init(out_query, appender_config)
    AbstractQueryAppender._init(self, out_query, appender_config)
end

--- Append a scalar function to an SQL query.
---@param scalar_function ScalarFunctionExpression function to append
function ScalarFunctionAppender:append_scalar_function(scalar_function)
    local function_name = string.lower(scalar_function.name)
    local implementation = ScalarFunctionAppender["_" .. function_name]
    if implementation ~= nil then
        implementation(self, scalar_function)
    else
        ExaError:new("E-VSCL-3", "Unable to render unsupported scalar function type {{function_name}}.", {
            function_name = {value = function_name, description = "name of the SQL function that is not yet supported"}
        }):add_ticket_mitigation():raise()
    end
end

-- Alias for main appender function for uniform appender invocation
ScalarFunctionAppender.append = ScalarFunctionAppender.append_scalar_function

---@param expression Expression
function ScalarFunctionAppender:_append_expression(expression)
    local expression_renderer = ExpressionAppender:new(self._out_query, self._appender_config)
    expression_renderer:append_expression(expression)
end

---@param arguments Expression[]
function ScalarFunctionAppender:_append_function_argument_list(arguments)
    self:_append("(")
    if (arguments) then
        for i = 1, #arguments do
            self:_comma(i)
            self:_append_expression(arguments[i])
        end
    end
    self:_append(")")
end

---@param left Expression
---@param operator string
---@param right Expression
function ScalarFunctionAppender:_append_arithmetic_function(left, operator, right)
    self:_append_expression(left)
    self:_append(" ")
    self:_append(operator)
    self:_append(" ")
    self:_append_expression(right)
end

function ScalarFunctionAppender:_append_parameterless_function(scalar_function)
    self:_append(scalar_function.name)
end

function ScalarFunctionAppender:_append_simple_function(f)
    self:_append(string.upper(f.name))
    self:_append_function_argument_list(f.arguments)
end

-- Numeric functions
ScalarFunctionAppender._abs = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._acos = ScalarFunctionAppender._append_simple_function

function ScalarFunctionAppender:_add(f)
    self:_append_arithmetic_function(f.arguments[1], "+", f.arguments[2])
end

ScalarFunctionAppender._asin = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._atan = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._atan = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._atan2 = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._ceil = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._cos = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._cosh = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._cot = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._degrees = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._div = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._exp = ScalarFunctionAppender._append_simple_function

function ScalarFunctionAppender:_float_div(f)
    self:_append_arithmetic_function(f.arguments[1], "/", f.arguments[2])
end

ScalarFunctionAppender._floor = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._ln = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._log = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._min_scale = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._mod = ScalarFunctionAppender._append_simple_function

function ScalarFunctionAppender:_mult(f)
    self:_append_arithmetic_function(f.arguments[1], "*", f.arguments[2])
end

function ScalarFunctionAppender:_neg(f)
    self:_append("-")
    self:_append_expression(f.arguments[1])
end

ScalarFunctionAppender._pi = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._power = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._radians = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._rand = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._round = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._sign = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._sin = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._sinh = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._sqrt = ScalarFunctionAppender._append_simple_function

function ScalarFunctionAppender:_sub(f)
    self:_append_arithmetic_function(f.arguments[1], "-", f.arguments[2])
end

ScalarFunctionAppender._tan = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._tanh = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._to_char = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._to_number = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._trunc = ScalarFunctionAppender._append_simple_function

-- String functions
ScalarFunctionAppender._ascii = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._bit_length = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._chr = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._cologne_phonetic = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._concat = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._dump = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._edit_distance = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._initcap = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._insert = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._instr = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._left = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._length = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._locate = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._lower = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._lpad = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._ltrim = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._octet_length = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._regexp_instr = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._regexp_substr = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._repeat = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._replace = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._reverse = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._right = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._rpad = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._rtrim = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._soundex = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._space = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._substr = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._translate = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._trim = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._unicode = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._unicodechr = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._upper = ScalarFunctionAppender._append_simple_function

-- Date / time functions
ScalarFunctionAppender._add_days = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._add_hours = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._add_minutes = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._add_months = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._add_seconds = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._add_weeks = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._add_years = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._convert_tz = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._current_date = ScalarFunctionAppender._append_parameterless_function
ScalarFunctionAppender._current_timestamp = ScalarFunctionAppender._append_parameterless_function
ScalarFunctionAppender._date_trunc = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._day = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._days_between = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._dbtimezone = ScalarFunctionAppender._append_parameterless_function

function ScalarFunctionAppender:_extract(f)
    local to_extract = string.upper(f.toExtract)
    self:_append("EXTRACT(")
    self:_append(to_extract)
    self:_append(" FROM ")
    self:_append_expression(f.arguments[1])
    self:_append(")")
end

ScalarFunctionAppender._from_posix_time = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._hour = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._hours_between = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._localtimestamp = ScalarFunctionAppender._append_parameterless_function
ScalarFunctionAppender._minute = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._minutes_between = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._month = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._months_between = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._numtodsinterval = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._numtoyminterval = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._posix_time = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._second = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._seconds_between = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._sessiontimezone = ScalarFunctionAppender._append_parameterless_function
ScalarFunctionAppender._sysdate = ScalarFunctionAppender._append_parameterless_function
ScalarFunctionAppender._systimestamp = ScalarFunctionAppender._append_parameterless_function
ScalarFunctionAppender._to_date = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._to_dsinterval = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._to_timestamp = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._to_yminterval = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._week = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._year = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._years_between = ScalarFunctionAppender._append_simple_function

-- Geospatial functions
-- Point functions
ScalarFunctionAppender._st_x = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._st_y = ScalarFunctionAppender._append_simple_function

-- Linestring functions
ScalarFunctionAppender._st_endpoint = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._st_isclosed = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._st_isring = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._st_length = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._st_numpoints = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._st_pointn = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._st_startpoint = ScalarFunctionAppender._append_simple_function

-- Polygon functions
ScalarFunctionAppender._st_area = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._st_exteriorring = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._st_interiorringn = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._st_numinteriorrings = ScalarFunctionAppender._append_simple_function

-- Geometry collection functions
ScalarFunctionAppender._st_geometryn = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._st_numgeometries = ScalarFunctionAppender._append_simple_function

-- General geospatial functions
ScalarFunctionAppender._st_boundary = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._st_buffer = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._st_centroid = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._st_contains = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._st_convexhull = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._st_crosses = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._st_difference = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._st_dimension = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._st_disjoint = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._st_distance = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._st_envelope = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._st_equals = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._st_force2d = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._st_geometrytype = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._st_intersection = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._st_intersects = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._st_isempty = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._st_issimple = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._st_overlaps = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._st_setsrid = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._st_symdifference = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._st_touches = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._st_transform = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._st_union = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._st_within = ScalarFunctionAppender._append_simple_function

-- Bitwise functions
ScalarFunctionAppender._bit_and = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._bit_check = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._bit_lrotate = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._bit_lshift = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._bit_not = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._bit_or = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._bit_rrotate = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._bit_rshift = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._bit_set = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._bit_to_num = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._bit_xor = ScalarFunctionAppender._append_simple_function

-- Conversion functions
function ScalarFunctionAppender:_cast(f)
    self:_append("CAST(")
    self:_append_expression(f.arguments[1])
    self:_append(" AS ")
    self:_append_data_type(f.dataType)
    self:_append(")")
end

-- Other functions
function ScalarFunctionAppender:_case(f)
    local arguments = f.arguments
    local results = f.results
    self:_append("CASE ")
    self:_append_expression(f.basis)
    for i = 1, #arguments do
        local argument = arguments[i]
        local result = results[i]
        self:_append(" WHEN ")
        self:_append_expression(argument)
        self:_append(" THEN ")
        self:_append_expression(result)
    end
    if (#results > #arguments) then
        self:_append(" ELSE ")
        self:_append_expression(results[#results])
    end
    self:_append(" END")
end

ScalarFunctionAppender._current_schema = ScalarFunctionAppender._append_parameterless_function
ScalarFunctionAppender._current_session = ScalarFunctionAppender._append_parameterless_function
ScalarFunctionAppender._current_statement = ScalarFunctionAppender._append_parameterless_function
ScalarFunctionAppender._current_user = ScalarFunctionAppender._append_parameterless_function
ScalarFunctionAppender._greatest = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._hash_md5 = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._hashtype_md5 = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._hash_sha1 = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._hashtype_sha1 = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._hash_sha256 = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._hashtype_sha256 = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._hash_sha512 = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._hashtype_sha512 = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._hash_tiger = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._hashtype_tiger = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._is_boolean = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._is_date = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._is_dsinterval = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._is_number = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._is_timestamp = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._is_yminterval = ScalarFunctionAppender._append_simple_function

function ScalarFunctionAppender:_json_value(f)
    local arguments = f.arguments
    local empty_behavior = f.emptyBehavior
    local error_behavior = f.errorBehavior
    self:_append("JSON_VALUE(")
    self:_append_expression(arguments[1])
    self:_append(", ")
    self:_append_expression(arguments[2])
    self:_append(" RETURNING ")
    self:_append_data_type(f.dataType)
    self:_append(" ")
    self:_append(empty_behavior.type)
    if empty_behavior.type == "DEFAULT" then
        self:_append(" ")
        self:_append_expression(empty_behavior.expression)
    end
    self:_append(" ON EMPTY ")
    self:_append(error_behavior.type)
    if error_behavior.type == "DEFAULT" then
        self:_append(" ")
        self:_append_expression(error_behavior.expression)
    end
    self:_append(" ON ERROR)")
end

ScalarFunctionAppender._least = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._nullifzero = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._session_parameter = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._sys_guid = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._typeof = ScalarFunctionAppender._append_simple_function
ScalarFunctionAppender._zeroifnull = ScalarFunctionAppender._append_simple_function

return ScalarFunctionAppender
end
end

do
local _ENV = _ENV
package.preload[ "exasol.vscl.queryrenderer.SelectAppender" ] = function( ... ) local arg = _G.arg;
--- Appender that can add top-level elements of a `SELECT` statement (or sub-select).
---@class SelectAppender: AbstractQueryAppender
local SelectAppender = {}
SelectAppender.__index = SelectAppender
local AbstractQueryAppender = require("exasol.vscl.queryrenderer.AbstractQueryAppender")
setmetatable(SelectAppender, {__index = AbstractQueryAppender})

local ExaError = require("ExaError")
local log = require("remotelog")
local ExpressionAppender = require("exasol.vscl.queryrenderer.ExpressionAppender")

local JOIN_TYPES<const> = {
    inner = "INNER",
    left_outer = "LEFT OUTER",
    right_outer = "RIGHT OUTER",
    full_outer = "FULL OUTER"
}

--- Get a map of supported JOIN type to the join keyword.
---@return table<string, string> join type (key) mapped to SQL join keyword
function SelectAppender.get_join_types()
    return JOIN_TYPES
end

--- Create a new query renderer.
---@param out_query Query query structure as provided through the Virtual Schema API
---@param appender_config AppenderConfig
---@return SelectAppender query renderer instance
function SelectAppender:new(out_query, appender_config)
    local instance = setmetatable({}, self)
    instance:_init(out_query, appender_config)
    return instance
end

---@param out_query Query
---@param appender_config AppenderConfig
function SelectAppender:_init(out_query, appender_config)
    AbstractQueryAppender._init(self, out_query, appender_config)
end

---@param select_list SelectList
function SelectAppender:_append_select_list_elements(select_list)
    for i = 1, #select_list do
        local element = select_list[i]
        self:_comma(i)
        self:_append_expression(element)
    end
end

---@param select_list SelectList?
function SelectAppender:_append_select_list(select_list)
    if not select_list then
        self:_append("*")
    else
        self:_append_select_list_elements(select_list)
    end
end

---@param table TableExpression
function SelectAppender:_append_table(table)
    if table.schema then
        if table.catalog then
            self:_append_identifier(table.catalog)
            self:_append('.')
        end
        self:_append_identifier(table.schema)
        self:_append('.')
    end
    self:_append_identifier(table.name)
end

---@param join JoinExpression
function SelectAppender:_append_join(join)
    local join_type_keyword = JOIN_TYPES[join.join_type]
    if join_type_keyword then
        self:_append_table(join.left)
        self:_append(' ')
        self:_append(join_type_keyword)
        self:_append(' JOIN ')
        self:_append_table(join.right)
        self:_append(' ON ')
        self:_append_expression(join.condition)
    else
        ExaError:new("E-VSCL-6", "Unable to render unknown join type {{type}}.",
                     {type = {value = join.join_type, description = "type of join that was not recognized"}})
                :add_ticket_mitigation():raise()
    end
end

---@param from FromClause
function SelectAppender:_append_from(from)
    if from then
        self:_append(' FROM ')
        local type = from.type
        if type == "table" then
            self:_append_table(from)
        elseif type == "join" then
            self:_append_join(from)
        else
            ExaError:new("E-VSCL-5", "Unable to render unknown SQL FROM clause type {{type}}.",
                         {type = {value = type, description = "type of the FROM clause that was not recognized"}})
                    :add_ticket_mitigation():raise()
        end
    end
end

---@return ExpressionAppender
function SelectAppender:_expression_appender()
    return ExpressionAppender:new(self._out_query, self._appender_config)
end

---@param expression Expression
function SelectAppender:_append_expression(expression)
    self:_expression_appender():append_expression(expression)
end

---@param filter PredicateExpression
function SelectAppender:_append_filter(filter)
    if filter then
        self:_append(" WHERE ")
        self:_expression_appender():append_predicate(filter)
    end
end

--- Replace an unsupported expression in a `GROUP BY` clause with a supported one or return it unchanged.
--
-- This replaces numeric literals with the corresponding string value, as Exasol interprets
-- `GROUP BY <integer-constant>` as column number &mdash; which is not what the user intended. Also,
-- please note that `GROUP BY <constant>` always leads to grouping with a single group, regardless of the
-- actual value of the constant (except for `FALSE`, which is reserved).
--
---@param group_by_criteria Expression the original `GROUP BY` expression
---@return Expression alternative_expression a new, alternative expression or the original expression
---                                          if no replacement is necessary
local function workaround_group_by_integer(group_by_criteria)
    if group_by_criteria.type == "literal_exactnumeric" then
        local new_value = tostring(group_by_criteria.value)
        log.debug("Replacing numeric literal " .. new_value .. " with string literal in GROUP BY")
        return {type = "literal_string", value = new_value}
    else
        return group_by_criteria
    end
end

---@param group Expression[]?
function SelectAppender:_append_group_by(group)
    if group then
        self:_append(" GROUP BY ")
        for i, criteria in ipairs(group) do
            self:_comma(i)
            self:_expression_appender():append_expression(workaround_group_by_integer(criteria))
        end
    end
end

---@param order OrderByClause[]?
---@param in_parenthesis boolean?
function SelectAppender:_append_order_by(order, in_parenthesis)
    if order then
        if not in_parenthesis then
            self:_append(" ")
        end
        self:_append("ORDER BY ")
        for i, criteria in ipairs(order) do
            self:_comma(i)
            self:_expression_appender():append_expression(criteria.expression)
            if criteria.isAscending ~= nil then
                self:_append(criteria.isAscending and " ASC" or " DESC")
            end
            if criteria.nullsLast ~= nil then
                self:_append(criteria.nullsLast and " NULLS LAST" or " NULLS FIRST")
            end
        end
    end
end

---@param limit LimitClause
function SelectAppender:_append_limit(limit)
    if limit then
        self:_append(" LIMIT ")
        self:_append(limit.numElements)
        if limit.offset then
            self:_append(" OFFSET ")
            self:_append(limit.offset)
        end
    end
end

--- Append a sub-select statement.
-- This method is public to allow recursive queries (e.g. embedded into an `EXISTS` clause in an expression.
---@param sub_query SelectSqlStatement query appended
function SelectAppender:append_sub_select(sub_query)
    self:_append("(")
    self:append_select(sub_query)
    self:_append(")")
end

--- Append a `SELECT` statement.
---@param sub_query SelectSqlStatement query appended
function SelectAppender:append_select(sub_query)
    self:_append("SELECT ")
    self:_append_select_list(sub_query.selectList)
    self:_append_from(sub_query.from)
    self:_append_filter(sub_query.filter)
    self:_append_group_by(sub_query.groupBy)
    self:_append_order_by(sub_query.orderBy)
    self:_append_limit(sub_query.limit)
end

-- Alias for the main entry point allows uniform appender invocation
SelectAppender.append = SelectAppender.append_select

return SelectAppender
end
end

do
local _ENV = _ENV
package.preload[ "exasol.vscl.text" ] = function( ... ) local arg = _G.arg;
---
-- This module contains basic string manipulation methods not included in the Lua standard library.
--
local M = {}

---
-- Check if string starts with a substring.
--
---@param text string? string to check
---@param start string? substring
--
---@return boolean result `true` if text starts with mentioned substring, `false` if any of the parameters is `nil`
---         or the text does not start with the substring
--
function M.starts_with(text, start)
    return text ~= nil and start ~= nil and start == string.sub(text, 1, string.len(start))
end

---
-- Remove leading and trailing spaces from a string
--
---@param text string string to be trimmed
--
---@return string trimmed string
--
function M.trim(text)
    return text:match "^%s*(.-)%s*$"
end

---
-- Split a delimited string into its components.
--
---@param text string string to split
--
---@param delimiter? string to split at (default: ',')
---@return string[]? components
--
function M.split(text, delimiter)
    if (text == nil) then
        return nil
    end
    delimiter = delimiter or ','
    local tokens = {}
    for token in (text .. delimiter):gmatch("(.-)" .. delimiter) do
        if (token ~= nil and token ~= "") then
            table.insert(tokens, M.trim(token))
        end
    end
    return tokens
end

return M
end
end

do
local _ENV = _ENV
package.preload[ "exasol.vscl.validator" ] = function( ... ) local arg = _G.arg;
--- Validators for common input such as user names or port numbers.
-- @module exasol.validator
local ExaError = require("ExaError")

local validator = {}

local SQL_IDENTIFIER_DOC_URL<const> =
        "https://docs.exasol.com/db/latest/sql_references/basiclanguageelements.htm#SQLIdentifier"
local MAX_IDENTIFIER_LENGTH<const> = 128

---@param id string?
---@param id_type string
local function validate_identifier_not_nil(id, id_type)
    if id == nil then
        ExaError:new("E-EVSCL-VAL-5", "Identifier cannot be null (or Lua nil): {{id_type|u}} name",
                     {id_type = {value = id_type, description = "type of database object which should be identified"}})
                :raise()
    end
end

---@param id string
---@param id_type string
local function validate_identifier_length(id, id_type)
    local length = utf8.len(id)
    if length > MAX_IDENTIFIER_LENGTH then
        ExaError:new("E-EVSCL-VAL-4", "Identifier too long: {{id_type|u}} name with {{length}} characters.", {
            id_type = {value = id_type, description = "type of database object which should be identified"},
            length = {value = length, description = "actual length of the identifier"}
        }):raise()
    end
end

-- Currently we only support the characters between 0x41 (= A) up to 0x5A (= Z) (ASCII) in all classes.
local function is_unicode_uppercase_letter(char)
    return char >= 0x41 and char <= 0x5A;
end

-- Currently we only support the characters between 0x61 (= a) up to 0x7A (= z) (ASCII) in all classes.
local function is_unicode_lowercase_letter(char)
    return char >= 0x61 and char <= 0x7A
end

-- Currently we only support the digits between 0x30 (= 0) up to 0x39 (= 9) (ASCII) in all classes.
local function is_unicode_decimal_number(char)
    return char >= 0x30 and char <= 0x39
end

-- Currently we only support the punctuation character 0x5f (= _) (ASCII) in all classes.
local function is_unicode_connector_punctuation(char)
    return char == 0x5f -- underscore
end

local function is_middle_dot(char)
    return char == 0xB7;
end

--- Check if the character is a valid first character for an identifier.
-- <ul>
-- <li>Lu (upper-case letters): partial support</li>
-- <li>Ll (lower-case letters): partial support</li>
-- <li>Lt (title-case letters): not supported yet</li>
-- <li>Lm (modifier letters): not supported yet</li>
-- <li>Lo (other letters): not supported yet</li>
-- <li>Nl (letter numbers): not supported yet</li>
---@param char integer unicode character number
---@return boolean result `true` if the character is valid
local function is_valid_first_identifier_character(char)
    return is_unicode_uppercase_letter(char) or is_unicode_lowercase_letter(char)
end

--- Check if the character is a valid follow-up character for an identifier.
-- <ul>
-- <li>Mn (non-spacing marks): not supported yet</li>
-- <li>Mc (spacing combination marks): not supported yet</li>
-- <li>Nd (decimal numbers): partial support</li>
-- <li>Pc (connectors punctuations): partial support</li>
-- <li>Cf (formatting codes): not supported yet</li>
-- <li>unicode character U+00B7 (middle dot): supported</li>
---@param char integer unicode character number
---@return boolean result `true` if the character is valid
local function is_valid_followup_identifier_character(char)
    return is_valid_first_identifier_character(char) or is_unicode_decimal_number(char)
                   or is_unicode_connector_punctuation(char) or is_middle_dot(char)
end

---@param id string database object identifier
---@param id_type string type of the database object referenced by the identifier
local function validate_identifier_characters(id, id_type)
    for position, char in utf8.codes(id) do
        if (position == 1 and not is_valid_first_identifier_character(char))
                or (not is_valid_followup_identifier_character(char)) then
            ExaError:new("E-EVSCL-VAL-3", "Invalid character in {{id_type|u}} name at position {{position}}: {{id}}", {
                id_type = {value = id_type, description = "type of database object which should be identified"},
                position = {value = position, description = "position of the first illegal character in identifier"},
                id = {value = id, description = "value of the object identifier"}
            }):add_mitigations("Please note that " .. id_type .. " names are SQL identifiers. Refer to "
                                       .. SQL_IDENTIFIER_DOC_URL .. " for information about valid identifiers."):raise()
        end
    end
end

---@param id string? database object identifier (e.g. a table name)
---@param id_type string type of the database object
local function validate_sql_identifier(id, id_type)
    validate_identifier_not_nil(id, id_type)
    assert(id ~= nil)
    validate_identifier_length(id, id_type)
    validate_identifier_characters(id, id_type)
end

---@param id string? user name
function validator.validate_user(id)
    validate_sql_identifier(id, "user")
end

---@param port_string string? port as string (before it is proven to be a number)
function validator.validate_port(port_string)
    local port = tonumber(port_string)
    if port == nil then
        ExaError:new("E-EVSCL-VAL-1", "Illegal source database port (not a number): {{port}}",
                     {port = {value = port_string, "number of the port the source database listens on"}})
                :add_mitigations("Please enter a number between 1 and 65535"):raise()
    else
        if (port < 1) or (port > 65535) then
            ExaError:new("E-EVSCL-VAL-2", "Source database port is out of range: {{port}}",
                         {port = {value = port, "number of the port the source database listens on"}}):add_mitigations(
                    "Please pick a port between 1 and 65535", "The default Exasol port is 8563"):raise()
        end
    end
end

return validator
end
end

do
local _ENV = _ENV
package.preload[ "remotelog" ] = function( ... ) local arg = _G.arg;
local levels = {NONE = 1, FATAL = 2, ERROR = 3, WARN = 4, INFO = 5, CONFIG = 6, DEBUG = 7, TRACE = 8}
local fallback_strategies = {CONSOLE = 1, DISCARD = 2, ERROR = 3}

---
-- This module implements a remote log client with the ability to fall back to console logging in case no connection
-- to a remote log receiver is established.
-- <p>
-- You can optionally use a high resolution timer for performance monitoring. Since Lua's <code>os.date()</code>
-- function only has a resolution of seconds, that timer uses <code>socket.gettime()</code>. Note that the values
-- you are getting are not the milliseconds of a second, but the milliseconds counted from when the module was first
-- loaded &mdash; which is typically at the very beginning of the software using this module.
-- </p><p>
-- Use the <code>init()</code> method to set some global parameters for this module.
-- </p>
--
local M = {
    VERSION = "1.1.1",
    level = levels.INFO,
    socket_client = nil,
    connection_timeout = 0.1, -- seconds
    log_client_name = nil,
    timestamp_pattern = "%Y-%m-%d %H:%M:%S", -- example: 2020-09-02 13:56:01
    start_nanos = 0,
    use_high_resolution_time = true,
    fallback_strategies = fallback_strategies,
    fallback_strategy = fallback_strategies.CONSOLE
}

local socket = require("socket")

---
-- Initialize the log module
-- <p>
-- This method allows you to set parameters that apply to all subsequent calls to logging methods. While it is possible
-- to change these settings at runtime, the recommended way is to do this once only, before you use the log for the
-- first time.
-- </p>
-- <p>
-- You can use a high resolution timer. Note that this are <b>not</b> the sub-second units of the timestamp! Lua
-- timestamps only offer second resolution. Rather you get a time difference in milliseconds counted from the first time
-- the log is opened.
--
-- @param timestamp_pattern layout of timestamps displayed in the logs
--
-- @param use_high_resolution_time switch high resolution time display on or off (default)
--
-- @param fallback_strategy what to do if the remote listener connection cannot be established (default: console log)
--
-- @return module loader
--
function M.init(timestamp_pattern, use_high_resolution_time, fallback_strategy)
    if timestamp_pattern then
        M.timestamp_pattern = timestamp_pattern
    end
    M.use_high_resolution_time = use_high_resolution_time or false
    M.fallback_strategy = fallback_strategy or fallback_strategies.CONSOLE
    return M
end

---
-- Set the log client name.
-- <p>
-- This is the name presented when the log is first opened. We recommend using the name of the application or script
-- that uses the log and a version number.
-- </p>
--
function M.set_client_name(log_client_name)
    M.log_client_name = log_client_name
end

local function start_high_resolution_timer()
    if M.use_high_resolution_time then
        M.start_nanos = socket.gettime()
    end
end

local function get_level_name(level)
    for key, value in pairs(levels) do
        if value == level then
            return key
        end
    end
    error("E-LOG-1: Unable to determine log level name for level number " .. level .. ".")
end

local function fallback_print(...)
    if M.fallback_strategy == fallback_strategies.DISCARD then
        return
    elseif M.fallback_strategy == fallback_strategies.CONSOLE then
        if print then print(...) end
    else
        error(string.format(...))
    end
end

---
-- Open a connection to a remote log receiver.
-- <p>
-- This method allows connecting the log to an external process listening on a TCP port. The process can be on a remote
-- host. If the connection cannot be established, the logger falls back to console logging.
-- </p>
-- <p>
-- If you don't use the <code>connect()</code> function, you get regular console logging.
-- </p>
--
-- @param host remote host on which the logging process runs
--
-- @param port TCP port on which the logging process listens
--
function M.connect(host, port)
    local tcp_socket = socket.tcp()
    tcp_socket:settimeout(M.connection_timeout)
    local ok, err = tcp_socket:connect(host, port)
    local log_client_prefix = M.log_client_name and (M.log_client_name .. ": ") or ""
    if ok then
        M.socket_client = tcp_socket
        M.info("%sConnected to log receiver listening on %s:%d with log level %s. Time zone is UTC%s.",
            log_client_prefix, host, port, get_level_name(M.level), os.date("%z"))
    else
        fallback_print(log_client_prefix .. "W-LOG-2: Unable to open socket connection to " .. host .. ":" .. port
            .. " for sending log messages. Falling back to console logging with log level "
            .. get_level_name(M.level) .. ". Timezone is UTC" .. os.date("%z") .. ". Caused by: " .. err)
    end
end

---
-- Close the connection to the remote log receiver.
--
function M.disconnect()
    if(M.socket_client) then
        M.socket_client:close()
    end
end

---
-- Set the log level.
--
-- @param level_name name of the log level, one of: FATAL, ERROR, WARN, INFO, CONFIG, DEBUG, TRACE
--
function M.set_level(level_name)
    local level = levels[level_name]
    if not level then
        M.warn('W-LOG-1: Attempt to set illegal log level "%s". Pick one of: NONE, FATAL, ERROR, WARN, INFO, CONFIG,'
            .. ' DEBUG, TRACE. Falling back to level INFO.', level_name)
        M.level = levels.INFO
    else
        M.level = level
    end
end

---
-- Write to a socket, print or discard message.
-- <p>
-- If a socket connection is established, this method writes to that socket. Otherwise if the global print function
-- exists (e.g. in a unit test) falls back to logging via <code>print()</code>.
-- </p><p>
-- Exasol removed print() in it's Lua implementation, so there is no fallback on a real Exasol instance. You either use
-- remote logging or messages are discarded immediately.
-- </p>
--
-- @param level log level
--
-- @param message log message; otherwise used as format string if any variadic parameters follow
--
-- @param ... parameters to be inserted into formatted message (optional)
--
local function write(level, message, ...)
    if not (M.socket_client or print) then
        return
    else
        local entry
        local formatted_message = (select('#', ...) > 0) and string.format(message, ...) or message
        if M.use_high_resolution_time then
            local current_millis = string.format("%07.3f", (socket.gettime() - M.start_nanos) * 1000)
            entry = {
                os.date(M.timestamp_pattern),
                " (", current_millis, "ms) [", level , "]",
                string.rep(" ", 7 - string.len(level)), formatted_message
            }
        else
            entry = {
                os.date(M.timestamp_pattern),
                " [", level , "]",
                string.rep(" ", 7 - string.len(level)), formatted_message
            }
        end
        if M.socket_client then
            entry[#entry + 1] = "\n"
            M.socket_client:send(table.concat(entry))
        else
            fallback_print(table.concat(entry))
        end
    end
end

---
-- Write a log message on level <code>FATAL</code>.
-- <p>
-- You should use this in cases where you directly need to terminate the running program afterwards. I.e. in case of
-- non-recoverable errors (e.g. data corruption).
-- </p>
--
-- @see info for details about the function paramters
--
-- @param ... log message or message pattern with placeholders and values
--
function M.fatal(...)
    if M.level >= levels.FATAL then
        write("FATAL", ...)
    end
end

---
-- Write a log message on level <code>ERROR<code>.
-- <p>
-- Log potentially recoverable errors on this level.
-- </p>
--
-- @see info for details about the function paramters
--
-- @param ... log message or message pattern with placeholders and values
--
function M.error(...)
    if M.level >= levels.ERROR then
        write("ERROR", ...)
    end
end

---
-- Write a log message on level <code>WARN<code>.
-- <p>
-- Log problems that either are recovered from automatically or do not have immediate adverse effects on this level.
-- </p>
--
-- @see info for details about the function paramters
--
-- @param ... log message or message pattern with placeholders and values
--
function M.warn(...)
    if M.level >= levels.WARN then
        write("WARN", ...)
    end
end

---
-- Write a log message on level <code>info</code>.
-- <p>
-- We recommend using this scarcely and for non-repeating messages only, since this is the default log level. Otherwise
-- a regular log will be cluttered.
-- </p>
-- <p> The parameters can either be a single parameter which will be written to the log as-is. In case multiple
-- parameters are used, the first is treated as message pattern with placeholders as used in the standard library's
-- <code>string.format(...)</code> function.
-- <p>
--
-- @param ... log message or message pattern with placeholders and values
--
function M.info(...)
    if M.level >= levels.INFO then
        write("INFO", ...)
    end
end

---
-- Write a log message on level <code>CONFIG</code>.
-- <p>
-- Messages on this level should be used to log program configuration or environment information.
-- </p>
--
-- @see info for details about the function paramters
--
-- @param ... log message or message pattern with placeholders and values
--
function M.config(...)
    if M.level >= levels.CONFIG then
        write("CONFIG", ...)
    end
end

---
-- Write a log message on level <code>DEBUG</code>.
-- <p>
-- Log information that helps analyzing program flow and error causes on this level.
-- </p>
--
-- @see info for details about the function paramters
--
-- @param ... log message or message pattern with placeholders and values
--
function M.debug(...)
    if M.level >= levels.DEBUG then
        write("DEBUG", ...)
    end
end

---
-- Write a log message on level <code>TRACE</code>.
-- <p>
-- Use this log level for the most details logging information, like internal program state, method entry and exit.
-- parameter values and all other details that are only of interest for someone with intimate knowledge of the internal
-- workings of the program.
-- </p>
--
-- @see info for details about the function paramters
--
-- @param ... log message or message pattern with placeholders and values
--
function M.trace(...)
    if M.level >= levels.TRACE then
        write("TRACE", ...)
    end
end

start_high_resolution_timer()
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
    local dispatcher = RequestDispatcher:new(adapter, AdapterProperties)
    return dispatcher:adapter_call(request_json)
end
