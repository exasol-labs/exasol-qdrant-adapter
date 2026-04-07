-- =============================================================================
-- install_all.sql — One-File Installer for Exasol Qdrant Vector Search Adapter
-- =============================================================================
--
-- This single file deploys the complete semantic search stack:
--   1. Schema for adapter scripts and UDFs
--   2. Connection to Qdrant
--   3. Lua adapter script (virtual schema engine)
--   4. Python UDFs (collection creation + data ingestion)
--   5. Virtual schema (query interface)
--
-- INSTRUCTIONS:
--   1. Update the 5 values in the CONFIGURATION section below
--   2. Run this entire file in your SQL client (DBeaver, DbVisualizer, etc.)
--   3. Done! Skip to the USAGE EXAMPLES at the bottom.
--
-- Prerequisites:
--   - Exasol 7.x+ running (Docker: docker run -d --name exasoldb -p 8563:8563 --privileged exasol/docker-db:latest)
--     Wait ~90 seconds for initialization. Connect: host=localhost, port=8563, user=sys, password=exasol
--   - Qdrant 1.9+ accessible from inside Exasol (Docker: docker run -d --name qdrant -p 6333:6333 qdrant/qdrant)
--   - Ollama with an embedding model pulled (Docker: docker run -d --name ollama -p 11434:11434 ollama/ollama
--     then: docker exec ollama ollama pull nomic-embed-text)
--
-- Docker networking note:
--   Inside Exasol's container, use the Docker bridge gateway IP (typically
--   172.17.0.1) to reach services on the host. Find it with:
--     docker exec exasoldb ip route show default
--   host.docker.internal does NOT work in Exasol's UDF sandbox on Linux.
-- =============================================================================


-- ┌───────────────────────────────────────────────────────────────────────────┐
-- │ CONFIGURATION — Update these values for your environment                 │
-- └───────────────────────────────────────────────────────────────────────────┘
-- To customize, find-and-replace these defaults throughout the file:
--
--   ADAPTER          → Schema name for scripts/UDFs
--   172.17.0.1       → Your Qdrant/Ollama host IP
--   6333             → Your Qdrant port
--   11434            → Your Ollama port
--   nomic-embed-text → Your Ollama embedding model


-- ┌───────────────────────────────────────────────────────────────────────────┐
-- │ STEP 1: Create schema                                                    │
-- └───────────────────────────────────────────────────────────────────────────┘

CREATE SCHEMA IF NOT EXISTS ADAPTER;
OPEN SCHEMA ADAPTER;


-- ┌───────────────────────────────────────────────────────────────────────────┐
-- │ STEP 2: Create connection to Qdrant                                      │
-- └───────────────────────────────────────────────────────────────────────────┘
-- The CONNECTION stores the Qdrant URL and optional API key.
-- USER is unused. IDENTIFIED BY is the Qdrant API key (leave '' for no auth).

CREATE OR REPLACE CONNECTION qdrant_conn
    TO 'http://172.17.0.1:6333'
    USER ''
    IDENTIFIED BY '';


-- ┌───────────────────────────────────────────────────────────────────────────┐
-- │ STEP 3: Deploy Lua adapter script                                        │
-- └───────────────────────────────────────────────────────────────────────────┘
-- This is the virtual schema engine. It handles:
--   - Discovering Qdrant collections as virtual tables
--   - Embedding query text via Ollama at query time
--   - Searching Qdrant for similar vectors
--   - Returning ranked results as SQL rows
--
-- Fixed 4-column schema per table: ID, TEXT, SCORE, QUERY

CREATE OR REPLACE LUA ADAPTER SCRIPT ADAPTER.VECTOR_SCHEMA_ADAPTER AS
-- Adapter version: update this on each release for deployment tracking.
local ADAPTER_VERSION = "2.2.0"

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

-- Tokenizer for hybrid search keyword extraction
local _STOP = {}
for _, w in ipairs({
    "a","an","the","and","or","but","not","no","nor","so","yet",
    "is","am","are","was","were","be","been","being",
    "has","have","had","do","does","did","will","would","shall","should",
    "can","could","may","might","must",
    "in","on","at","to","for","of","by","from","with","about","between",
    "through","during","before","after","above","below","up","down",
    "out","off","over","under","into",
    "i","me","my","we","us","our","you","your","he","him","his",
    "she","her","it","its","they","them","their",
    "this","that","these","those","what","which","who","whom","how",
    "when","where","why","if","then","than","as","while",
    "all","each","every","both","few","more","most","some","any","such",
    "very","just","also","only","too","own","same","other",
}) do _STOP[w] = true end

local function extract_keywords(text)
    local seen, result, prev = {}, {}, nil
    for word in text:lower():gmatch("[%w]+") do
        if #word >= 2 and not _STOP[word] and not seen[word] then
            seen[word] = true
            result[#result+1] = word
            if prev then
                local compound = prev .. word
                if not seen[compound] then
                    seen[compound] = true
                    result[#result+1] = compound
                end
            end
            prev = word
        else
            prev = nil
        end
    end
    if #result > 12 then
        local capped = {}
        for i = 1, 12 do capped[i] = result[i] end
        return capped
    end
    return result
end

local function rewrite(req, props)
    local url, key = resolve(props)
    assert(props.OLLAMA_URL and props.OLLAMA_URL ~= "", "OLLAMA_URL property is not set. Set it to your Ollama endpoint reachable from inside Exasol (e.g. 'http://172.17.0.1:11434' for Docker bridge). Do NOT use 'localhost' — it does not work inside Exasol's UDF sandbox.")
    local ollama = props.OLLAMA_URL
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
    local emb = http_post_json(ollama .. "/api/embeddings", {model=props.QDRANT_MODEL, prompt=qtext})
    assert(emb.embedding, "Ollama returned no embedding array")
    local keys = {}
    for k, _ in pairs(emb.embedding) do if type(k) == "number" then keys[#keys+1] = k end end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do parts[#parts+1] = tostring(emb.embedding[k]) end
    assert(#parts > 0, "Ollama embedding array is empty after iteration")
    local emb_json = "[" .. table.concat(parts, ",") .. "]"
    -- Hybrid search: vector + per-keyword RRF fusion
    local keywords = extract_keywords(qtext)
    local search_body
    if #keywords > 0 then
        local vlimit = math.max(limit * 10, 50)
        local klimit = math.max(limit * 4, 20)
        local legs = {string.format('{"query":%s,"using":"text","limit":%d}', emb_json, vlimit)}
        for _, kw in ipairs(keywords) do
            legs[#legs+1] = string.format('{"query":%s,"using":"text","limit":%d,"filter":{"must":[{"key":"text","match":{"text":"%s"}}]}}', emb_json, klimit, kw:gsub('"', '\\"'))
        end
        search_body = string.format('{"prefetch":[%s],"query":{"fusion":"rrf"},"limit":%d,"with_payload":true}', table.concat(legs, ","), limit)
    else
        search_body = string.format(
            '{"query":%s,"using":"text","limit":%d,"with_payload":true}',
            emb_json, limit
        )
    end
    local h2 = {}
    if key ~= "" then h2["api-key"] = key end
    local sr = http_post_raw(
        url .. "/collections/" .. col .. "/points/query",
        search_body,
        h2
    )
    local res = (sr.result or {}).points or {}
    if #res == 0 then
        return "SELECT CAST('' AS VARCHAR(2000000) UTF8) AS ID, CAST('' AS VARCHAR(2000000) UTF8) AS TEXT, CAST(0 AS DOUBLE) AS SCORE, CAST('' AS VARCHAR(2000000) UTF8) AS QUERY FROM DUAL WHERE FALSE"
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


-- ┌───────────────────────────────────────────────────────────────────────────┐
-- │ STEP 4: Deploy Python UDFs for data ingestion                            │
-- └───────────────────────────────────────────────────────────────────────────┘
-- These UDFs let you create Qdrant collections and ingest data from Exasol
-- tables — all from SQL. No pip packages required (Python stdlib only).

-- 4a. CREATE_QDRANT_COLLECTION — Creates a Qdrant collection
CREATE OR REPLACE PYTHON3 SCALAR SCRIPT ADAPTER.CREATE_QDRANT_COLLECTION(
    host        VARCHAR(255),
    port        INTEGER,
    api_key     VARCHAR(512),
    collection  VARCHAR(255),
    vector_size INTEGER,
    distance    VARCHAR(32),
    model_name  VARCHAR(255)
)
RETURNS VARCHAR(512)
AS
import json
import urllib.request
import urllib.error

_MODEL_DIMENSIONS = {
    "text-embedding-3-small":    1536,
    "text-embedding-3-large":    3072,
    "text-embedding-ada-002":    1536,
    "all-MiniLM-L6-v2":          384,
    "all-MiniLM-L12-v2":         384,
    "all-mpnet-base-v2":         768,
    "paraphrase-MiniLM-L6-v2":   384,
    "multi-qa-MiniLM-L6-cos-v1": 384,
    "nomic-embed-text":          768,
}
_VALID_DISTANCES = {"Cosine", "Dot", "Euclid", "Manhattan"}

def _qdrant_request(method, url, body=None, api_key=None):
    data = json.dumps(body).encode() if body is not None else None
    headers = {"Content-Type": "application/json"}
    if api_key:
        headers["api-key"] = api_key
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        raise RuntimeError("Qdrant HTTP " + str(e.code) + ": " + e.read().decode()) from e
    except urllib.error.URLError as e:
        raise RuntimeError("Connection to " + url + " failed: " + str(e.reason)) from e

def run(ctx):
    host        = ctx.host
    port        = int(ctx.port)
    api_key     = ctx.api_key or None
    collection  = ctx.collection
    vector_size = ctx.vector_size
    distance    = ctx.distance
    model_name  = ctx.model_name or ""

    if distance not in _VALID_DISTANCES:
        raise ValueError("Invalid distance '" + distance + "'. Valid: " + ", ".join(sorted(_VALID_DISTANCES)))

    if vector_size is None:
        if not model_name:
            raise ValueError("vector_size is NULL and no model_name provided.")
        if model_name not in _MODEL_DIMENSIONS:
            raise ValueError("Unknown model '" + model_name + "'. Provide explicit vector_size.")
        vector_size = _MODEL_DIMENSIONS[model_name]

    base_url = "http://" + host + ":" + str(port)
    resp = _qdrant_request("GET", base_url + "/collections", api_key=api_key)
    existing = {c["name"] for c in resp.get("result", {}).get("collections", [])}

    if collection in existing:
        return "exists: " + collection

    _qdrant_request("PUT", base_url + "/collections/" + collection,
                    body={"vectors": {"text": {"size": int(vector_size), "distance": distance}}},
                    api_key=api_key)
    _qdrant_request("PUT", base_url + "/collections/" + collection + "/index",
                    body={"field_name": "text", "field_schema": {
                        "type": "text", "tokenizer": "word",
                        "min_token_len": 2, "max_token_len": 40,
                        "lowercase": True}},
                    api_key=api_key)
    return "created: " + collection
/

-- 4b. EMBED_AND_PUSH — Embeds text via Ollama/OpenAI and upserts into Qdrant
--
-- ╔══════════════════════════════════════════════════════════════════════════╗
-- ║  SECURITY WARNING: This UDF is DEPRECATED. Use EMBED_AND_PUSH_V2.     ║
-- ║                                                                        ║
-- ║  This UDF accepts API keys (qdrant_api_key, embedding_key) as plain-   ║
-- ║  text SQL parameters. These values appear VERBATIM in Exasol's audit   ║
-- ║  log (EXA_DBA_AUDIT_SQL). Anyone with SELECT access to audit tables    ║
-- ║  can harvest your credentials.                                         ║
-- ║                                                                        ║
-- ║  EMBED_AND_PUSH_V2 (Step 4d below) reads credentials from a           ║
-- ║  CONNECTION object, where passwords are redacted as <SECRET> in        ║
-- ║  audit logs. Always prefer V2 for any environment with API keys.       ║
-- ╚══════════════════════════════════════════════════════════════════════════╝
--
-- Parameters:
--   id             — Unique row identifier (stored as _original_id in Qdrant)
--   text_col       — Text to embed (tip: concatenate multiple columns)
--   qdrant_host    — Qdrant hostname/IP
--   qdrant_port    — Qdrant port (usually 6333)
--   qdrant_api_key — Qdrant API key ('' for no auth) [EXPOSED IN AUDIT LOGS]
--   collection     — Target Qdrant collection name
--   provider       — 'ollama' or 'openai'
--   embedding_key  — Ollama URL (e.g. 'http://172.17.0.1:11434') or OpenAI API key [EXPOSED IN AUDIT LOGS]
--   model_name     — Embedding model name (e.g. 'nomic-embed-text')
--
-- IMPORTANT: Always add GROUP BY IPROC() at the end of your SELECT statement.
CREATE OR REPLACE PYTHON3 SET SCRIPT ADAPTER.EMBED_AND_PUSH(
    id             VARCHAR(255),
    text_col       VARCHAR(65535),
    qdrant_host    VARCHAR(255),
    qdrant_port    INTEGER,
    qdrant_api_key VARCHAR(512),
    collection     VARCHAR(255),
    provider       VARCHAR(32),
    embedding_key  VARCHAR(512),
    model_name     VARCHAR(255)
)
EMITS (partition_id INTEGER, upserted_count INTEGER)
AS
import json
import time
import uuid
import urllib.request
import urllib.error
import hashlib
import socket

BATCH_SIZE = 100
MAX_RETRIES = 3
MAX_CHARS = 6000  # ~1500 tokens, safe for nomic-embed-text (2048 token limit)

def _truncate(texts):
    return [t[:MAX_CHARS] if t and len(t) > MAX_CHARS else (t or "") for t in texts]

def _ollama_embed(texts, ollama_url, model):
    url = ollama_url.rstrip("/") + "/api/embed"
    payload = json.dumps({"model": model, "input": texts}).encode()
    headers = {"Content-Type": "application/json"}
    req = urllib.request.Request(url, data=payload, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req) as resp:
            data = json.loads(resp.read().decode())
            return data["embeddings"]
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return _ollama_embed_one_by_one(texts, ollama_url, model)
        raise RuntimeError("Ollama HTTP " + str(e.code) + " from " + url + ": " + e.read().decode()) from e
    except urllib.error.URLError as e:
        raise RuntimeError("Connection to Ollama at " + url + " failed: " + str(e.reason)) from e

def _ollama_embed_one_by_one(texts, ollama_url, model):
    url = ollama_url.rstrip("/") + "/api/embeddings"
    headers = {"Content-Type": "application/json"}
    vectors = []
    for text in texts:
        payload = json.dumps({"model": model, "prompt": text}).encode()
        req = urllib.request.Request(url, data=payload, headers=headers, method="POST")
        try:
            with urllib.request.urlopen(req) as resp:
                data = json.loads(resp.read().decode())
                vectors.append(data["embedding"])
        except urllib.error.HTTPError as e:
            raise RuntimeError("Ollama HTTP " + str(e.code) + " from " + url + ": " + e.read().decode()) from e
        except urllib.error.URLError as e:
            raise RuntimeError("Connection to Ollama at " + url + " failed: " + str(e.reason)) from e
    return vectors

def _openai_embed(texts, api_key, model):
    url = "https://api.openai.com/v1/embeddings"
    payload = json.dumps({"input": texts, "model": model}).encode()
    headers = {"Content-Type": "application/json", "Authorization": "Bearer " + api_key}
    delay = 1.0
    for attempt in range(1, MAX_RETRIES + 1):
        req = urllib.request.Request(url, data=payload, headers=headers, method="POST")
        try:
            with urllib.request.urlopen(req) as resp:
                data = json.loads(resp.read().decode())
                return [item["embedding"] for item in data["data"]]
        except urllib.error.HTTPError as e:
            status = e.code
            body = e.read().decode()
            if status == 429 and attempt < MAX_RETRIES:
                time.sleep(delay); delay *= 2; continue
            raise RuntimeError("OpenAI HTTP " + str(status) + " from " + url + ": " + body) from e
        except urllib.error.URLError as e:
            raise RuntimeError("Connection to OpenAI at " + url + " failed: " + str(e.reason)) from e
    raise RuntimeError("OpenAI failed after " + str(MAX_RETRIES) + " attempts")

def _text_to_uuid(text_id):
    return str(uuid.uuid5(uuid.NAMESPACE_DNS, str(text_id)))

def _qdrant_upsert(qdrant_url, collection, ids, texts, vectors, api_key):
    points = [{"id": _text_to_uuid(i), "vector": {"text": v}, "payload": {"_original_id": i, "text": t}}
              for i, t, v in zip(ids, texts, vectors)]
    payload = json.dumps({"points": points}).encode()
    headers = {"Content-Type": "application/json"}
    if api_key:
        headers["api-key"] = api_key
    req = urllib.request.Request(qdrant_url + "/collections/" + collection + "/points",
                                  data=payload, headers=headers, method="PUT")
    try:
        with urllib.request.urlopen(req) as resp:
            result = json.loads(resp.read().decode())
            if result.get("status") != "ok":
                raise RuntimeError("Qdrant non-ok: " + str(result))
    except urllib.error.HTTPError as e:
        raise RuntimeError("Qdrant HTTP " + str(e.code) + " from " + qdrant_url + ": " + e.read().decode()) from e
    except urllib.error.URLError as e:
        raise RuntimeError("Connection to Qdrant at " + qdrant_url + " failed: " + str(e.reason)) from e

def run(ctx):
    qdrant_host    = ctx.qdrant_host
    qdrant_port    = int(ctx.qdrant_port)
    qdrant_api_key = ctx.qdrant_api_key or None
    collection     = ctx.collection
    provider       = ctx.provider.lower()
    embedding_key  = ctx.embedding_key or ""
    model_name     = ctx.model_name
    qdrant_url     = "http://" + qdrant_host + ":" + str(qdrant_port)

    if provider not in ("openai", "ollama"):
        raise ValueError("provider must be 'ollama' or 'openai', got: " + provider)

    all_ids, all_texts, skipped_nulls = [], [], 0
    while True:
        row_id   = ctx.id
        row_text = ctx.text_col or ""
        if row_id is None or row_id == "":
            skipped_nulls += 1
        else:
            all_ids.append(row_id)
            all_texts.append(row_text)
        if not ctx.next():
            break
    if skipped_nulls > 0 and len(all_ids) == 0:
        raise ValueError("All " + str(skipped_nulls) + " rows have NULL or empty IDs. Provide a non-empty ID column.")


    total = 0
    for i in range(0, len(all_ids), BATCH_SIZE):
        batch_ids   = all_ids[i:i+BATCH_SIZE]
        batch_texts = all_texts[i:i+BATCH_SIZE]

        if provider == "ollama":
            vectors = _ollama_embed(_truncate(batch_texts), embedding_key, model_name)
        else:
            vectors = _openai_embed(_truncate(batch_texts), embedding_key, model_name)

        _qdrant_upsert(qdrant_url, collection, batch_ids, batch_texts, vectors, qdrant_api_key)
        total += len(batch_ids)

    partition_id = int(hashlib.md5(socket.gethostname().encode()).hexdigest(), 16) % 65536
    ctx.emit(partition_id, total)
/


-- 4c. EMBEDDING_CONNECTION — Stores infrastructure config for simplified UDF
--
-- The connection address stores a JSON config blob. The password field stores
-- the Qdrant API key (or '' for no auth). This keeps credentials out of SQL
-- text and out of EXA_DBA_AUDIT_SQL.
--
-- Required keys: qdrant_url, ollama_url, provider, model
-- Optional tuning keys:
--   batch_size  — Number of texts to embed per API call (default: 100)
--   max_chars   — Max characters per text before truncation (default: 6000, ~1500 tokens)
--
-- Update the JSON values below for your environment:
CREATE OR REPLACE CONNECTION embedding_conn
    TO '{"qdrant_url":"http://172.17.0.1:6333","ollama_url":"http://172.17.0.1:11434","provider":"ollama","model":"nomic-embed-text"}'
    USER ''
    IDENTIFIED BY '';

-- 4d. EMBED_AND_PUSH_V2 — Simplified 4-parameter version using CONNECTION
--
-- Usage:
--   SELECT ADAPTER.EMBED_AND_PUSH_V2(
--       'embedding_conn',                  -- connection name (stores all config)
--       'my_collection',                   -- target collection
--       CAST(id_col AS VARCHAR(255)),      -- unique ID
--       text_col                           -- text to embed
--   )
--   FROM my_schema.my_table
--   GROUP BY IPROC();  -- REQUIRED for SET UDFs
--
CREATE OR REPLACE PYTHON3 SET SCRIPT ADAPTER.EMBED_AND_PUSH_V2(
    connection_name VARCHAR(255),
    collection      VARCHAR(255),
    id              VARCHAR(255),
    text_col        VARCHAR(65535)
)
EMITS (partition_id INTEGER, upserted_count INTEGER)
AS
import json
import time
import uuid
import urllib.request
import urllib.error
import hashlib
import socket

BATCH_SIZE = 100
MAX_RETRIES = 3
MAX_CHARS = 6000

def _truncate(texts):
    return [t[:MAX_CHARS] if t and len(t) > MAX_CHARS else (t or "") for t in texts]

def _ollama_embed(texts, ollama_url, model):
    url = ollama_url.rstrip("/") + "/api/embed"
    payload = json.dumps({"model": model, "input": texts}).encode()
    headers = {"Content-Type": "application/json"}
    req = urllib.request.Request(url, data=payload, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req) as resp:
            data = json.loads(resp.read().decode())
            return data["embeddings"]
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return _ollama_embed_one_by_one(texts, ollama_url, model)
        raise RuntimeError("Ollama HTTP " + str(e.code) + " from " + url + ": " + e.read().decode()) from e
    except urllib.error.URLError as e:
        raise RuntimeError("Connection to Ollama at " + url + " failed: " + str(e.reason)) from e

def _ollama_embed_one_by_one(texts, ollama_url, model):
    url = ollama_url.rstrip("/") + "/api/embeddings"
    headers = {"Content-Type": "application/json"}
    vectors = []
    for text in texts:
        payload = json.dumps({"model": model, "prompt": text}).encode()
        req = urllib.request.Request(url, data=payload, headers=headers, method="POST")
        try:
            with urllib.request.urlopen(req) as resp:
                data = json.loads(resp.read().decode())
                vectors.append(data["embedding"])
        except urllib.error.HTTPError as e:
            raise RuntimeError("Ollama HTTP " + str(e.code) + " from " + url + ": " + e.read().decode()) from e
        except urllib.error.URLError as e:
            raise RuntimeError("Connection to Ollama at " + url + " failed: " + str(e.reason)) from e
    return vectors

def _openai_embed(texts, api_key, model):
    url = "https://api.openai.com/v1/embeddings"
    payload = json.dumps({"input": texts, "model": model}).encode()
    headers = {"Content-Type": "application/json", "Authorization": "Bearer " + api_key}
    delay = 1.0
    for attempt in range(1, MAX_RETRIES + 1):
        req = urllib.request.Request(url, data=payload, headers=headers, method="POST")
        try:
            with urllib.request.urlopen(req) as resp:
                data = json.loads(resp.read().decode())
                return [item["embedding"] for item in data["data"]]
        except urllib.error.HTTPError as e:
            status = e.code
            body = e.read().decode()
            if status == 429 and attempt < MAX_RETRIES:
                time.sleep(delay); delay *= 2; continue
            raise RuntimeError("OpenAI HTTP " + str(status) + " from " + url + ": " + body) from e
        except urllib.error.URLError as e:
            raise RuntimeError("Connection to OpenAI at " + url + " failed: " + str(e.reason)) from e
    raise RuntimeError("OpenAI failed after " + str(MAX_RETRIES) + " attempts")

def _text_to_uuid(text_id):
    return str(uuid.uuid5(uuid.NAMESPACE_DNS, str(text_id)))

def _qdrant_upsert(qdrant_url, collection, ids, texts, vectors, api_key):
    points = [{"id": _text_to_uuid(i), "vector": {"text": v}, "payload": {"_original_id": i, "text": t}}
              for i, t, v in zip(ids, texts, vectors)]
    payload = json.dumps({"points": points}).encode()
    headers = {"Content-Type": "application/json"}
    if api_key:
        headers["api-key"] = api_key
    req = urllib.request.Request(qdrant_url + "/collections/" + collection + "/points",
                                  data=payload, headers=headers, method="PUT")
    try:
        with urllib.request.urlopen(req) as resp:
            result = json.loads(resp.read().decode())
            if result.get("status") != "ok":
                raise RuntimeError("Qdrant non-ok: " + str(result))
    except urllib.error.HTTPError as e:
        raise RuntimeError("Qdrant HTTP " + str(e.code) + " from " + qdrant_url + ": " + e.read().decode()) from e
    except urllib.error.URLError as e:
        raise RuntimeError("Connection to Qdrant at " + qdrant_url + " failed: " + str(e.reason)) from e

def run(ctx):
    # Read config from CONNECTION object
    conn_name = ctx.connection_name
    conn = exa.get_connection(conn_name)
    config = json.loads(conn.address)

    qdrant_url  = config.get("qdrant_url")
    if not qdrant_url:
        raise ValueError("CONNECTION config missing 'qdrant_url'. Set it to the Qdrant endpoint reachable from inside Exasol (e.g. 'http://172.17.0.1:6333').")
    ollama_url  = config.get("ollama_url")
    if not ollama_url:
        raise ValueError("CONNECTION config missing 'ollama_url'. Set it to the Ollama endpoint reachable from inside Exasol (e.g. 'http://172.17.0.1:11434'). Do NOT use 'localhost'.")
    provider    = config.get("provider", "ollama").lower()
    model_name  = config.get("model", "nomic-embed-text")
    api_key     = conn.password if conn.password else config.get("qdrant_api_key", "")
    embedding_key = config.get("openai_api_key", "") if provider == "openai" else ollama_url

    # Performance tuning knobs (configurable via CONNECTION JSON)
    global BATCH_SIZE, MAX_CHARS
    BATCH_SIZE = int(config.get("batch_size", BATCH_SIZE))
    MAX_CHARS  = int(config.get("max_chars", MAX_CHARS))

    collection = ctx.collection

    if provider not in ("openai", "ollama"):
        raise ValueError("provider must be 'ollama' or 'openai', got: " + provider)

    all_ids, all_texts, skipped_nulls = [], [], 0
    while True:
        row_id   = ctx.id
        row_text = ctx.text_col or ""
        if row_id is None or row_id == "":
            skipped_nulls += 1
        else:
            all_ids.append(row_id)
            all_texts.append(row_text)
        if not ctx.next():
            break
    if skipped_nulls > 0 and len(all_ids) == 0:
        raise ValueError("All " + str(skipped_nulls) + " rows have NULL or empty IDs.")

    total = 0
    for i in range(0, len(all_ids), BATCH_SIZE):
        batch_ids   = all_ids[i:i+BATCH_SIZE]
        batch_texts = all_texts[i:i+BATCH_SIZE]

        if provider == "ollama":
            vectors = _ollama_embed(_truncate(batch_texts), embedding_key, model_name)
        else:
            vectors = _openai_embed(_truncate(batch_texts), embedding_key, model_name)

        _qdrant_upsert(qdrant_url, collection, batch_ids, batch_texts, vectors, api_key)
        total += len(batch_ids)

    partition_id = int(hashlib.md5(socket.gethostname().encode()).hexdigest(), 16) % 65536
    ctx.emit(partition_id, total)
/


-- 4e. PREFLIGHT_CHECK — Verify Qdrant + Ollama connectivity before deploying
--
-- Usage:
--   SELECT ADAPTER.PREFLIGHT_CHECK('http://172.17.0.1:6333', 'http://172.17.0.1:11434', 'nomic-embed-text');
--
-- Returns a structured pass/fail report as a single VARCHAR value.
CREATE OR REPLACE PYTHON3 SCALAR SCRIPT ADAPTER.PREFLIGHT_CHECK(
    qdrant_url  VARCHAR(512),
    ollama_url  VARCHAR(512),
    model_name  VARCHAR(255)
)
RETURNS VARCHAR(2000000)
AS
import json
import urllib.request
import urllib.error

def _http_get(url, timeout=10):
    req = urllib.request.Request(url, method="GET")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read().decode()), None
    except urllib.error.HTTPError as e:
        return None, "HTTP " + str(e.code) + ": " + e.read().decode()
    except urllib.error.URLError as e:
        return None, "Connection failed: " + str(e.reason)
    except Exception as e:
        return None, str(e)

def _http_post(url, payload, timeout=30):
    data = json.dumps(payload).encode()
    req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"}, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read().decode()), None
    except urllib.error.HTTPError as e:
        return None, "HTTP " + str(e.code) + ": " + e.read().decode()
    except urllib.error.URLError as e:
        return None, "Connection failed: " + str(e.reason)
    except Exception as e:
        return None, str(e)

def run(ctx):
    if not ctx.qdrant_url or ctx.qdrant_url.strip() == "":
        raise ValueError("qdrant_url is required. Use the IP reachable from inside Exasol (e.g. '172.17.0.1'). Do NOT use 'localhost'.")
    if not ctx.ollama_url or ctx.ollama_url.strip() == "":
        raise ValueError("ollama_url is required. Use the IP reachable from inside Exasol (e.g. 'http://172.17.0.1:11434'). Do NOT use 'localhost'.")
    qdrant_url = ctx.qdrant_url.rstrip("/")
    ollama_url = ctx.ollama_url.rstrip("/")
    model_name = ctx.model_name or "nomic-embed-text"

    checks = []
    all_pass = True

    # Check 1: Qdrant connectivity
    data, err = _http_get(qdrant_url + "/collections")
    if err:
        checks.append("[FAIL] Qdrant (" + qdrant_url + "): " + err)
        all_pass = False
    else:
        collections = [c["name"] for c in data.get("result", {}).get("collections", [])]
        checks.append("[PASS] Qdrant: reachable, " + str(len(collections)) + " collection(s): " + ", ".join(collections[:5]))

    # Check 2: Ollama connectivity
    data, err = _http_get(ollama_url + "/api/tags")
    if err:
        checks.append("[FAIL] Ollama (" + ollama_url + "): " + err)
        all_pass = False
    else:
        models = [m["name"] for m in data.get("models", [])]
        checks.append("[PASS] Ollama: reachable, models: " + ", ".join(models[:5]))

        # Check 3: Model availability
        model_found = any(model_name in m for m in models)
        if model_found:
            checks.append("[PASS] Model '" + model_name + "': available")
        else:
            checks.append("[FAIL] Model '" + model_name + "': NOT found. Available: " + ", ".join(models))
            all_pass = False

    # Check 4: Embedding round-trip
    data, err = _http_post(ollama_url + "/api/embeddings", {"model": model_name, "prompt": "preflight test"})
    if err:
        checks.append("[FAIL] Embedding test: " + err)
        all_pass = False
    elif data and data.get("embedding"):
        dim = len(data["embedding"])
        checks.append("[PASS] Embedding test: " + str(dim) + "-dimensional vector returned")
    else:
        checks.append("[FAIL] Embedding test: no embedding in response")
        all_pass = False

    # Build report
    status = "ALL CHECKS PASSED" if all_pass else "SOME CHECKS FAILED"
    report = "=== PREFLIGHT CHECK: " + status + " ===\n"
    for c in checks:
        report += c + "\n"
    if not all_pass:
        report += "\nTroubleshooting:\n"
        report += "- Ensure Qdrant and Ollama are running and accessible from inside Exasol\n"
        report += "- Docker bridge IP is typically 172.17.0.1 (find with: docker exec <exasol> ip route show default)\n"
        report += "- Pull missing models with: docker exec ollama ollama pull " + model_name + "\n"

    return report
/


-- ┌───────────────────────────────────────────────────────────────────────────┐
-- │ STEP 5: Create virtual schema                                            │
-- └───────────────────────────────────────────────────────────────────────────┘
-- This maps all Qdrant collections as queryable Exasol tables.
-- After creating, each collection appears as a table with columns:
--   ID (VARCHAR), TEXT (VARCHAR), SCORE (DOUBLE), QUERY (VARCHAR)

-- DROP + CREATE is used instead of IF NOT EXISTS because Exasol cannot
-- update virtual schema properties in-place. This is safe — dropping a
-- virtual schema does NOT delete Qdrant data (it is just a metadata mapping).
--
-- IMPORTANT: We use DROP FORCE (not CASCADE) for two reasons:
--   1. CASCADE can destroy the ADAPTER schema (scripts, connections, everything)
--   2. Regular DROP sometimes leaves ghost metadata that blocks the next CREATE
--      (Exasol platform bug — session-level metadata caching). DROP FORCE
--      resolves this reliably.
--
-- If CREATE still fails with "already exists" after DROP FORCE, disconnect
-- and reconnect your SQL session, then re-run from this point.
DROP FORCE VIRTUAL SCHEMA IF EXISTS vector_schema;

CREATE VIRTUAL SCHEMA vector_schema
    USING ADAPTER.VECTOR_SCHEMA_ADAPTER
    WITH CONNECTION_NAME = 'qdrant_conn'
         QDRANT_MODEL    = 'nomic-embed-text'
         OLLAMA_URL      = 'http://172.17.0.1:11434';


-- ┌───────────────────────────────────────────────────────────────────────────┐
-- │ NOTE: No explicit REFRESH needed                                         │
-- └───────────────────────────────────────────────────────────────────────────┘
-- CREATE VIRTUAL SCHEMA already performs an implicit refresh. Adding an
-- explicit ALTER VIRTUAL SCHEMA REFRESH here is redundant and can trigger
-- the ghost-state metadata caching bug on re-runs. If you need to refresh
-- later (e.g., after adding new Qdrant collections), run:
--   ALTER VIRTUAL SCHEMA vector_schema REFRESH;


-- =============================================================================
-- INSTALLATION COMPLETE!
-- =============================================================================
--
-- USAGE EXAMPLES:
--
-- ── Semantic Search ──────────────────────────────────────────────────────────
--
--   SELECT "ID", "TEXT", "SCORE"
--   FROM vector_schema.<collection_name>
--   WHERE "QUERY" = 'your natural language search'
--   LIMIT 10;
--
-- ── Create a Qdrant Collection ──────────────────────────────────────────────
--
--   SELECT ADAPTER.CREATE_QDRANT_COLLECTION(
--       '172.17.0.1', 6333, '',         -- Qdrant host, port, API key
--       'my_collection',                 -- collection name
--       768, 'Cosine',                   -- vector size, distance metric
--       'nomic-embed-text'               -- model (auto-detects dimensions)
--   );
--
-- ── Ingest Data from an Exasol Table (V2 — recommended) ─────────────────────
--
--   V2 reads config from a CONNECTION object. Credentials are stored in the
--   CONNECTION password field, which Exasol redacts as <SECRET> in audit logs.
--
--   SELECT ADAPTER.EMBED_AND_PUSH_V2(
--       'embedding_conn',                 -- connection name (stores all config)
--       'my_collection',                  -- target collection
--       CAST(row_number AS VARCHAR(36)),  -- unique ID column
--       "name" || ' in ' || "city"        -- text to embed (concatenate columns)
--   )
--   FROM my_schema.my_table
--   GROUP BY IPROC();  -- REQUIRED for SET UDFs
--
--   -- Then refresh to see the new collection:
--   ALTER VIRTUAL SCHEMA vector_schema REFRESH;
--
-- ── Ingest Data (V1 — legacy, NOT recommended) ─────────────────────────────
--
--   WARNING: V1 passes API keys as plain-text SQL parameters. These appear
--   verbatim in EXA_DBA_AUDIT_SQL. Use V2 above instead.
--
--   SELECT ADAPTER.EMBED_AND_PUSH(
--       CAST(row_number AS VARCHAR(36)), -- unique ID column
--       "name" || ' in ' || "city",      -- text to embed (concatenate columns)
--       '172.17.0.1', 6333, '',          -- Qdrant host, port, API key
--       'my_collection',                  -- target collection
--       'ollama',                         -- provider ('ollama' or 'openai')
--       'http://<OLLAMA_IP>:11434',       -- Ollama URL
--       'nomic-embed-text'                -- embedding model
--   )
--   FROM my_schema.my_table
--   GROUP BY IPROC();
--
-- ── Hello World (quick test) ─────────────────────────────────────────────────
--
--   Run this after installing to verify everything works:
--
--   CREATE OR REPLACE TABLE ADAPTER.hello_world (
--       id DECIMAL(5,0), doc VARCHAR(200)
--   );
--   INSERT INTO ADAPTER.hello_world VALUES (1, 'The quick brown fox jumps over the lazy dog');
--   INSERT INTO ADAPTER.hello_world VALUES (2, 'A fast red car drives down the highway');
--   INSERT INTO ADAPTER.hello_world VALUES (3, 'Machine learning predicts stock trends');
--   INSERT INTO ADAPTER.hello_world VALUES (4, 'The chef prepared delicious pasta');
--   INSERT INTO ADAPTER.hello_world VALUES (5, 'Neural networks mimic brain structures');
--
--   SELECT ADAPTER.CREATE_QDRANT_COLLECTION('172.17.0.1', 6333, '', 'hello_world', 768, 'Cosine', '');
--
--   SELECT ADAPTER.EMBED_AND_PUSH_V2(
--       'embedding_conn', 'hello_world',
--       CAST(ID AS VARCHAR(36)), DOC
--   ) FROM ADAPTER.hello_world GROUP BY IPROC();
--
--   ALTER VIRTUAL SCHEMA vector_schema REFRESH;
--
--   SELECT "ID", "TEXT", "SCORE"
--   FROM vector_schema.hello_world
--   WHERE "QUERY" = 'artificial intelligence'
--   LIMIT 5;
--
-- =============================================================================
