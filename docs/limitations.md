# Limitations and Known Constraints

## Unsupported DDL operations

| SQL statement | Status | Notes |
|---|---|---|
| `CREATE TABLE` | Via Python UDF | Use `SELECT ADAPTER.CREATE_QDRANT_COLLECTION(...)` |
| `INSERT INTO` | Via Python UDF | Use `SELECT ADAPTER.EMBED_AND_PUSH(...) FROM ... GROUP BY IPROC()` |
| `DROP TABLE` | No-op | Dropping the virtual schema does NOT delete Qdrant collections |
| `ALTER TABLE` | Not supported | Column schema is fixed: ID, TEXT, SCORE, QUERY |
| `TRUNCATE` | Not supported | Delete points via the Qdrant API or dashboard directly |
| `UPDATE` | Not supported | Re-insert with the same ID to upsert updated content |

---

## Inference model behaviour

- The embedding model is set **once** at virtual schema creation time via the
  `QDRANT_MODEL` property.
- Changing `QDRANT_MODEL` via `ALTER VIRTUAL SCHEMA ... SET` affects **new** collections
  only. Existing collections retain the model they were created with.
- If the model is changed and old collections are queried, the query vector will
  be computed with the new model but existing point vectors were computed with the
  old model, producing incorrect similarity scores.
- **Mitigation:** after changing `QDRANT_MODEL`, drop and recreate any affected
  collections.

---

## ID conversion

- Exasol VARCHAR IDs are converted to UUID v5 for storage in Qdrant (Qdrant
  requires unsigned integer or UUID point IDs).
- The original VARCHAR ID is preserved in the Qdrant point payload under the key
  `_original_id` and is returned as the `ID` column in search results.
- The UUID is deterministic: the same VARCHAR ID always maps to the same UUID.
- IDs longer than 36 characters are supported; only the UUID stored in Qdrant
  differs.

---

## Query shape support

Only the following SELECT pattern is supported for vector search:

```sql
SELECT [columns] FROM <virtual_schema>.<table>
WHERE query = '<search string>'
[LIMIT k]
```

> **Default limit:** When `LIMIT` is omitted, the adapter returns at most **10 results**. Always specify an explicit `LIMIT` clause if you need more (or fewer) rows.

Unsupported patterns (will not push down correctly):

- Joins between a vector table and another virtual schema table
- `GROUP BY`, `HAVING`, `ORDER BY` applied before `LIMIT`
- Multiple `WHERE` conditions combined with `AND`/`OR` alongside the `query` filter
- Subqueries in the `WHERE` clause

---

## Batch insert performance

- The adapter chunks upsert batches at 100 points per Qdrant API call.
- For very large ingestion workloads, consider using Qdrant's native bulk import
  tools and refreshing the virtual schema afterward.
- Qdrant inference API timeouts under heavy load have not been characterised;
  load testing is recommended before production use.

---

## Distance metric

The `CREATE_QDRANT_COLLECTION` UDF supports four distance metrics: **Cosine**,
**Dot**, **Euclid**, and **Manhattan**. The metric is set at collection creation
time and cannot be changed afterward. The adapter's query-time search uses
whichever metric the collection was created with.

---

## Semantic search only — no BM25 / keyword search

The adapter uses vector similarity exclusively. There is no BM25 or keyword
search capability. For hybrid search (semantic + keyword), query Qdrant directly
or use a separate full-text search solution alongside the virtual schema.

---

## Fixed 4-column schema

Each virtual table exposes exactly four columns: `ID`, `TEXT`, `SCORE`, `QUERY`.
Custom Qdrant payload fields are not directly accessible through the virtual
schema. To access additional metadata, JOIN the search results with your original
Exasol table using the ID column.

---

## Query latency

Each query takes approximately **5–8 seconds**. This latency is dominated by
Exasol's Lua sandbox initialization (~80% of total time), not by the embedding
or vector search (~150ms combined). This is a known characteristic of Exasol's
UDF sandbox architecture.

For sub-second latency, query Ollama and Qdrant directly via their HTTP APIs.

---

## Single vector field

The adapter searches the `text` vector field only. Multi-vector collections
(collections with multiple named vector fields) are not supported.
