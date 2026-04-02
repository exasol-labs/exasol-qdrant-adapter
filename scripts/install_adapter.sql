CREATE OR REPLACE LUA ADAPTER SCRIPT ADAPTER.VECTOR_SCHEMA_ADAPTER AS
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

local function http_post_json(url, payload, headers)
    local body = cjson.encode(payload)
    local h = headers or {}
    h["Content-Type"]="application/json"
    h["Content-Length"]=tostring(#body)
    local chunks = {}
    local _, code = http.request({url=url, method="POST", headers=h, source=ltn12.source.string(body), sink=ltn12.sink.table(chunks)})
    local resp = table.concat(chunks)
    assert(type(code)=="number" and code<400, ("POST %s => %s: %s"):format(url,tostring(code),resp))
    return cjson.decode(resp)
end

local function http_post_raw(url, body, headers)
    local h = headers or {}
    h["Content-Type"]="application/json"
    h["Content-Length"]=tostring(#body)
    local chunks = {}
    local _, code = http.request({url=url, method="POST", headers=h, source=ltn12.source.string(body), sink=ltn12.sink.table(chunks)})
    local resp = table.concat(chunks)
    assert(type(code)=="number" and code<400, ("POST %s => %s: %s"):format(url,tostring(code),resp))
    return cjson.decode(resp)
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

local function read_metadata(props)
    local url, key = resolve(props)
    local h = {}
    if key ~= "" then h["api-key"] = key end
    local r = http_get_json(url .. "/collections", h)
    local tables = {}
    for _, c in ipairs((r.result or {}).collections or {}) do
        if c.name then
            tables[#tables+1] = {name=c.name:upper(), columns=COLS}
        end
    end
    return tables
end

local function esc(s) return (s or ""):gsub("'", "''") end

local function rewrite(req, props)
    local url, key = resolve(props)
    local ollama = (props.OLLAMA_URL and props.OLLAMA_URL ~= "") and props.OLLAMA_URL or "http://localhost:11434"
    local pdr = req.pushdownRequest or {}
    local col = (((req.involvedTables or {})[1]) or {}).name
    assert(col, "no involved table in involvedTables")
    col = col:lower()
    local qtext = ""
    local f = pdr.filter
    if f and f.type == "predicate_equal" then
        local l, r = f.left or {}, f.right or {}
        if l.type == "column" and l.name:upper() == "QUERY" and r.type == "literal_string" then
            qtext = r.value
        elseif r.type == "column" and r.name:upper() == "QUERY" and l.type == "literal_string" then
            qtext = l.value
        end
    end
    local limit = (pdr.limit and pdr.limit.numElements) and tonumber(pdr.limit.numElements) or 10
    local emb = http_post_json(ollama .. "/api/embeddings", {model=props.QDRANT_MODEL, prompt=qtext})
    assert(emb.embedding, "Ollama returned no embedding array")
    local keys = {}
    for k, _ in pairs(emb.embedding) do if type(k) == "number" then keys[#keys+1] = k end end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do parts[#parts+1] = tostring(emb.embedding[k]) end
    assert(#parts > 0, "Ollama embedding array is empty after iteration")
    local emb_json = "[" .. table.concat(parts, ",") .. "]"
    local search_body = string.format(
        '{"query":%s,"using":"text","limit":%d,"with_payload":true}',
        emb_json, limit
    )
    local h2 = {}
    if key ~= "" then h2["api-key"] = key end
    local sr = http_post_raw(
        url .. "/collections/" .. col .. "/points/query",
        search_body,
        h2
    )
    local res = (sr.result or {}).points or {}
    if #res == 0 then
        return "SELECT CAST('' AS VARCHAR(36) UTF8) AS ID, CAST('' AS VARCHAR(2000000) UTF8) AS TEXT, CAST(0 AS DOUBLE) AS SCORE, CAST('' AS VARCHAR(2000000) UTF8) AS QUERY FROM DUAL WHERE FALSE"
    end
    local rows, q = {}, esc(qtext)
    for _, pt in ipairs(res) do
        local p = pt.payload or {}
        rows[#rows+1] = ("(CAST('%s' AS VARCHAR(2000000) UTF8),CAST('%s' AS VARCHAR(2000000) UTF8),CAST(%s AS DOUBLE),CAST('%s' AS VARCHAR(2000000) UTF8))"):format(
            esc(tostring(p._original_id or pt.id or "")),
            esc(tostring(p.text or "")),
            tostring(pt.score or 0),
            q
        )
    end
    return "SELECT * FROM VALUES " .. table.concat(rows, ",") .. " AS t(ID,TEXT,SCORE,QUERY)"
end

local function props_of(req) return ((req.schemaMetadataInfo or {}).properties or {}) end
local function check(p)
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
        local m = {}
        for k, v in pairs(old) do m[k] = v end
        for k, v in pairs(new) do if v == "" then m[k] = nil else m[k] = v end end
        check(m)
        return cjson.encode({type="setProperties", schemaMetadata={tables=read_metadata(m)}})
    elseif t == "dropvirtualschema" then
        return cjson.encode({type="dropVirtualSchema"})
    elseif t == "pushdown" then
        local p = props_of(req); check(p)
        -- Wrap rewrite in pcall so any error surfaces as a readable SQL result
        local ok2, result = pcall(rewrite, req, p)
        if not ok2 then
            local msg = esc(tostring(result))
            return cjson.encode({type="pushdown", sql="SELECT '" .. msg .. "' AS ADAPTER_ERROR FROM DUAL"})
        end
        return cjson.encode({type="pushdown", sql=result})
    else
        error("Unknown request type: " .. tostring(t))
    end
end
/
