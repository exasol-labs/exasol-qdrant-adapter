"""
Exasol SCALAR UDF: CREATE_QDRANT_COLLECTION

Creates or verifies a Qdrant collection. Uses only Python standard library
(urllib) — no SLC or extra packages required.

Returns 'created: <collection>' or 'exists: <collection>'.
"""

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
    """Make a Qdrant REST request; return parsed JSON response."""
    data = json.dumps(body).encode() if body is not None else None
    headers = {"Content-Type": "application/json"}
    if api_key:
        headers["api-key"] = api_key
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"Qdrant HTTP {e.code}: {e.read().decode()}") from e


def run(ctx):
    host        = ctx.host
    port        = int(ctx.port)
    api_key     = ctx.api_key or None
    collection  = ctx.collection
    vector_size = ctx.vector_size
    distance    = ctx.distance
    model_name  = ctx.model_name or ""

    if distance not in _VALID_DISTANCES:
        raise ValueError(
            f"Invalid distance metric '{distance}'. "
            f"Valid options: {', '.join(sorted(_VALID_DISTANCES))}."
        )

    if vector_size is None:
        if not model_name:
            raise ValueError(
                "vector_size is NULL and no model_name provided. "
                "Provide an explicit vector_size or a known model_name."
            )
        if model_name not in _MODEL_DIMENSIONS:
            raise ValueError(
                f"Unknown model '{model_name}'. "
                f"Provide an explicit vector_size. Known models: {list(_MODEL_DIMENSIONS)}"
            )
        vector_size = _MODEL_DIMENSIONS[model_name]

    vector_size = int(vector_size)
    base_url = f"http://{host}:{port}"

    # Check existing collections
    resp = _qdrant_request("GET", f"{base_url}/collections", api_key=api_key)
    existing = {c["name"] for c in resp.get("result", {}).get("collections", [])}

    if collection in existing:
        return f"exists: {collection}"

    # Create collection (named vector "text" for adapter compatibility)
    _qdrant_request(
        "PUT",
        f"{base_url}/collections/{collection}",
        body={"vectors": {"text": {"size": vector_size, "distance": distance}}},
        api_key=api_key,
    )

    # Create text payload index for hybrid search (keyword + vector RRF fusion)
    _qdrant_request(
        "PUT",
        f"{base_url}/collections/{collection}/index",
        body={
            "field_name": "text",
            "field_schema": {
                "type": "text",
                "tokenizer": "word",
                "min_token_len": 2,
                "max_token_len": 40,
                "lowercase": True,
            },
        },
        api_key=api_key,
    )
    return f"created: {collection}"
