"""
Exasol SET UDF: EMBED_AND_PUSH_LOCAL

In-process embedding ingest. Loads sentence-transformers + a local model
from BucketFS once per UDF VM and embeds rows directly inside the UDF —
no HTTP hop to Ollama on the ingest path.

Reads Qdrant config from a CONNECTION object (same pattern as
EMBED_AND_PUSH_V2). Emits one summary row per partition.

Requires the qdrant-embed SLC + nomic-embed-text-v1.5 model to be present
in BucketFS, and PYTHON3_QDRANT to be registered in SCRIPT_LANGUAGES. See
scripts/install_local_embeddings.sql for the DDL.
"""

import os
# HF/transformers must be told they are offline BEFORE the import — otherwise
# huggingface_hub phones home for model metadata at load time and fails with a
# confusing networking error inside the sealed UDF sandbox.
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

# Default model path inside the UDF sandbox. The model tarball is uploaded to
# BucketFS at models/<MODEL_NAME>.tar.gz and auto-extracted.
MODEL_NAME = "nomic-embed-text-v1.5"
MODEL_PATH = "/buckets/bfsdefault/default/models/" + MODEL_NAME

BATCH_SIZE = 64
MAX_CHARS = 6000  # ~1500 tokens, well under nomic's 2048-token window

# Module-scope load: runs once per UDF VM, amortized across all rows the VM
# processes. trust_remote_code=True is required by nomic's SentenceTransformer
# config; the code being trusted is whatever the operator uploaded to BucketFS.
_model = SentenceTransformer(MODEL_PATH, device="cpu", trust_remote_code=True)


def _truncate(text):
    if not text:
        return ""
    return text[:MAX_CHARS] if len(text) > MAX_CHARS else text


def _text_to_uuid(text_id):
    return str(uuid.uuid5(uuid.NAMESPACE_DNS, str(text_id)))


def _qdrant_upsert(qdrant_url, api_key, collection, ids, texts, vectors):
    points = [
        {
            "id": _text_to_uuid(i),
            "vector": {"text": v},
            "payload": {"_original_id": i, "text": t},
        }
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
        raise RuntimeError(
            "Qdrant HTTP " + str(e.code) + " from " + url + ": " + e.read().decode()
        ) from e
    except urllib.error.URLError as e:
        raise RuntimeError(
            "Connection to Qdrant at " + url + " failed: " + str(e.reason)
        ) from e


def run(ctx):
    conn = exa.get_connection(ctx.connection_name)  # noqa: F821
    config = json.loads(conn.address)

    qdrant_url = config.get("qdrant_url")
    if not qdrant_url:
        raise ValueError(
            "CONNECTION config missing 'qdrant_url'. Set it to the Qdrant "
            "endpoint reachable from inside Exasol (e.g. 'http://172.17.0.1:6333')."
        )
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
        raise ValueError(
            "All " + str(skipped) + " rows had NULL/empty id or text. "
            "Provide non-empty id and text columns."
        )

    total = 0
    for start in range(0, len(all_ids), BATCH_SIZE):
        batch_ids = all_ids[start:start + BATCH_SIZE]
        batch_texts = all_texts[start:start + BATCH_SIZE]

        vectors = _model.encode(
            batch_texts,
            batch_size=BATCH_SIZE,
            normalize_embeddings=True,
            convert_to_numpy=True,
        ).tolist()

        _qdrant_upsert(qdrant_url, qdrant_api_key, collection, batch_ids, batch_texts, vectors)
        total += len(batch_ids)

    partition_id = int(hashlib.md5(socket.gethostname().encode()).hexdigest()[:16], 16) % 65536
    ctx.emit(partition_id, total)
