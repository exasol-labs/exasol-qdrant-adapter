-- =============================================================================
-- install_all.sql — One-File Installer for Exasol Qdrant Vector Search Adapter
-- =============================================================================
--
-- This single file deploys the complete semantic search stack:
--   1. ADAPTER schema for adapter scripts and UDFs
--   2. CONNECTION objects for Qdrant (used by both the Lua adapter and the
--      ingest/search UDFs)
--   3. PYTHON3_QDRANT script-language alias for the qdrant-embed SLC
--   4. Lua adapter script (virtual schema engine; rewrites pushdown to a
--      call to ADAPTER.SEARCH_QDRANT_LOCAL)
--   5. Python UDFs:
--        - CREATE_QDRANT_COLLECTION (scalar)
--        - EMBED_AND_PUSH_LOCAL     (set, in-process via SLC — ingest path)
--        - EMBED_TEXT               (scalar, in-process via SLC — utility)
--        - SEARCH_QDRANT_LOCAL      (set, in-process via SLC — query path)
--        - PREFLIGHT_CHECK          (scalar)
--   6. Virtual schema (no OLLAMA_URL property — query embeddings happen
--      in-database via ADAPTER.SEARCH_QDRANT_LOCAL)
--
-- INSTRUCTIONS:
--   1. Update the IP/port/connection values below for your environment
--   2. Make sure the qdrant-embed SLC and nomic-embed-text-v1.5 model are
--      already in BucketFS (run scripts/build_and_upload_slc.sh once if not)
--   3. Run this entire file in your SQL client (DBeaver, DbVisualizer, etc.)
--   4. Re-running this script is safe — every statement is idempotent
--      (CREATE OR REPLACE / IF NOT EXISTS / DROP FORCE IF EXISTS)
--
-- Prerequisites:
--   - Exasol 7.x+ running (Docker: docker run -d --name exasoldb -p 8563:8563 --privileged exasol/docker-db:latest)
--     Wait ~90 seconds for initialisation. Connect: host=localhost, port=8563, user=sys, password=exasol
--   - Qdrant 1.9+ accessible from inside Exasol (Docker: docker run -d --name qdrant -p 6333:6333 qdrant/qdrant)
--   - qdrant-embed SLC + nomic-embed-text-v1.5 model in BucketFS
--     (run ./scripts/build_and_upload_slc.sh once)
--
--   No Ollama required. The query path embeds and searches in-database via
--   the ADAPTER.SEARCH_QDRANT_LOCAL set UDF, sharing the same SLC + model
--   as the ingest path.
--
-- Docker networking note:
--   Inside Exasol's container, use the Docker bridge gateway IP (typically
--   172.17.0.1) to reach services on the host. Find it with:
--     docker exec exasoldb ip route show default
--   host.docker.internal does NOT work in Exasol's UDF sandbox on Linux.
--
-- Migrating from earlier versions:
--   If you previously deployed this adapter with OLLAMA_URL or used
--   ADAPTER.EMBED_AND_PUSH / EMBED_AND_PUSH_V2:
--     1. DROP FORCE VIRTUAL SCHEMA IF EXISTS vector_schema;
--     2. Re-run this file (it removes the old UDFs and replaces the adapter)
--     3. Re-ingest into a fresh Qdrant collection via EMBED_AND_PUSH_LOCAL
--        (the on-disk vectors from Ollama-backed ingest are not interchangeable
--        with SLC-backed vectors in a single collection — see
--        docs/local-embeddings.md for the parity hazard details)
--     4. Stop and remove the Ollama container: docker rm -f ollama
-- =============================================================================


-- ┌───────────────────────────────────────────────────────────────────────────┐
-- │ STEP 1: Create schema                                                     │
-- └───────────────────────────────────────────────────────────────────────────┘

CREATE SCHEMA IF NOT EXISTS ADAPTER;
OPEN SCHEMA ADAPTER;


-- ┌───────────────────────────────────────────────────────────────────────────┐
-- │ STEP 2: Create connection objects                                         │
-- └───────────────────────────────────────────────────────────────────────────┘
-- qdrant_conn — used by the Lua adapter (virtual schema). The address is the
-- raw Qdrant base URL; password is the Qdrant API key (or '' for no auth).

CREATE OR REPLACE CONNECTION qdrant_conn
    TO 'http://172.17.0.1:6333'
    USER ''
    IDENTIFIED BY '';

-- embedding_conn — used by EMBED_AND_PUSH_LOCAL. The address is a JSON config
-- blob that holds the Qdrant URL (and optionally the API key). The password
-- field is redacted as <SECRET> in audit logs, so prefer it for API keys.

CREATE OR REPLACE CONNECTION embedding_conn
    TO '{"qdrant_url":"http://172.17.0.1:6333"}'
    USER ''
    IDENTIFIED BY '';


-- ┌───────────────────────────────────────────────────────────────────────────┐
-- │ STEP 3: Register the PYTHON3_QDRANT script-language alias                 │
-- └───────────────────────────────────────────────────────────────────────────┘
-- Points at the qdrant-embed SLC in BucketFS. EMBED_AND_PUSH_LOCAL and
-- EMBED_TEXT both run under this alias and share one in-VM model load.
--
-- ALTER SYSTEM SET SCRIPT_LANGUAGES is REPLACING (not appending). If your
-- cluster already has other custom aliases, edit this string to include them.
-- The default Exasol aliases (PYTHON3, R, JAVA) are kept first to preserve
-- baseline behaviour.

ALTER SYSTEM SET SCRIPT_LANGUAGES =
    'PYTHON3=builtin_python3 R=builtin_r JAVA=builtin_java '
    'PYTHON3_QDRANT=localzmq+protobuf:///bfsdefault/default/slc/qdrant-embed'
    '?lang=python#buckets/bfsdefault/default/slc/qdrant-embed/exaudf/exaudfclient';


-- ┌───────────────────────────────────────────────────────────────────────────┐
-- │ STEP 4: Deploy Lua adapter script                                         │
-- └───────────────────────────────────────────────────────────────────────────┘
-- The virtual schema engine. It:
--   - Discovers Qdrant collections as virtual tables (HTTP GET /collections)
--   - Rewrites pushdown queries to a SQL call to ADAPTER.SEARCH_QDRANT_LOCAL,
--     which owns the embed + Qdrant search work.
--
-- Why a SET UDF and not pquery directly:
--   Exasol forbids exa.pquery_no_preprocessing during virtual schema pushdown
--   (it would re-enter the SQL planner and create cycles). The canonical
--   workaround is a row-emitting UDF that the adapter targets via generated
--   SQL — that's ADAPTER.SEARCH_QDRANT_LOCAL.
--
-- Fixed 4-column schema per virtual table: ID, TEXT, SCORE, QUERY
-- Properties: CONNECTION_NAME (required), QDRANT_MODEL (required),
--             QDRANT_URL (optional override), COLLECTION_FILTER (optional).
--             OLLAMA_URL is rejected — it is no longer a valid property.

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


-- ┌───────────────────────────────────────────────────────────────────────────┐
-- │ STEP 5: CREATE_QDRANT_COLLECTION — create a Qdrant collection             │
-- └───────────────────────────────────────────────────────────────────────────┘

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
    "nomic-embed-text-v1.5":     768,
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


-- ┌───────────────────────────────────────────────────────────────────────────┐
-- │ STEP 6: EMBED_AND_PUSH_LOCAL — in-process embedding ingest (SLC)         │
-- └───────────────────────────────────────────────────────────────────────────┘
-- Reads Qdrant config from CONNECTION (qdrant_url, optional qdrant_api_key).
-- Embeds rows in-process via sentence-transformers + nomic-embed-text-v1.5.
-- No external embedding service required.

CREATE OR REPLACE PYTHON3_QDRANT SET SCRIPT ADAPTER.EMBED_AND_PUSH_LOCAL(
    connection_name VARCHAR(200),
    collection      VARCHAR(200),
    id              VARCHAR(255),
    text_col        VARCHAR(2000000)
)
EMITS (partition_id INTEGER, upserted_count INTEGER)
AS
import os
os.environ["HF_HUB_OFFLINE"] = "1"
os.environ["TRANSFORMERS_OFFLINE"] = "1"
os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")

import hashlib
import json
import socket
import urllib.error
import urllib.request
import uuid

from sentence_transformers import SentenceTransformer

MODEL_NAME = "nomic-embed-text-v1.5"
MODEL_PATH = "/buckets/bfsdefault/default/models/" + MODEL_NAME

BATCH_SIZE = 64
MAX_CHARS = 6000

_model = SentenceTransformer(MODEL_PATH, device="cpu", trust_remote_code=True)


def _truncate(text):
    if not text:
        return ""
    return text[:MAX_CHARS] if len(text) > MAX_CHARS else text


def _text_to_uuid(text_id):
    return str(uuid.uuid5(uuid.NAMESPACE_DNS, str(text_id)))


def _qdrant_upsert(qdrant_url, api_key, collection, ids, texts, vectors):
    points = [
        {"id": _text_to_uuid(i), "vector": {"text": v},
         "payload": {"_original_id": i, "text": t}}
        for i, t, v in zip(ids, texts, vectors)
    ]
    payload = json.dumps({"points": points}).encode()
    headers = {"Content-Type": "application/json"}
    if api_key:
        headers["api-key"] = api_key
    url = qdrant_url.rstrip("/") + "/collections/" + collection + "/points"
    req = urllib.request.Request(url, data=payload, headers=headers, method="PUT")
    try:
        with urllib.request.urlopen(req) as resp:
            result = json.loads(resp.read().decode())
            if result.get("status") != "ok":
                raise RuntimeError("Qdrant non-ok: " + str(result))
    except urllib.error.HTTPError as e:
        raise RuntimeError("Qdrant HTTP " + str(e.code) + " from " + url + ": " + e.read().decode()) from e
    except urllib.error.URLError as e:
        raise RuntimeError("Connection to Qdrant at " + url + " failed: " + str(e.reason)) from e


def run(ctx):
    conn = exa.get_connection(ctx.connection_name)
    config = json.loads(conn.address)
    qdrant_url = config.get("qdrant_url")
    if not qdrant_url:
        raise ValueError("CONNECTION config missing 'qdrant_url'.")
    qdrant_api_key = conn.password if conn.password else config.get("qdrant_api_key", "")
    collection = ctx.collection

    all_ids, all_texts, skipped = [], [], 0
    while True:
        row_id = ctx.id
        row_text = ctx.text_col or ""
        if row_id is None or row_id == "" or row_text == "":
            skipped += 1
        else:
            all_ids.append(row_id)
            all_texts.append(_truncate(row_text))
        if not ctx.next():
            break

    if skipped > 0 and len(all_ids) == 0:
        raise ValueError("All " + str(skipped) + " rows had NULL/empty id or text.")

    total = 0
    for start in range(0, len(all_ids), BATCH_SIZE):
        batch_ids = all_ids[start:start + BATCH_SIZE]
        batch_texts = all_texts[start:start + BATCH_SIZE]
        vectors = _model.encode(
            batch_texts, batch_size=BATCH_SIZE,
            normalize_embeddings=True, convert_to_numpy=True,
        ).tolist()
        _qdrant_upsert(qdrant_url, qdrant_api_key, collection, batch_ids, batch_texts, vectors)
        total += len(batch_ids)

    partition_id = int(hashlib.md5(socket.gethostname().encode()).hexdigest()[:16], 16) % 65536
    ctx.emit(partition_id, total)
/


-- ┌───────────────────────────────────────────────────────────────────────────┐
-- │ STEP 7: EMBED_TEXT — scalar in-process embedding for the query path       │
-- └───────────────────────────────────────────────────────────────────────────┘
-- Returns a JSON-encoded 768-float vector for the input text. Called by the
-- Lua adapter via SQL (SELECT ADAPTER.EMBED_TEXT(?)) at query time.
-- Bit-for-bit parity with EMBED_AND_PUSH_LOCAL on the same SLC + model.

CREATE OR REPLACE PYTHON3_QDRANT SCALAR SCRIPT ADAPTER.EMBED_TEXT(
    text VARCHAR(2000000)
)
RETURNS VARCHAR(2000000)
AS
import os
os.environ["HF_HUB_OFFLINE"] = "1"
os.environ["TRANSFORMERS_OFFLINE"] = "1"
os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")

import json

from sentence_transformers import SentenceTransformer

MODEL_NAME = "nomic-embed-text-v1.5"
MODEL_PATH = "/buckets/bfsdefault/default/models/" + MODEL_NAME

MAX_CHARS = 6000

_model = SentenceTransformer(MODEL_PATH, device="cpu", trust_remote_code=True)


def _truncate(text):
    return text[:MAX_CHARS] if len(text) > MAX_CHARS else text


def run(ctx):
    text = ctx.text
    if text is None or text == "":
        return None
    vector = _model.encode(
        _truncate(text),
        normalize_embeddings=True,
        convert_to_numpy=True,
    )
    return json.dumps(vector.tolist())
/


-- ┌───────────────────────────────────────────────────────────────────────────┐
-- │ STEP 7b: SEARCH_QDRANT_LOCAL — embed + Qdrant hybrid search (SET UDF)     │
-- └───────────────────────────────────────────────────────────────────────────┘
-- Owns the entire query path. The Lua adapter generates SQL that calls this
-- UDF; the UDF embeds the query text, runs Qdrant hybrid search (vector +
-- per-keyword RRF fusion), and emits one row per hit. Reads Qdrant config
-- from the same CONNECTION the virtual schema uses (accepts plain URL or
-- JSON {"qdrant_url":"..."}).
--
-- This UDF exists because Exasol forbids exa.pquery_no_preprocessing during
-- virtual schema pushdown, so the adapter cannot run SQL or HTTP itself
-- there — all query-time work happens here.

CREATE OR REPLACE PYTHON3_QDRANT SET SCRIPT ADAPTER.SEARCH_QDRANT_LOCAL(
    connection_name VARCHAR(200),
    collection      VARCHAR(200),
    query_text      VARCHAR(2000000),
    result_limit    INTEGER
)
EMITS (
    result_id    VARCHAR(2000000) UTF8,
    result_text  VARCHAR(2000000) UTF8,
    result_score DOUBLE,
    result_query VARCHAR(2000000) UTF8
)
AS
import os
os.environ["HF_HUB_OFFLINE"] = "1"
os.environ["TRANSFORMERS_OFFLINE"] = "1"
os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")

import json
import re
import urllib.error
import urllib.request

from sentence_transformers import SentenceTransformer

MODEL_NAME = "nomic-embed-text-v1.5"
MODEL_PATH = "/buckets/bfsdefault/default/models/" + MODEL_NAME

MAX_CHARS = 6000
MAX_KEYWORDS = 12

_model = SentenceTransformer(MODEL_PATH, device="cpu", trust_remote_code=True)

_STOPWORDS = frozenset({
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
})

_TOKEN_RE = re.compile(r"[A-Za-z0-9]+")


def _truncate(text):
    return text[:MAX_CHARS] if len(text) > MAX_CHARS else text


def extract_keywords(text):
    seen, result, prev = set(), [], None
    for raw in _TOKEN_RE.findall(text or ""):
        word = raw.lower()
        if len(word) >= 2 and word not in _STOPWORDS and word not in seen:
            seen.add(word); result.append(word)
            if prev is not None:
                compound = prev + word
                if compound not in seen:
                    seen.add(compound); result.append(compound)
            prev = word
        else:
            prev = None
    return result[:MAX_KEYWORDS]


def _parse_connection(conn):
    address = (conn.address or "").strip()
    api_key = conn.password or ""
    if address.startswith("{"):
        try:
            cfg = json.loads(address)
            qdrant_url = cfg.get("qdrant_url", "")
            if not api_key:
                api_key = cfg.get("qdrant_api_key", "")
        except (ValueError, json.JSONDecodeError):
            qdrant_url = address
    else:
        qdrant_url = address
    if not qdrant_url:
        raise ValueError("CONNECTION address is empty or missing 'qdrant_url'.")
    return qdrant_url.rstrip("/"), api_key


def _build_vector_body(vector, limit):
    return {"query": vector, "using": "text", "limit": limit, "with_payload": True}


def _build_hybrid_body(vector, keywords, limit):
    vector_limit = max(limit * 10, 50)
    keyword_limit = max(limit * 4, 20)
    prefetch = [{"query": vector, "using": "text", "limit": vector_limit}]
    for kw in keywords:
        prefetch.append({
            "query": vector, "using": "text", "limit": keyword_limit,
            "filter": {"must": [{"key": "text", "match": {"text": kw}}]},
        })
    return {"prefetch": prefetch, "query": {"fusion": "rrf"},
            "limit": limit, "with_payload": True}


def _qdrant_query(qdrant_url, api_key, collection, body):
    url = qdrant_url + "/collections/" + collection + "/points/query"
    headers = {"Content-Type": "application/json"}
    if api_key:
        headers["api-key"] = api_key
    payload = json.dumps(body).encode()
    req = urllib.request.Request(url, data=payload, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        raise RuntimeError("Qdrant HTTP " + str(e.code) + " from " + url + ": " + e.read().decode()) from e
    except urllib.error.URLError as e:
        raise RuntimeError("Connection to Qdrant at " + url + " failed: " + str(e.reason)) from e


def run(ctx):
    conn = exa.get_connection(ctx.connection_name)
    qdrant_url, api_key = _parse_connection(conn)
    collection = ctx.collection
    query_text = ctx.query_text
    try:
        result_limit = int(ctx.result_limit) if ctx.result_limit is not None else 10
    except (TypeError, ValueError):
        result_limit = 10

    if query_text is None or query_text == "":
        return

    vector = _model.encode(_truncate(query_text), normalize_embeddings=True,
                           convert_to_numpy=True).tolist()
    keywords = extract_keywords(query_text)
    body = _build_hybrid_body(vector, keywords, result_limit) if keywords \
        else _build_vector_body(vector, result_limit)

    response = _qdrant_query(qdrant_url, api_key, collection, body)
    points = (response.get("result") or {}).get("points") or []

    for pt in points:
        payload = pt.get("payload") or {}
        rid = payload.get("_original_id")
        if rid is None:
            rid = pt.get("id", "")
        rtext = payload.get("text", "")
        rscore = pt.get("score") or 0.0
        ctx.emit(str(rid), str(rtext), float(rscore), query_text)
/


-- ┌───────────────────────────────────────────────────────────────────────────┐
-- │ STEP 8: PREFLIGHT_CHECK — verify Qdrant + SLC/model round-trip            │
-- └───────────────────────────────────────────────────────────────────────────┘
-- Single argument now: only Qdrant URL. The embedding side is verified by
-- loading the SLC's SentenceTransformer and encoding 'preflight' directly —
-- this exercises exactly the same code path EMBED_TEXT and EMBED_AND_PUSH_LOCAL
-- use, so a PASS here means both query-time and ingest-time embedding are
-- working.
--
-- Usage:
--   SELECT ADAPTER.PREFLIGHT_CHECK('http://172.17.0.1:6333');

CREATE OR REPLACE PYTHON3_QDRANT SCALAR SCRIPT ADAPTER.PREFLIGHT_CHECK(
    qdrant_url  VARCHAR(512)
)
RETURNS VARCHAR(2000000)
AS
import os
os.environ["HF_HUB_OFFLINE"] = "1"
os.environ["TRANSFORMERS_OFFLINE"] = "1"
os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")

import json
import urllib.request
import urllib.error

MODEL_NAME = "nomic-embed-text-v1.5"
MODEL_PATH = "/buckets/bfsdefault/default/models/" + MODEL_NAME

_model = None
_model_load_error = None
try:
    from sentence_transformers import SentenceTransformer
    _model = SentenceTransformer(MODEL_PATH, device="cpu", trust_remote_code=True)
except Exception as e:
    _model_load_error = str(e)


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


def run(ctx):
    if not ctx.qdrant_url or ctx.qdrant_url.strip() == "":
        raise ValueError("qdrant_url is required. Use the IP reachable from inside Exasol (e.g. 'http://172.17.0.1:6333'). Do NOT use 'localhost'.")
    qdrant_url = ctx.qdrant_url.rstrip("/")

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

    # Check 2: SLC + model load + embedding round-trip
    if _model is None:
        checks.append("[FAIL] sentence-transformers + " + MODEL_NAME + " load: " + str(_model_load_error))
        all_pass = False
    else:
        try:
            vec = _model.encode("preflight", normalize_embeddings=True, convert_to_numpy=True)
            checks.append("[PASS] Embedding round-trip: " + str(len(vec.tolist())) + "-dim vector from " + MODEL_NAME)
        except Exception as e:
            checks.append("[FAIL] Embedding round-trip: " + str(e))
            all_pass = False

    # Build report
    status = "ALL CHECKS PASSED" if all_pass else "SOME CHECKS FAILED"
    report = "=== PREFLIGHT CHECK: " + status + " ===\n"
    for c in checks:
        report += c + "\n"
    if not all_pass:
        report += "\nTroubleshooting:\n"
        report += "- Ensure Qdrant is running and reachable from inside Exasol (typically 172.17.0.1)\n"
        report += "- Ensure the qdrant-embed SLC and nomic-embed-text-v1.5 model are uploaded to BucketFS\n"
        report += "  (run ./scripts/build_and_upload_slc.sh) and PYTHON3_QDRANT is registered\n"
        report += "- Re-run scripts/install_all.sql to (re)install the EMBED_TEXT UDF\n"

    return report
/


-- ┌───────────────────────────────────────────────────────────────────────────┐
-- │ STEP 9: Create virtual schema                                            │
-- └───────────────────────────────────────────────────────────────────────────┘
-- This maps all Qdrant collections as queryable Exasol tables.
-- After creating, each collection appears as a table with columns:
--   ID (VARCHAR), TEXT (VARCHAR), SCORE (DOUBLE), QUERY (VARCHAR)
--
-- Note: OLLAMA_URL is no longer a valid property. The query path embeds in
-- the database via ADAPTER.EMBED_TEXT — no external embedding service.
--
-- DROP + CREATE is used instead of IF NOT EXISTS because Exasol cannot
-- update virtual schema properties in-place. Dropping a virtual schema does
-- NOT delete Qdrant data — it is just a metadata mapping.
--
-- DROP FORCE (not CASCADE) is intentional: CASCADE can destroy the ADAPTER
-- schema (scripts, connections, everything). DROP FORCE also resolves the
-- "ghost metadata" caching bug that sometimes blocks the next CREATE.

DROP FORCE VIRTUAL SCHEMA IF EXISTS vector_schema;

CREATE VIRTUAL SCHEMA vector_schema
    USING ADAPTER.VECTOR_SCHEMA_ADAPTER
    WITH CONNECTION_NAME = 'qdrant_conn'
         QDRANT_MODEL    = 'nomic-embed-text-v1.5';


-- =============================================================================
-- INSTALLATION COMPLETE!
-- =============================================================================
--
-- USAGE EXAMPLES:
--
-- ── Preflight check ──────────────────────────────────────────────────────────
--
--   SELECT ADAPTER.PREFLIGHT_CHECK('http://172.17.0.1:6333');
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
--       'nomic-embed-text-v1.5'          -- model (auto-detects dimensions)
--   );
--
-- ── Ingest data via in-process SLC embedding (CONNECTION-driven) ────────────
--
--   SELECT ADAPTER.EMBED_AND_PUSH_LOCAL(
--       'embedding_conn',                 -- connection name
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
--   SELECT ADAPTER.EMBED_AND_PUSH_LOCAL(
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
