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

--- Handles pushDown: build SQL that calls ADAPTER.SEARCH_QDRANT_LOCAL. The
-- SET UDF owns embedding + Qdrant search; the adapter never runs SQL/HTTP
-- itself during pushdown (Exasol forbids exa.pquery_no_preprocessing here).
function QdrantAdapter:push_down(request)
    local props = self:_load_properties(request)
    props:validate()

    local rewriter = QueryRewriter:new(props:get_connection_name())
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
