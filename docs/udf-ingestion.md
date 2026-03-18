# Loading Data into Qdrant via Exasol UDFs

Because Exasol virtual schemas are read-only, data cannot flow from Exasol into
Qdrant through the virtual schema adapter. This guide shows how to use the
**`EMBED_AND_PUSH`** and **`CREATE_QDRANT_COLLECTION`** UDFs to ingest data that
already lives in Exasol tables — the UDFs embed each row using Ollama and upsert
the resulting vectors into Qdrant so you can later run semantic search via the
virtual schema.

## Overview

```
Exasol table (native)
        │
        │  SELECT EMBED_AND_PUSH(...)  ← SET UDF
        ▼
Ollama (local embeddings — text → float vector)
        │
        ▼
Qdrant collection (vector store)
        │
        │  SELECT ... FROM vector_schema.my_collection WHERE "QUERY" = ...
        ▼
Semantic search results back in Exasol SQL
```

---

## Prerequisites

| Requirement | Notes |
|---|---|
| Exasol 7.x+ | Docker or on-premise |
| Qdrant 1.9+ | `docker run -d --name qdrant -p 6333:6333 qdrant/qdrant` |
| Ollama | `docker run -d --name ollama -p 11434:11434 ollama/ollama` |
| `nomic-embed-text` pulled | `docker exec ollama ollama pull nomic-embed-text` |

> **No SLC or extra packages required.** The UDFs use Python's standard library only (`urllib`, `json`, `uuid`) and are deployed by running a single SQL file.

---

## Docker Networking Note

The UDFs run inside the Exasol container. Use Docker container IPs, not `localhost`:

```bash
# Find the gateway IP (used to reach Qdrant from inside Exasol)
docker exec exasoldb ip route show default
# → default via 172.17.0.1 dev eth0

# Find Ollama's container IP
docker inspect ollama --format '{{json .NetworkSettings.Networks}}'
# → "IPAddress":"172.17.0.4"

# Find Qdrant's container IP
docker inspect qdrant --format '{{json .NetworkSettings.Networks}}'
# → "IPAddress":"172.17.0.3"
```

Use `172.17.0.1` as the Qdrant host (traffic is forwarded via the gateway to the mapped port) and the Ollama container IP directly (e.g. `172.17.0.4`) for the `embedding_key` parameter.

---

## Step 1 — Deploy the UDF Scripts

Run `scripts/create_udfs_ollama.sql` directly in your SQL client (DBeaver, DbVisualizer, etc.). No SLC build or BucketFS upload is needed.

```sql
-- Prerequisites
CREATE SCHEMA IF NOT EXISTS ADAPTER;
```

Then open and run the full contents of `scripts/create_udfs_ollama.sql`. This creates two scripts in the `ADAPTER` schema:
- `ADAPTER.CREATE_QDRANT_COLLECTION`
- `ADAPTER.EMBED_AND_PUSH`

---

## Step 2 — Create a Qdrant Collection

```sql
-- nomic-embed-text produces 768-dimensional vectors
SELECT ADAPTER.CREATE_QDRANT_COLLECTION(
    '172.17.0.1',   -- qdrant_host (gateway IP reachable from inside Exasol)
    6333,           -- qdrant_port
    '',             -- api_key (empty = no authentication)
    'my_articles',  -- collection name
    768,            -- vector_size (must match embedding model output)
    'Cosine',       -- distance metric
    ''              -- model_name (leave empty when vector_size is explicit)
);
-- Returns: 'created: my_articles'
-- Returns: 'exists: my_articles'  if it already exists
```

Supported distance metrics: `Cosine`, `Dot`, `Euclid`, `Manhattan`.

### CREATE_QDRANT_COLLECTION parameters

| # | Parameter | Description |
|---|---|---|
| 1 | `host` | Qdrant host IP reachable from inside Exasol |
| 2 | `port` | Qdrant REST port (default `6333`) |
| 3 | `api_key` | API key, or `''` for unauthenticated |
| 4 | `collection` | Collection name to create or verify |
| 5 | `vector_size` | Vector dimension. `768` for `nomic-embed-text`, `1536` for OpenAI `text-embedding-3-small`. Pass `NULL` to infer from `model_name` |
| 6 | `distance` | Similarity metric: `Cosine`, `Dot`, `Euclid`, or `Manhattan` |
| 7 | `model_name` | Used for automatic size inference when `vector_size` is `NULL`. Leave `''` when providing explicit size |

---

## Step 3 — Ingest Data from an Exasol Table

Only two columns are needed: an ID column and a text column. All other columns are ignored during ingestion.

```sql
SELECT ADAPTER.EMBED_AND_PUSH(
    "new_id",                    -- id column
    "text",                      -- text column to embed
    '172.17.0.1',                -- qdrant_host
    6333,                        -- qdrant_port
    '',                          -- qdrant_api_key
    'my_articles',               -- collection name
    'ollama',                    -- provider ('ollama' or 'openai')
    'http://172.17.0.4:11434',   -- embedding_key = Ollama base URL when provider='ollama'
    'nomic-embed-text'           -- model name
)
FROM MY_SCHEMA.MY_TABLE
GROUP BY IPROC();
```

`GROUP BY IPROC()` distributes the work across Exasol cluster nodes. The UDF returns one summary row per node: `(partition_id, upserted_count)`.

### EMBED_AND_PUSH parameters

| # | Parameter | Description |
|---|---|---|
| 1 | `id` | Source row identifier — stored as Qdrant payload field `_original_id` |
| 2 | `text_col` | Text to embed — stored as payload field `text`. Texts longer than 6000 characters are automatically truncated |
| 3 | `qdrant_host` | Qdrant host IP |
| 4 | `qdrant_port` | Qdrant REST port |
| 5 | `qdrant_api_key` | Qdrant API key, or `''` |
| 6 | `collection` | Target collection name |
| 7 | `provider` | `'ollama'` for local Ollama embeddings, `'openai'` for OpenAI API |
| 8 | `embedding_key` | **Ollama**: full base URL (e.g. `'http://172.17.0.4:11434'`). **OpenAI**: API key (`'sk-...'`) |
| 9 | `model_name` | Embedding model (e.g. `'nomic-embed-text'`, `'text-embedding-3-small'`) |

### Provider behaviour

| Provider | `embedding_key` value | Notes |
|---|---|---|
| `'ollama'` | Ollama base URL, e.g. `'http://172.17.0.4:11434'` | Uses container IP — not `localhost` |
| `'openai'` | OpenAI API key `'sk-...'` | Requires internet access from Exasol |

---

## Step 4 — Run Semantic Search

```sql
ALTER VIRTUAL SCHEMA vector_schema REFRESH;

SELECT "ID", "TEXT", "SCORE"
FROM vector_schema.my_articles
WHERE "QUERY" = 'trade tensions between US and Japan'
LIMIT 10;
```

> **Tip:** Semantic search finds documents with similar *meaning*, not keyword matches. Use descriptive phrases rather than single words for best results.

---

## Troubleshooting

| Error | Cause | Fix |
|---|---|---|
| `function or script ADAPTER.EMBED_AND_PUSH not found` | UDF scripts not created | Run `scripts/create_udfs_ollama.sql` in your SQL client |
| `Connection refused` (Ollama) | Wrong IP for Ollama | Use the container IP from `docker inspect ollama`, not `localhost` |
| `the input length exceeds the context length` | Text too long for model | Fixed automatically — texts are truncated at 6000 characters |
| `invalid input type` | NULL values in text column | Fixed automatically — NULLs are replaced with empty strings |
| `Not existing vector name error: text` | Collection created with unnamed vectors | Delete and recreate collection, then re-ingest |
| `Qdrant HTTP 400` during upsert | Vector dimension mismatch | Ensure `vector_size` in `CREATE_QDRANT_COLLECTION` matches the model output |
| Zero search results | Query text not semantically matching content | Use a more descriptive query phrase |
| NULL IDs in search results | Old data ingested before payload fix | Delete collection, re-run UDF script, re-ingest |

---

## Security Note — Secrets in SQL

Passing API keys or URLs as SQL string literals means they may appear in:
- Exasol audit logs (`EXA_DBA_AUDIT_SQL`)
- SQL client history files

**Mitigations:** restrict access to audit log views with `GRANT`/`REVOKE`, and rotate credentials regularly.
