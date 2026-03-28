-- Test 1: Can Exasol reach Ollama?
CREATE OR REPLACE LUA SCALAR SCRIPT ADAPTER.TEST_OLLAMA()
RETURNS VARCHAR(2000000) AS
local http  = require("socket.http")
local ltn12 = require("ltn12")
function run(ctx)
    local chunks = {}
    local _, code = http.request({
        url  = "http://172.17.0.1:11435/api/tags",
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
        url    = "http://172.17.0.1:11435/api/embeddings",
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

-- Test 4: Show exactly what we send to Qdrant (without actually sending)
CREATE OR REPLACE LUA SCALAR SCRIPT ADAPTER.TEST_SEARCH_BODY(query VARCHAR(2000000))
RETURNS VARCHAR(2000000) AS
local http  = require("socket.http")
local ltn12 = require("ltn12")
local cjson = require("cjson")
function run(ctx)
    -- Get real embedding from Ollama
    local body = cjson.encode({model="nomic-embed-text", prompt=ctx[1]})
    local chunks = {}
    local _, code = http.request({
        url    = "http://172.17.0.1:11435/api/embeddings",
        method = "POST",
        headers = {["Content-Type"]="application/json", ["Content-Length"]=tostring(#body)},
        source  = ltn12.source.string(body),
        sink    = ltn12.sink.table(chunks)
    })
    local resp = table.concat(chunks)
    local parsed = cjson.decode(resp)
    local embedding = parsed.embedding

    -- Build and encode the search request exactly as the adapter does
    local search_body = cjson.encode({
        query        = embedding,
        using        = "text",
        limit        = 5,
        with_payload = true
    })

    -- Show first 500 chars of what we'd send
    return "body_len=" .. #search_body .. " | first300=" .. search_body:sub(1, 300)
end
/

-- Test 5: Actually send the search request to Qdrant and show the raw response
CREATE OR REPLACE LUA SCALAR SCRIPT ADAPTER.TEST_QDRANT_SEARCH(query VARCHAR(2000000))
RETURNS VARCHAR(2000000) AS
local http  = require("socket.http")
local ltn12 = require("ltn12")
local cjson = require("cjson")
function run(ctx)
    -- Step 1: get embedding from Ollama
    local emb_req = cjson.encode({model="nomic-embed-text", prompt=ctx[1]})
    local c1 = {}
    local _, code1 = http.request({
        url     = "http://172.17.0.1:11435/api/embeddings",
        method  = "POST",
        headers = {["Content-Type"]="application/json", ["Content-Length"]=tostring(#emb_req)},
        source  = ltn12.source.string(emb_req),
        sink    = ltn12.sink.table(c1)
    })
    local emb_resp = table.concat(c1)
    local parsed = cjson.decode(emb_resp)
    local embedding = parsed.embedding

    -- Step 2: encode embedding separately, then build body with string.format
    local emb_json = cjson.encode(embedding)
    local search_body = string.format(
        '{"query":%s,"using":"text","limit":5,"with_payload":true}',
        emb_json
    )

    -- Step 3: POST to Qdrant and return raw response
    local h = {["Content-Type"]="application/json", ["Content-Length"]=tostring(#search_body)}
    local c2 = {}
    local _, code2 = http.request({
        url     = "http://172.17.0.1:6333/collections/modapte/points/query",
        method  = "POST",
        headers = h,
        source  = ltn12.source.string(search_body),
        sink    = ltn12.sink.table(c2)
    })
    local qdrant_resp = table.concat(c2)
    return "HTTP " .. tostring(code2) .. " | body_prefix=" .. search_body:sub(1,80) .. " | resp=" .. qdrant_resp:sub(1,500)
end
/
