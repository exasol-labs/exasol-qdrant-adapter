# Usage Guide — Qdrant Vector Search via Exasol

## Overview

This adapter provides pseudo-native vector search in Exasol by bridging SQL to
Qdrant's inference API. Users work entirely in SQL:

| User story | SQL pattern |
|---|---|
| Create a vector table | `EXECUTE SCRIPT vector_schema.CREATE_COLLECTION('table_name')` |
| Insert text data | `EXECUTE SCRIPT vector_schema.INGEST_TEXT('table_name', 'id', 'text')` |
| Similarity search | `SELECT id, text, score FROM vector_schema.table_name WHERE query = '...' LIMIT k` |

> **Note on CREATE TABLE and INSERT:**
> The Exasol Virtual Schema framework forwards only SELECT queries as push-downs.
> For CREATE TABLE and INSERT, this adapter provides companion Lua scripts
> (`CREATE_COLLECTION` and `INGEST_TEXT`) that maintain the same SQL-oriented
> developer experience.

---

## Creating a vector table (US-01)

```sql
-- Creates a Qdrant collection named "articles" using the schema-level model
EXECUTE SCRIPT vector_schema.CREATE_COLLECTION('articles');

-- The collection appears as a table after refreshing the schema:
ALTER VIRTUAL SCHEMA vector_schema REFRESH;

-- Verify:
SELECT * FROM vector_schema.articles LIMIT 0;
-- Columns: ID VARCHAR(36), TEXT VARCHAR(2000000), SCORE DOUBLE, QUERY VARCHAR(2000000)
```

If the collection already exists, `CREATE_COLLECTION` returns an error.

---

## Inserting text data (US-02)

```sql
-- Single row
EXECUTE SCRIPT vector_schema.INGEST_TEXT('articles', 'doc-001',
    'Exasol is a high-performance analytical database.');

-- Batch insert (recommended for large volumes)
EXECUTE SCRIPT vector_schema.INGEST_BATCH('articles',
    'doc-001', 'Exasol is a high-performance analytical database.',
    'doc-002', 'Qdrant is a vector similarity search engine.',
    'doc-003', 'Natural language processing enables semantic search.'
);
```

Qdrant computes the embeddings using the schema-configured model. The original
text is stored as a payload field so it can be returned in search results.

Duplicate IDs are handled as upserts (the existing point is overwritten).

---

## Similarity search (US-03)

```sql
-- Find the 5 most semantically similar articles to a query
SELECT id, text, score
FROM vector_schema.articles
WHERE query = 'fast analytical databases'
LIMIT 5;

-- Results are ordered by score DESC (most similar first)
-- Columns: ID, TEXT, SCORE (cosine similarity, range 0–1)
```

The `query` column is a pseudo-column: filtering on it triggers a vector search.
Do not include `QUERY` in the SELECT list unless you want the query string echoed back.

---

## Using search results in downstream SQL

```sql
-- Join search results with a real Exasol table
SELECT s.id, s.score, d.author, d.published_date
FROM (
    SELECT id, score
    FROM vector_schema.articles
    WHERE query = 'machine learning'
    LIMIT 10
) s
JOIN real_schema.document_metadata d ON s.id = d.doc_id
ORDER BY s.score DESC;
```

---

## Checking the configured model

```sql
-- List virtual schema properties
SELECT schema_name, schema_object
FROM EXA_ALL_VIRTUAL_SCHEMAS
WHERE schema_name = 'VECTOR_SCHEMA';
```
