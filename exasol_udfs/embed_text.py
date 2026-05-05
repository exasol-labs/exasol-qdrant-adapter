"""
Exasol SCALAR UDF: EMBED_TEXT

In-process scalar embedding for the query path. Loads sentence-transformers +
the BucketFS-resident model once per UDF VM and returns a JSON-encoded
768-float vector for the input text. Used by the Lua adapter's QueryRewriter
to obtain the query embedding via SQL instead of an external Ollama HTTP call.

Returns NULL for NULL/empty input. Truncates long input at MAX_CHARS (matches
EMBED_AND_PUSH_LOCAL). Bit-for-bit parity with EMBED_AND_PUSH_LOCAL on the
same SLC + model.

Requires the qdrant-embed SLC + nomic-embed-text-v1.5 model to be present in
BucketFS, and PYTHON3_QDRANT to be registered in SCRIPT_LANGUAGES. See
scripts/install_local_embeddings.sql for the DDL.
"""

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
