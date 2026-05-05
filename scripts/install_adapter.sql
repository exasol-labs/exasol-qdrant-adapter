-- =============================================================================
-- install_adapter.sql — Standalone Lua adapter script (Qdrant Virtual Schema)
-- =============================================================================
--
-- This file installs ONLY the Lua adapter script. It does NOT create the
-- ADAPTER schema, the CONNECTION objects, the Python UDFs, or the virtual
-- schema — for the full stack run scripts/install_all.sql instead.
--
-- The adapter rewrites pushdown queries to a SQL call to
-- ADAPTER.SEARCH_QDRANT_LOCAL — a SET UDF that owns the embed + Qdrant
-- search work. Make sure scripts/install_local_embeddings.sql has been run
-- first so SEARCH_QDRANT_LOCAL is available, otherwise pushDown queries will
-- fail with "function ADAPTER.SEARCH_QDRANT_LOCAL not found".
--
-- Why a SET UDF and not a direct HTTP/embedding call from this Lua script:
-- Exasol forbids exa.pquery_no_preprocessing during virtual schema pushdown
-- (it would re-enter the SQL planner). The canonical workaround is for the
-- adapter to generate SQL that targets a row-emitting UDF.
-- =============================================================================

CREATE OR REPLACE LUA ADAPTER SCRIPT ADAPTER.VECTOR_SCHEMA_ADAPTER AS
local ADAPTER_VERSION = "3.1.0"

local cjson = require("cjson")
local http  = require("socket.http")
local ltn12 = require("ltn12")

local function http_get_json(url, headers)
    local chunks = {}
    local _, code = http.request({url=url, method="GET", headers=headers or {}, sink=ltn12.sink.table(chunks)})
    local body = table.concat(chunks)
    assert(type(code)=="number" and code<400, ("GET %s => %s: %s"):format(url,tostring(code),body))
    return cjson.decode(body)
end

local COLS = {
    {name="ID",    dataType={type="VARCHAR", size=2000000, characterSet="UTF8"}},
    {name="TEXT",  dataType={type="VARCHAR", size=2000000, characterSet="UTF8"}},
    {name="SCORE", dataType={type="DOUBLE"}},
    {name="QUERY", dataType={type="VARCHAR", size=2000000, characterSet="UTF8"}},
}

local function resolve(props)
    local conn = exa.get_connection(props.CONNECTION_NAME)
    local url = (props.QDRANT_URL and props.QDRANT_URL ~= "") and props.QDRANT_URL or conn.address
    return url:gsub("/$", ""), conn.password or ""
end

local function glob_to_pattern(glob)
    local p = glob:gsub("([%.%+%-%^%$%(%)%%])", "%%%1")
    p = p:gsub("%*", ".*"):gsub("%?", ".")
    return "^" .. p .. "$"
end

local function matches_filter(name, filter)
    if not filter or type(filter) ~= "string" or filter == "" then return true end
    for entry in filter:gmatch("[^,]+") do
        local pat = entry:match("^%s*(.-)%s*$")
        if pat ~= "" and name:match(glob_to_pattern(pat)) then return true end
    end
    return false
end

local function read_metadata(props)
    local url, key = resolve(props)
    local h = {}
    if key ~= "" then h["api-key"] = key end
    local r = http_get_json(url .. "/collections", h)
    local filter = props.COLLECTION_FILTER
    local tables = {}
    for _, c in ipairs((r.result or {}).collections or {}) do
        if c.name and matches_filter(c.name, filter) then
            tables[#tables+1] = {name=c.name:upper(), columns=COLS}
        end
    end
    return tables
end

local function esc(s) return (s or ""):gsub("'", "''") end

local function rewrite(req, props)
    local pdr = req.pushdownRequest or {}
    local col = (((req.involvedTables or {})[1]) or {}).name
    assert(col, "no involved table in involvedTables")
    col = col:lower()
    local qtext = ""
    local f = pdr.filter
    local unsupported_filter = false
    if f and f.type == "predicate_equal" then
        local l, r = f.left or {}, f.right or {}
        if l.type == "column" and l.name:upper() == "QUERY" and r.type == "literal_string" then
            qtext = r.value
        elseif r.type == "column" and r.name:upper() == "QUERY" and l.type == "literal_string" then
            qtext = l.value
        else
            unsupported_filter = true
        end
    elseif f then
        unsupported_filter = true
    end
    if qtext == "" then
        local hint_text
        if unsupported_filter then
            hint_text = "Unsupported predicate. Only WHERE \"QUERY\" = ''your search text'' is supported. LIKE, >, <, AND, OR are not supported. Example: SELECT \"ID\", \"TEXT\", \"SCORE\" FROM vector_schema." .. col .. " WHERE \"QUERY\" = ''your search'' LIMIT 10"
        else
            hint_text = "Semantic search requires: WHERE \"QUERY\" = ''your search text''. Example: SELECT \"ID\", \"TEXT\", \"SCORE\" FROM vector_schema." .. col .. " WHERE \"QUERY\" = ''your search'' LIMIT 10"
        end
        return "SELECT * FROM VALUES (CAST('HINT' AS VARCHAR(2000000) UTF8), CAST('" .. hint_text .. "' AS VARCHAR(2000000) UTF8), CAST(1 AS DOUBLE), CAST('Only equality predicates on QUERY are supported: WHERE \"QUERY\" = ''your text''' AS VARCHAR(2000000) UTF8)) AS t(ID, TEXT, SCORE, QUERY)"
    end
    local limit = (pdr.limit and pdr.limit.numElements) and tonumber(pdr.limit.numElements) or 10
    return string.format(
        "SELECT result_id AS \"ID\", result_text AS \"TEXT\","
        .. " result_score AS \"SCORE\", result_query AS \"QUERY\""
        .. " FROM (SELECT ADAPTER.SEARCH_QDRANT_LOCAL("
        .. "'%s', '%s', '%s', %d) FROM DUAL)",
        esc(props.CONNECTION_NAME), esc(col), esc(qtext), limit
    )
end

local function props_of(req) return ((req.schemaMetadataInfo or {}).properties or {}) end

local REMOVED_PROPS = {
    OLLAMA_URL = "OLLAMA_URL is no longer supported — the query path now embeds in-database via ADAPTER.SEARCH_QDRANT_LOCAL (no Ollama process is required). Drop and re-create the virtual schema without OLLAMA_URL after running scripts/install_all.sql.",
}

local function check(p)
    for key, msg in pairs(REMOVED_PROPS) do
        if p[key] and p[key] ~= "" then error(msg) end
    end
    assert(p.CONNECTION_NAME and p.CONNECTION_NAME ~= "", "Missing CONNECTION_NAME")
    assert(p.QDRANT_MODEL and p.QDRANT_MODEL ~= "", "Missing QDRANT_MODEL")
end

function adapter_call(request_json)
    local ok, req = pcall(cjson.decode, request_json)
    if not ok then error("Failed to parse request: " .. tostring(req)) end
    local t = (req.type or ""):lower()
    if t == "getcapabilities" then
        return cjson.encode({type="getCapabilities", capabilities={"SELECTLIST_EXPRESSIONS","FILTER_EXPRESSIONS","LIMIT","LIMIT_WITH_OFFSET","FN_PRED_EQUAL","LITERAL_STRING"}})
    elseif t == "createvirtualschema" then
        local p = props_of(req); check(p)
        return cjson.encode({type="createVirtualSchema", schemaMetadata={tables=read_metadata(p)}})
    elseif t == "refresh" then
        local p = props_of(req); check(p)
        return cjson.encode({type="refresh", schemaMetadata={tables=read_metadata(p)}})
    elseif t == "setproperties" then
        local old = props_of(req)
        local new = req.properties or {}
        for key, msg in pairs(REMOVED_PROPS) do
            if new[key] and new[key] ~= "" then error(msg) end
        end
        local m = {}
        for k, v in pairs(old) do m[k] = v end
        for k, v in pairs(new) do if v == "" then m[k] = nil else m[k] = v end end
        check(m)
        return cjson.encode({type="setProperties", schemaMetadata={tables=read_metadata(m)}})
    elseif t == "dropvirtualschema" then
        return cjson.encode({type="dropVirtualSchema"})
    elseif t == "pushdown" then
        local p = props_of(req); check(p)
        local ok2, result = pcall(rewrite, req, p)
        if not ok2 then
            local msg = esc(tostring(result))
            return cjson.encode({type="pushdown", sql="SELECT * FROM VALUES (CAST('ERROR' AS VARCHAR(2000000) UTF8), CAST('" .. msg .. "' AS VARCHAR(2000000) UTF8), CAST(0 AS DOUBLE), CAST('' AS VARCHAR(2000000) UTF8)) AS t(ID, TEXT, SCORE, QUERY)"})
        end
        return cjson.encode({type="pushdown", sql=result})
    else
        error("Unknown request type: " .. tostring(t))
    end
end
/
