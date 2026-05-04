# Usage Guide — Qdrant Vector Search via Exasol

## Overview

This adapter provides semantic vector search in Exasol by bridging SQL to
Qdrant's vector search API. Users work entirely in SQL:

| User story | SQL pattern |
|---|---|
| Create a vector collection | `SELECT ADAPTER.CREATE_QDRANT_COLLECTION(...)` |
| Ingest data from Exasol | `SELECT ADAPTER.EMBED_AND_PUSH_LOCAL(...) FROM my_table GROUP BY IPROC()` |
| Similarity search | `SELECT "ID", "TEXT", "SCORE" FROM vector_schema.table WHERE "QUERY" = '...' LIMIT k` |

> **Note:** The Exasol Virtual Schema framework forwards only SELECT queries as push-downs.
> Data ingestion is handled by companion Python UDFs (`CREATE_QDRANT_COLLECTION`
> and `EMBED_AND_PUSH_LOCAL`) that embed text in-process via the BucketFS-resident
> SLC + model and upsert vectors into Qdrant. Query-time embedding and Qdrant
> hybrid search are also in-process — the Lua adapter generates pushdown SQL
> that calls `ADAPTER.SEARCH_QDRANT_LOCAL`, which owns the entire query path.

---

## Creating a vector collection

```sql
-- Creates a Qdrant collection named "articles" (768 dims for nomic-embed-text)
SELECT ADAPTER.CREATE_QDRANT_COLLECTION(
    '172.17.0.1', 6333, '', 'articles', 768, 'Cosine', ''
);

-- The collection appears as a table after refreshing the schema:
ALTER VIRTUAL SCHEMA vector_schema REFRESH;

-- Verify:
SELECT * FROM EXA_ALL_TABLES WHERE TABLE_SCHEMA = 'VECTOR_SCHEMA';
-- Columns per table: ID VARCHAR, TEXT VARCHAR, SCORE DOUBLE, QUERY VARCHAR
```

If the collection already exists, `CREATE_QDRANT_COLLECTION` returns `'exists: articles'`.

---

## Ingesting text data

```sql
-- Embed and push rows from an Exasol table into Qdrant
SELECT ADAPTER.EMBED_AND_PUSH_LOCAL(
    'embedding_conn',                -- CONNECTION object with Qdrant URL
    'articles',                      -- collection name
    CAST(doc_id AS VARCHAR(36)),     -- unique ID column
    doc_text                         -- text column to embed
)
FROM MY_SCHEMA.DOCUMENTS
GROUP BY IPROC();
```

`GROUP BY IPROC()` is required for SET UDFs — it distributes work across Exasol
cluster nodes. The UDF returns one summary row per partition:
`(partition_id, upserted_count)`.

Duplicate IDs are handled as upserts (the existing point is overwritten).

See [udf-ingestion.md](udf-ingestion.md) for the full parameter reference,
CONNECTION JSON fields, and troubleshooting.

---

## Similarity search

```sql
-- Find the 5 most semantically similar articles to a query
SELECT "ID", "TEXT", "SCORE"
FROM vector_schema.articles
WHERE "QUERY" = 'fast analytical databases'
LIMIT 5;

-- Results are ordered by score DESC (most similar first)
-- SCORE is cosine similarity, range 0-1
```

The `"QUERY"` column is a pseudo-column: filtering on it triggers a vector search.
Always quote column names with double quotes to avoid Exasol reserved word conflicts.

> **Default limit:** When `LIMIT` is omitted, the adapter returns at most **10 results**.

### SCORE filtering

You can filter results by relevance score. Exasol applies SCORE filters after the vector search:

```sql
SELECT "ID", "TEXT", "SCORE" FROM vector_schema.articles
WHERE "QUERY" = 'machine learning' AND "SCORE" > 0.6 LIMIT 5;
```

### Performance note

After the first call in a UDF VM, each query takes approximately **5–8 seconds**.
This latency is dominated by Exasol's Lua sandbox initialization (~80% of total
time), not by the embedding (~50–150 ms warm) or vector search (~50–100 ms).
The first query in a freshly recycled VM additionally pays a 3–8 s model-load
cost from BucketFS. For sub-second latency, query Qdrant directly via its HTTP
API and embed client-side.

---

## Using search results in downstream SQL

```sql
-- Join search results with a real Exasol table
SELECT s."ID", s."SCORE", d.author, d.published_date
FROM (
    SELECT "ID", "SCORE"
    FROM vector_schema.articles
    WHERE "QUERY" = 'machine learning'
    LIMIT 10
) s
JOIN real_schema.document_metadata d ON s."ID" = d.doc_id
ORDER BY s."SCORE" DESC;
```

---

## Virtual schema properties

| Property            | Required | Default              | Description                                                          |
| ------------------- | -------- | -------------------- | -------------------------------------------------------------------- |
| `CONNECTION_NAME`   | Yes      | --                   | Exasol CONNECTION object with Qdrant URL                             |
| `QDRANT_MODEL`      | Yes      | --                   | Embedding model name (informational; surfaced in diagnostic errors)  |
| `QDRANT_URL`        | No       | --                   | Override Qdrant URL (ignores CONNECTION address)                     |
| `COLLECTION_FILTER` | No       | -- (all collections) | Comma-separated list of collection names or glob patterns to expose  |

> **Removed property:** `OLLAMA_URL` is no longer accepted. Use of
> `OLLAMA_URL` raises a clear migration error — drop and re-create the
> virtual schema after running `scripts/install_all.sql`.

Change properties without dropping the schema:

```sql
ALTER VIRTUAL SCHEMA vector_schema SET COLLECTION_FILTER = 'bank_*';
ALTER VIRTUAL SCHEMA vector_schema REFRESH;
```

---

## Checking the configured model

```sql
-- List virtual schema properties
SELECT schema_name, schema_object
FROM EXA_ALL_VIRTUAL_SCHEMAS
WHERE schema_name = 'VECTOR_SCHEMA';
```
