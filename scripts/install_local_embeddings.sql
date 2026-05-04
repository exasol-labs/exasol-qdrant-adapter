-- =============================================================================
-- install_local_embeddings.sql — Install ADAPTER.EMBED_AND_PUSH_LOCAL +
--                                ADAPTER.EMBED_TEXT
-- =============================================================================
--
-- Registers the PYTHON3_QDRANT script-language alias against the qdrant-embed
-- SLC in BucketFS, then creates two UDFs that share the same SLC + model:
--   - EMBED_AND_PUSH_LOCAL (SET UDF)  — in-process ingest path
--   - EMBED_TEXT           (SCALAR)   — query-path embedding for the Lua
--                                       adapter's QueryRewriter
--
-- After this script runs, no external embedding service is required. The Lua
-- adapter calls EMBED_TEXT via SQL to obtain query embeddings; the ingest UDF
-- writes vectors directly to Qdrant. Both share one BucketFS model load per
-- UDF VM.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- Prerequisites (do these first; this script does NOT do them)
-- ─────────────────────────────────────────────────────────────────────────────
-- 1. SLC and model tarballs uploaded to BucketFS, e.g.:
--      ./scripts/build_and_upload_slc.sh
--    Resulting BucketFS layout:
--      /buckets/bfsdefault/default/slc/qdrant-embed/...   (extracted SLC)
--      /buckets/bfsdefault/default/models/nomic-embed-text-v1.5/...
--
-- 2. CONNECTION created (Qdrant URL + optional API key, JSON-encoded). The
--    UDF refuses to fall back to defaults if the CONNECTION is missing or
--    its address does not contain qdrant_url, so this step is mandatory.
--
--      CREATE OR REPLACE CONNECTION embedding_conn
--          TO '{"qdrant_url":"http://172.17.0.1:6333","qdrant_api_key":""}'
--          USER ''
--          IDENTIFIED BY '';
--
--    If you already created embedding_conn for EMBED_AND_PUSH_V2 with the
--    full Ollama config, the local UDF will read qdrant_url and ignore the
--    rest — no need to swap connections.
--
-- 3. ADAPTER schema exists. install_all.sql creates it; if you skipped that,
--    this script will create it for you below.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- One-line example invocation (after install)
-- ─────────────────────────────────────────────────────────────────────────────
-- SELECT ADAPTER.EMBED_AND_PUSH_LOCAL(
--     'embedding_conn', 'news_articles',
--     CAST(id AS VARCHAR(36)), text_col
-- )
-- FROM source_table
-- WHERE text_col IS NOT NULL
-- GROUP BY IPROC();
--
-- =============================================================================


-- ┌───────────────────────────────────────────────────────────────────────────┐
-- │ STEP 1: Ensure ADAPTER schema exists                                      │
-- └───────────────────────────────────────────────────────────────────────────┘

CREATE SCHEMA IF NOT EXISTS ADAPTER;
OPEN SCHEMA ADAPTER;


-- ┌───────────────────────────────────────────────────────────────────────────┐
-- │ STEP 2: Register the PYTHON3_QDRANT script-language alias                 │
-- └───────────────────────────────────────────────────────────────────────────┘
-- Append PYTHON3_QDRANT to the existing SCRIPT_LANGUAGES setting. Run this
-- if your DB does not yet have the alias.
--
-- IMPORTANT: ALTER SYSTEM SET SCRIPT_LANGUAGES is REPLACING, not appending.
-- If you have other custom aliases, edit this string to include them all.
-- The default Exasol aliases (PYTHON3, R, JAVA) are listed first to preserve
-- behavior; adjust if your cluster is on a non-standard release.
--
-- Re-running this exact statement is idempotent.

ALTER SYSTEM SET SCRIPT_LANGUAGES =
    'PYTHON3=builtin_python3 R=builtin_r JAVA=builtin_java '
    'PYTHON3_QDRANT=localzmq+protobuf:///bfsdefault/default/slc/qdrant-embed'
    '?lang=python#buckets/bfsdefault/default/slc/qdrant-embed/exaudf/exaudfclient';


-- ┌───────────────────────────────────────────────────────────────────────────┐
-- │ STEP 3: Create EMBED_AND_PUSH_LOCAL SET UDF                                │
-- └───────────────────────────────────────────────────────────────────────────┘
-- CREATE OR REPLACE makes this idempotent; re-running upgrades the body in
-- place without dropping anything else.

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
-- │ STEP 4: Create EMBED_TEXT SCALAR UDF                                      │
-- └───────────────────────────────────────────────────────────────────────────┘
-- Returns a JSON-encoded 768-float vector for the input text. The Lua adapter
-- calls this UDF via SQL (SELECT ADAPTER.EMBED_TEXT(?)) to embed query text
-- — no external embedding service required.
--
-- Bit-for-bit parity with EMBED_AND_PUSH_LOCAL: same SLC, same model, same
-- normalize_embeddings=True. NULL/empty input returns NULL.

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
-- │ STEP 5: SEARCH_QDRANT_LOCAL — embed + Qdrant hybrid search (SET UDF)      │
-- └───────────────────────────────────────────────────────────────────────────┘
-- Owns the entire query path. The Lua adapter generates SQL that calls this
-- UDF; the UDF embeds the query text, runs Qdrant hybrid search (vector +
-- per-keyword RRF fusion), and emits one row per hit.
--
-- This UDF exists because Exasol forbids exa.pquery_no_preprocessing during
-- virtual schema pushdown — the adapter cannot run SQL or HTTP itself there,
-- so all query-time work happens here when Exasol executes the pushdown SQL.
--
-- Reads Qdrant config from a CONNECTION (accepts both plain URL and JSON
-- forms — the same connection the virtual schema's Lua adapter uses).

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
-- │ DONE                                                                      │
-- └───────────────────────────────────────────────────────────────────────────┘
-- Validate with the smoke test below (uncomment to run). It embeds 10 rows
-- via the local UDF into a throw-away collection.
--
-- 1. Create a fresh collection sized for nomic (768-dim cosine):
--      SELECT ADAPTER.CREATE_QDRANT_COLLECTION('172.17.0.1', 6333, '',
--                                              'smoke_local', 768, 'Cosine', '');
--
-- 2. Run the local UDF over a 10-row VALUES set:
--      SELECT ADAPTER.EMBED_AND_PUSH_LOCAL(
--          'embedding_conn', 'smoke_local',
--          CAST(id AS VARCHAR(36)), text_col
--      )
--      FROM (
--          SELECT 1 AS id, 'a quick brown fox' AS text_col UNION ALL
--          SELECT 2, 'a slow lazy dog'                       UNION ALL
--          SELECT 3, 'banks acquired by JP Morgan'           UNION ALL
--          SELECT 4, 'large bank failures in New York'       UNION ALL
--          SELECT 5, 'small community banks in the midwest'  UNION ALL
--          SELECT 6, 'machine learning embeddings'           UNION ALL
--          SELECT 7, 'vector similarity search'              UNION ALL
--          SELECT 8, 'sentence transformers cpu'             UNION ALL
--          SELECT 9, 'qdrant hybrid search rrf'              UNION ALL
--          SELECT 10, 'in-process embedding ingest'
--      ) src
--      GROUP BY IPROC();
--
-- 3. Refresh the virtual schema so the new collection appears as a table:
--      ALTER VIRTUAL SCHEMA VECTOR_SCHEMA REFRESH;
--
-- 4. Query it:
--      SELECT "ID", "TEXT", "SCORE"
--      FROM vector_schema.smoke_local
--      WHERE "QUERY" = 'fast wildlife'
--      LIMIT 5;
--
-- 5. EMBED_TEXT smoke test (scalar query path):
--      SELECT LENGTH(ADAPTER.EMBED_TEXT('banks acquired by JP Morgan'));
--      -- expected: a positive integer (~9 KB JSON for 768-dim vector)
--      SELECT ADAPTER.EMBED_TEXT(NULL) IS NULL;
--      -- expected: TRUE
--      SELECT ADAPTER.EMBED_TEXT('') IS NULL;
--      -- expected: TRUE
