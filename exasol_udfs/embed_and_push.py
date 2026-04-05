"""
Exasol SET UDF: EMBED_AND_PUSH

Reads text rows from an Exasol table, calls the OpenAI embeddings API,
and upserts the resulting vectors into Qdrant in batches of 100.

Uses only Python standard library (urllib, json, uuid) — no SLC required.
"""

import json
import time
import uuid
import urllib.request
import urllib.error

BATCH_SIZE = 100
MAX_RETRIES = 3


# ---------------------------------------------------------------------------
# Embedding
# ---------------------------------------------------------------------------

def _openai_embed(texts, api_key, model):
    """Call OpenAI embeddings API with exponential back-off retry."""
    url = "https://api.openai.com/v1/embeddings"
    payload = json.dumps({"input": texts, "model": model}).encode()
    headers = {
        "Content-Type": "application/json",
        "Authorization": f"Bearer {api_key}",
    }
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
            if status == 429 and attempt < MAX_RETRIES:   # rate limit
                time.sleep(delay)
                delay *= 2
                continue
            raise RuntimeError(
                f"OpenAI API error {status} (attempt {attempt}/{MAX_RETRIES}): {body}"
            ) from e
    raise RuntimeError(f"OpenAI embedding failed after {MAX_RETRIES} attempts")


# ---------------------------------------------------------------------------
# Qdrant upsert
# ---------------------------------------------------------------------------

def _text_to_uuid(text_id):
    return str(uuid.uuid5(uuid.NAMESPACE_DNS, str(text_id)))


def _qdrant_upsert(base_url, collection, ids, texts, vectors, api_key):
    """Upsert a batch of points into Qdrant via REST."""
    points = [
        {
            "id":      _text_to_uuid(doc_id),
            "vector":  vector,
            "payload": {"id": doc_id, "text": text},
        }
        for doc_id, text, vector in zip(ids, texts, vectors)
    ]
    payload = json.dumps({"points": points}).encode()
    headers = {"Content-Type": "application/json"}
    if api_key:
        headers["api-key"] = api_key
    url = f"{base_url}/collections/{collection}/points"
    req = urllib.request.Request(url, data=payload, headers=headers, method="PUT")
    try:
        with urllib.request.urlopen(req) as resp:
            result = json.loads(resp.read().decode())
            if result.get("status") != "ok":
                raise RuntimeError(f"Qdrant upsert returned non-ok status: {result}")
    except urllib.error.HTTPError as e:
        raise RuntimeError(
            f"Qdrant upsert HTTP {e.code}: {e.read().decode()}"
        ) from e


# ---------------------------------------------------------------------------
# UDF entry point
# ---------------------------------------------------------------------------

def run(ctx):
    qdrant_host    = ctx.qdrant_host
    qdrant_port    = int(ctx.qdrant_port)
    qdrant_api_key = ctx.qdrant_api_key or None
    collection     = ctx.collection
    provider       = ctx.provider.lower()
    embedding_key  = ctx.embedding_key or ""
    model_name     = ctx.model_name

    if provider != "openai":
        raise ValueError(
            f"Unsupported provider '{provider}'. "
            "Only 'openai' is supported in the stdlib-only UDF. "
            "For local sentence-transformers, deploy the full SLC variant."
        )

    base_url = f"http://{qdrant_host}:{qdrant_port}"

    # Collect all rows for this partition
    all_ids, all_texts, skipped_nulls = [], [], 0
    while True:
        row_id = ctx.id
        row_text = ctx.text_col or ""
        if row_id is None or row_id == "":
            skipped_nulls += 1
        else:
            all_ids.append(row_id)
            all_texts.append(row_text)
        if not ctx.next():
            break
    if skipped_nulls > 0 and len(all_ids) == 0:
        raise ValueError(
            f"All {skipped_nulls} rows have NULL or empty IDs. "
            "Provide a non-empty ID column."
        )

    total_upserted = 0
    for i in range(0, len(all_ids), BATCH_SIZE):
        batch_ids   = all_ids[i: i + BATCH_SIZE]
        batch_texts = all_texts[i: i + BATCH_SIZE]

        vectors = _openai_embed(batch_texts, embedding_key, model_name)

        try:
            _qdrant_upsert(base_url, collection, batch_ids, batch_texts, vectors, qdrant_api_key)
        except Exception as exc:
            raise RuntimeError(
                f"Qdrant upsert failed for batch at row {i}: {exc}"
            ) from exc

        total_upserted += len(batch_ids)

    # Emit partition summary
    import hashlib, socket
    partition_id = int(hashlib.md5(socket.gethostname().encode()).hexdigest(), 16) % 65536
    ctx.emit(partition_id, total_upserted)
