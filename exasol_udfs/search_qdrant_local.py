"""
Exasol SET UDF: SEARCH_QDRANT_LOCAL

Owns the entire query path inside a single UDF: embeds the user's query text
with the BucketFS-resident sentence-transformers model, runs Qdrant hybrid
search (vector + per-keyword RRF fusion), and emits one row per Qdrant hit.

This UDF exists because the Lua adapter cannot execute SQL during pushdown
(Exasol forbids exa.pquery_no_preprocessing in that context). Instead, the
adapter just generates SQL that calls this UDF, and the search work happens
when Exasol executes that SQL.

Inputs:
  connection_name VARCHAR(200)  -- name of an Exasol CONNECTION pointing at Qdrant
  collection      VARCHAR(200)  -- target Qdrant collection name (lowercased)
  query_text      VARCHAR(2M)   -- the natural-language search text
  result_limit    INTEGER       -- max hits to emit

Emits one row per hit (column names chosen to avoid Exasol reserved words):
  result_id    VARCHAR(2M)   -- payload._original_id, falling back to point.id
  result_text  VARCHAR(2M)   -- payload.text
  result_score DOUBLE        -- Qdrant score
  result_query VARCHAR(2M)   -- echo of input query_text; the adapter aliases
                                this back to the "QUERY" virtual column

Requires: qdrant-embed SLC + nomic-embed-text-v1.5 in BucketFS, PYTHON3_QDRANT
registered in SCRIPT_LANGUAGES. See scripts/install_local_embeddings.sql.
"""

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
    "a", "an", "the", "and", "or", "but", "not", "no", "nor", "so", "yet",
    "is", "am", "are", "was", "were", "be", "been", "being",
    "has", "have", "had", "do", "does", "did", "will", "would", "shall", "should",
    "can", "could", "may", "might", "must",
    "in", "on", "at", "to", "for", "of", "by", "from", "with", "about", "between",
    "through", "during", "before", "after", "above", "below", "up", "down",
    "out", "off", "over", "under", "into",
    "i", "me", "my", "we", "us", "our", "you", "your", "he", "him", "his",
    "she", "her", "it", "its", "they", "them", "their",
    "this", "that", "these", "those", "what", "which", "who", "whom", "how",
    "when", "where", "why", "if", "then", "than", "as", "while",
    "all", "each", "every", "both", "few", "more", "most", "some", "any", "such",
    "very", "just", "also", "only", "too", "own", "same", "other",
})

_TOKEN_RE = re.compile(r"[A-Za-z0-9]+")


def _truncate(text):
    return text[:MAX_CHARS] if len(text) > MAX_CHARS else text


def extract_keywords(text):
    seen = set()
    result = []
    prev = None
    for raw in _TOKEN_RE.findall(text or ""):
        word = raw.lower()
        if len(word) >= 2 and word not in _STOPWORDS and word not in seen:
            seen.add(word)
            result.append(word)
            if prev is not None:
                compound = prev + word
                if compound not in seen:
                    seen.add(compound)
                    result.append(compound)
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
        raise ValueError(
            "CONNECTION address is empty or missing 'qdrant_url'. "
            "Set the address to either a plain Qdrant URL "
            "('http://172.17.0.1:6333') or a JSON blob "
            "({\"qdrant_url\":\"http://172.17.0.1:6333\"})."
        )
    return qdrant_url.rstrip("/"), api_key


def _build_vector_body(vector, limit):
    return {
        "query": vector,
        "using": "text",
        "limit": limit,
        "with_payload": True,
    }


def _build_hybrid_body(vector, keywords, limit):
    vector_limit = max(limit * 10, 50)
    keyword_limit = max(limit * 4, 20)
    prefetch = [{"query": vector, "using": "text", "limit": vector_limit}]
    for kw in keywords:
        prefetch.append({
            "query": vector,
            "using": "text",
            "limit": keyword_limit,
            "filter": {"must": [{"key": "text", "match": {"text": kw}}]},
        })
    return {
        "prefetch": prefetch,
        "query": {"fusion": "rrf"},
        "limit": limit,
        "with_payload": True,
    }


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
        raise RuntimeError(
            "Qdrant HTTP " + str(e.code) + " from " + url + ": " + e.read().decode()
        ) from e
    except urllib.error.URLError as e:
        raise RuntimeError(
            "Connection to Qdrant at " + url + " failed: " + str(e.reason)
        ) from e


def run(ctx):
    conn = exa.get_connection(ctx.connection_name)  # noqa: F821
    qdrant_url, api_key = _parse_connection(conn)
    collection = ctx.collection
    query_text = ctx.query_text
    try:
        result_limit = int(ctx.result_limit) if ctx.result_limit is not None else 10
    except (TypeError, ValueError):
        result_limit = 10

    if query_text is None or query_text == "":
        return

    vector = _model.encode(
        _truncate(query_text),
        normalize_embeddings=True,
        convert_to_numpy=True,
    ).tolist()

    keywords = extract_keywords(query_text)
    body = _build_hybrid_body(vector, keywords, result_limit) if keywords \
        else _build_vector_body(vector, result_limit)

    response = _qdrant_query(qdrant_url, api_key, collection, body)
    points = (response.get("result") or {}).get("points") or []

    for pt in points:
        payload = pt.get("payload") or {}
        result_id = payload.get("_original_id")
        if result_id is None:
            result_id = pt.get("id", "")
        result_text = payload.get("text", "")
        result_score = pt.get("score") or 0.0
        ctx.emit(str(result_id), str(result_text), float(result_score), query_text)
