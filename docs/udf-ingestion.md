# Loading Data into Qdrant via Exasol UDFs

Because Exasol virtual schemas are read-only, data cannot flow from Exasol into
Qdrant through the virtual schema adapter. This guide shows how to use the
**`EMBED_AND_PUSH_LOCAL`** SET UDF and the **`CREATE_QDRANT_COLLECTION`** scalar
UDF to ingest data that already lives in Exasol tables. Both UDFs run inside
the Exasol UDF VM. `EMBED_AND_PUSH_LOCAL` embeds each row in-process via
`sentence-transformers` (loaded once per VM from BucketFS) and upserts the
resulting vectors into Qdrant — no external embedding service is contacted.

## Overview

```
Exasol table (native)
        │
        │  SELECT EMBED_AND_PUSH_LOCAL(...)  ← SET UDF, in-process
        ▼
sentence-transformers + nomic-embed-text-v1.5 (BucketFS, loaded once per UDF VM)
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

| Requirement                                | Notes                                                                                  |
|--------------------------------------------|----------------------------------------------------------------------------------------|
| Exasol 7.x+                                | Docker or on-premise                                                                   |
| Qdrant 1.9+                                | `docker run -d --name qdrant -p 6333:6333 qdrant/qdrant`                               |
| `qdrant-embed` SLC + model in BucketFS     | One-time: `./scripts/build_and_upload_slc.sh` — see [docs/local-embeddings.md](local-embeddings.md) |
| `PYTHON3_QDRANT` script-language alias     | Created by `scripts/install_local_embeddings.sql` or `scripts/install_all.sql`         |

> The model lives in BucketFS, the SLC ships `sentence-transformers`, and the
> alias points at both. `EMBED_AND_PUSH_LOCAL`, `SEARCH_QDRANT_LOCAL` (the
> query-path UDF the Lua adapter calls), and `EMBED_TEXT` (parity utility)
> all share the same SLC + model copy — one model load per UDF VM.

---

## Docker Networking Note

The UDFs run inside the Exasol container. Use the Docker bridge gateway IP (`172.17.0.1`) for Qdrant — not `localhost`, and not the Qdrant container IP.

```bash
# Find the gateway IP
docker exec exasoldb ip route show default
# → default via 172.17.0.1 dev eth0
# Use 172.17.0.1 for qdrant_url
```

---

## Step 1 — Deploy the UDF Scripts

If you used `scripts/install_all.sql` (the one-file installer), the UDFs are
already deployed — skip to Step 2.

If you only need the local-embeddings UDFs, run
`scripts/install_local_embeddings.sql` instead. It registers the
`PYTHON3_QDRANT` alias and creates `EMBED_AND_PUSH_LOCAL`, `EMBED_TEXT`, and
`SEARCH_QDRANT_LOCAL` (the query-path UDF the Lua adapter depends on).

```sql
-- Prerequisites
CREATE SCHEMA IF NOT EXISTS ADAPTER;
```

Then open and run the full contents of `scripts/install_all.sql` (or the
narrower `scripts/install_local_embeddings.sql`).

---

## Step 2 — Create a Qdrant Collection

```sql
-- nomic-embed-text-v1.5 produces 768-dimensional vectors
SELECT ADAPTER.CREATE_QDRANT_COLLECTION(
    '172.17.0.1',          -- qdrant_host (gateway IP reachable from inside Exasol)
    6333,                  -- qdrant_port
    '',                    -- api_key (empty = no authentication)
    'my_articles',         -- collection name
    768,                   -- vector_size (must match embedding model output)
    'Cosine',              -- distance metric
    ''                     -- model_name (leave empty when vector_size is explicit)
);
-- Returns: 'created: my_articles'
-- Returns: 'exists: my_articles'  if it already exists
```

This UDF also creates a **text payload index** on the collection, which enables
hybrid search (vector similarity + keyword matching via RRF). See the
[Hybrid Search](../README.md#hybrid-search) section in the README for details.

Supported distance metrics: `Cosine`, `Dot`, `Euclid`, `Manhattan`.

### CREATE_QDRANT_COLLECTION parameters

| # | Parameter | Description |
|---|---|---|
| 1 | `host` | Qdrant host IP reachable from inside Exasol |
| 2 | `port` | Qdrant REST port (default `6333`) |
| 3 | `api_key` | API key, or `''` for unauthenticated |
| 4 | `collection` | Collection name to create or verify |
| 5 | `vector_size` | Vector dimension. `768` for `nomic-embed-text-v1.5`. Pass `NULL` to infer from `model_name` |
| 6 | `distance` | Similarity metric: `Cosine`, `Dot`, `Euclid`, or `Manhattan` |
| 7 | `model_name` | Used for automatic size inference when `vector_size` is `NULL`. Leave `''` when providing explicit size |

---

## Step 3 — Ingest Data from an Exasol Table

Only two columns are needed: an ID column and a text column. All other columns
are ignored during ingestion.

`EMBED_AND_PUSH_LOCAL` reads infrastructure config from a CONNECTION object —
credentials never appear in SQL text or audit logs.

```sql
-- The embedding_conn CONNECTION is created by install_all.sql.
-- If you need a custom one:
CREATE OR REPLACE CONNECTION my_embedding_conn TO '{
    "qdrant_url": "http://172.17.0.1:6333",
    "qdrant_api_key": ""
}';

SELECT ADAPTER.EMBED_AND_PUSH_LOCAL(
    'embedding_conn',                   -- connection name
    'my_articles',                      -- Qdrant collection
    CAST("id" AS VARCHAR(255)),         -- unique ID
    "text"                              -- text to embed
)
FROM MY_SCHEMA.MY_TABLE
GROUP BY IPROC();
```

`GROUP BY IPROC()` distributes the work across Exasol cluster nodes. The UDF
returns one summary row per partition: `(partition_id, upserted_count)`.

> **Timing:** First call after a UDF VM start pays a 3–8 s model-load cost.
> Steady-state throughput on a single node is ~8.7 rows/sec for ~280-character
> text. For 544 rows expect ~60–90 s. The query will appear to "hang"
> until all embeddings are computed — this is normal.

### EMBED_AND_PUSH_LOCAL parameters

| # | Parameter         | Description                                                                  |
|---|-------------------|------------------------------------------------------------------------------|
| 1 | `connection_name` | Name of an Exasol CONNECTION object containing config JSON                   |
| 2 | `collection`      | Target Qdrant collection name                                                |
| 3 | `id`              | Source row identifier — stored as Qdrant payload field `_original_id`        |
| 4 | `text_col`        | Text to embed — stored as payload field `text`. Truncated at 6000 characters |

### CONNECTION config JSON fields

| Key              | Required | Default | Description                                                |
|------------------|----------|---------|------------------------------------------------------------|
| `qdrant_url`     | Yes      | --      | Full Qdrant URL (e.g. `http://172.17.0.1:6333`)            |
| `qdrant_api_key` | No       | `""`    | Qdrant API key (also reads from CONNECTION password field) |

The model name and dimensions are fixed by the SLC + BucketFS upload — there
are no model/provider options on the ingest side. To change the embedding
model, rebuild the SLC against a different model.

---

## Step 4 — Run Semantic Search

```sql
ALTER VIRTUAL SCHEMA vector_schema REFRESH;

SELECT "ID", "TEXT", "SCORE"
FROM vector_schema.my_articles
WHERE "QUERY" = 'trade tensions between US and Japan'
LIMIT 10;
```

> **Tip:** Semantic search finds documents with similar *meaning*, not keyword
> matches. Use descriptive phrases rather than single words for best results.

The query path also runs in-process — the Lua adapter generates pushdown SQL
that calls `ADAPTER.SEARCH_QDRANT_LOCAL`, which embeds the query text and
runs Qdrant hybrid search inside the same UDF.

---

## Troubleshooting

| Error                                                       | Cause                                                       | Fix                                                                                                |
|-------------------------------------------------------------|-------------------------------------------------------------|----------------------------------------------------------------------------------------------------|
| `function or script ADAPTER.EMBED_AND_PUSH_LOCAL not found` | UDF scripts not created                                     | Run `scripts/install_local_embeddings.sql` (or `scripts/install_all.sql`) in your SQL client       |
| `language not found: PYTHON3_QDRANT`                        | `SCRIPT_LANGUAGES` not extended                             | Re-run the `ALTER SYSTEM SET SCRIPT_LANGUAGES = ...` block in `install_local_embeddings.sql`       |
| `ModuleNotFoundError: sentence_transformers`                | SLC not in BucketFS, or alias path mismatch                 | Re-run `./scripts/build_and_upload_slc.sh`                                                         |
| `Connection refused` (Qdrant)                               | Wrong IP / port for Qdrant                                  | Use the Docker bridge gateway IP (`172.17.0.1`), not `localhost`                                   |
| Long text truncation                                        | Text > 6000 chars                                           | Automatic — UDF truncates at `MAX_CHARS`. Check the SLC source if a different cap is needed.       |
| `Qdrant HTTP 400` during upsert                             | Vector dimension mismatch                                   | Ensure `vector_size=768` in `CREATE_QDRANT_COLLECTION` (matches `nomic-embed-text-v1.5` output)    |
| Zero search results                                         | Query text not semantically matching content                | Use a more descriptive query phrase                                                                |
| `function or script ADAPTER.SEARCH_QDRANT_LOCAL not found`  | Query-path UDF missing                                      | Re-run `scripts/install_all.sql` or `scripts/install_local_embeddings.sql`                         |
| OOM on Exasol nodes                                         | Too many concurrent UDF VMs for node memory                 | Drop concurrency (lower partition cardinality) or add RAM. Each VM holds ~600 MB resident.         |

---

## Security Note — Secrets in SQL

Use the CONNECTION-based pattern shown above to keep credentials out of SQL
text. Exasol redacts CONNECTION contents as `<SECRET>` in audit logs.
`EMBED_AND_PUSH_LOCAL` only ever reads the CONNECTION's JSON address and
optional password field — no API keys appear as SQL parameters.
