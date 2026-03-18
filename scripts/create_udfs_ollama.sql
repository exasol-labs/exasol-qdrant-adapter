-- =============================================================================
-- create_udfs_ollama.sql
-- Run this directly in Exasol (DBeaver, DbVisualizer, etc.).
-- No SLC or extra packages required — uses Python standard library only.
-- Supports provider='ollama' and provider='openai'.
--
-- Prerequisites:
--   CREATE SCHEMA IF NOT EXISTS ADAPTER;
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. CREATE_QDRANT_COLLECTION (SCALAR)
-- ---------------------------------------------------------------------------
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
    return "created: " + collection
/

-- ---------------------------------------------------------------------------
-- 2. EMBED_AND_PUSH (SET)
--
-- provider = 'ollama' : embedding_key = Ollama base URL
--                       e.g. 'http://172.17.0.1:11434'
-- provider = 'openai' : embedding_key = OpenAI API key
--
-- Example (Ollama):
--   SELECT ADAPTER.EMBED_AND_PUSH(
--       id_col, text_col,
--       '172.17.0.1', 6333, '',
--       'my_articles',
--       'ollama',
--       'http://172.17.0.1:11434',
--       'nomic-embed-text'
--   )
--   FROM VALUES ('doc-1','some text') AS t(id_col, text_col)
--   GROUP BY IPROC();
-- ---------------------------------------------------------------------------
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
        raise RuntimeError("Ollama error " + str(e.code) + ": " + e.read().decode()) from e

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
            raise RuntimeError("Ollama error " + str(e.code) + ": " + e.read().decode()) from e
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
            raise RuntimeError("OpenAI error " + str(status) + ": " + body) from e
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
        raise RuntimeError("Qdrant HTTP " + str(e.code) + ": " + e.read().decode()) from e

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

    all_ids, all_texts = [], []
    while True:
        row_id   = ctx.id   or ""
        row_text = ctx.text_col or ""
        if row_id or row_text:
            all_ids.append(row_id)
            all_texts.append(row_text)
        if not ctx.next():
            break

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
