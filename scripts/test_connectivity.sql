-- =============================================================================
-- test_connectivity.sql — Pre-flight checks for Qdrant + Ollama connectivity
-- =============================================================================
-- Run these tests to verify Exasol can reach Qdrant and Ollama before
-- deploying the adapter. Update the IPs/ports below if your setup differs.
--
-- Usage:
--   SELECT ADAPTER.TEST_OLLAMA();
--   SELECT ADAPTER.TEST_QDRANT();
--   SELECT ADAPTER.TEST_EMBED('hello world');
--   SELECT ADAPTER.TEST_QDRANT_SEARCH('your_collection', 'search text');
-- =============================================================================


-- Test 1: Can Exasol reach Ollama?
CREATE OR REPLACE LUA SCALAR SCRIPT ADAPTER.TEST_OLLAMA()
RETURNS VARCHAR(2000000) AS
local http  = require("socket.http")
local ltn12 = require("ltn12")
function run(ctx)
    local chunks = {}
    local _, code = http.request({
        url  = "http://172.17.0.1:11434/api/tags",
        method = "GET",
        sink = ltn12.sink.table(chunks)
    })
    return "HTTP " .. tostring(code) .. " | " .. table.concat(chunks):sub(1, 300)
end
/

-- Test 2: Can Exasol reach Qdrant?
CREATE OR REPLACE LUA SCALAR SCRIPT ADAPTER.TEST_QDRANT()
RETURNS VARCHAR(2000000) AS
local http  = require("socket.http")
local ltn12 = require("ltn12")
function run(ctx)
    local chunks = {}
    local _, code = http.request({
        url  = "http://172.17.0.1:6333/collections",
        method = "GET",
        sink = ltn12.sink.table(chunks)
    })
    return "HTTP " .. tostring(code) .. " | " .. table.concat(chunks):sub(1, 300)
end
/

-- Test 3: Can Exasol embed via Ollama?
CREATE OR REPLACE LUA SCALAR SCRIPT ADAPTER.TEST_EMBED(query VARCHAR(2000000))
RETURNS VARCHAR(2000000) AS
local http  = require("socket.http")
local ltn12 = require("ltn12")
local cjson = require("cjson")
function run(ctx)
    local body = cjson.encode({model="nomic-embed-text", prompt=ctx[1]})
    local chunks = {}
    local _, code = http.request({
        url    = "http://172.17.0.1:11434/api/embeddings",
        method = "POST",
        headers = {["Content-Type"]="application/json", ["Content-Length"]=tostring(#body)},
        source  = ltn12.source.string(body),
        sink    = ltn12.sink.table(chunks)
    })
    local resp = table.concat(chunks)
    local ok, parsed = pcall(cjson.decode, resp)
    if ok and parsed.embedding then
        return "OK - got embedding of size " .. tostring(#parsed.embedding)
    end
    return "HTTP " .. tostring(code) .. " | " .. resp:sub(1, 300)
end
/

-- Test 4: End-to-end search against a specific Qdrant collection
CREATE OR REPLACE LUA SCALAR SCRIPT ADAPTER.TEST_QDRANT_SEARCH(collection VARCHAR(255), query VARCHAR(2000000))
RETURNS VARCHAR(2000000) AS
local http  = require("socket.http")
local ltn12 = require("ltn12")
local cjson = require("cjson")
function run(ctx)
    local collection = ctx[1]
    local query_text = ctx[2]

    -- Step 1: get embedding from Ollama
    local emb_req = cjson.encode({model="nomic-embed-text", prompt=query_text})
    local c1 = {}
    local _, code1 = http.request({
        url     = "http://172.17.0.1:11434/api/embeddings",
        method  = "POST",
        headers = {["Content-Type"]="application/json", ["Content-Length"]=tostring(#emb_req)},
        source  = ltn12.source.string(emb_req),
        sink    = ltn12.sink.table(c1)
    })
    local emb_resp = table.concat(c1)
    local ok, parsed = pcall(cjson.decode, emb_resp)
    if not ok or not parsed.embedding then
        return "Ollama error: HTTP " .. tostring(code1) .. " | " .. emb_resp:sub(1, 300)
    end

    -- Step 2: search Qdrant
    local emb_json = cjson.encode(parsed.embedding)
    local search_body = string.format(
        '{"query":%s,"using":"text","limit":5,"with_payload":true}',
        emb_json
    )
    local h = {["Content-Type"]="application/json", ["Content-Length"]=tostring(#search_body)}
    local c2 = {}
    local _, code2 = http.request({
        url     = "http://172.17.0.1:6333/collections/" .. collection .. "/points/query",
        method  = "POST",
        headers = h,
        source  = ltn12.source.string(search_body),
        sink    = ltn12.sink.table(c2)
    })
    local qdrant_resp = table.concat(c2)
    return "Qdrant HTTP " .. tostring(code2) .. " | " .. qdrant_resp:sub(1, 500)
end
/
