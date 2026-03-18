## Context

Exasol supports extensibility via Virtual Schemas — a mechanism where an external adapter intercepts SQL statements (DDL and DML push-downs) and translates them into operations against a remote data source. This project uses that mechanism to expose Qdrant as a pseudo-native vector database within Exasol.

Qdrant is a vector similarity search engine that supports dense vector storage, named inference models for automatic embedding, and cosine/dot/euclid distance metrics. Its REST API supports upsert, search, and collection management.

The current state: Exasol has no built-in vector search capability. Users who need semantic search must manage embeddings externally and integrate results manually. This adapter closes that gap.

## Goals / Non-Goals

**Goals:**
- Implement a Java-based Exasol Virtual Schema adapter that translates SQL `CREATE TABLE`, `INSERT INTO`, and `SELECT` into Qdrant REST API calls
- Support Qdrant's built-in inference API for automatic embedding (model configured at schema creation time)
- Return similarity search results as standard Exasol result sets (ID, text, score)
- Store Qdrant credentials centrally via Exasol connection objects
- Support batch inserts and top-k limiting via `LIMIT`

**Non-Goals:**
- Support for vector distance metrics other than cosine (no dot product or euclidean in v1)
- Support for non-text data types (images, audio, multi-modal) in v1
- DDL operations beyond `CREATE TABLE` (no `ALTER TABLE`, `DROP TABLE`, `TRUNCATE`)
- Qdrant collection snapshots, backups, or migration tooling
- Exasol result caching or adapter-side embedding computation

## Decisions

### D1: Java Virtual Schema Adapter (not UDF-based)

**Decision**: Implement as a Java Virtual Schema adapter using Exasol's `virtual-schema-api` library.

**Rationale**: Virtual Schema adapters receive full SQL push-down context (table names, filters, projections, `LIMIT`), enabling precise translation to Qdrant operations. UDFs are callable from SQL but do not intercept DDL (`CREATE TABLE`) and lack the push-down metadata needed for efficient query routing.

**Alternatives considered**:
- Python UDF: simpler to write but cannot intercept DDL; requires user to call explicit search functions rather than writing natural `SELECT` statements.
- Lua scripting: not suitable for complex REST API interactions.

---

### D2: Qdrant Inference API for Embeddings (not adapter-side)

**Decision**: Delegate embedding generation entirely to Qdrant's inference API.

**Rationale**: The user stories explicitly require that raw text is forwarded to Qdrant and Qdrant computes embeddings. This removes the adapter's dependency on ML libraries, simplifies deployment, and centralises model management in Qdrant.

**Alternatives considered**:
- Adapter-side embedding via sentence-transformers: adds a Python/native dependency, increases adapter complexity, and duplicates model management outside Qdrant.

---

### D3: Model Specified Once at Schema Level

**Decision**: The Qdrant inference model name is set as a virtual schema property at creation time and stored in Exasol's connection object (alongside the URL and API key).

**Rationale**: Users should not need to specify the model per-query. Centralising it at schema creation reduces user error and aligns with how Exasol manages external connection parameters. The model is passed to Qdrant at collection creation (`CREATE TABLE`) and is implicit for inserts and searches thereafter.

---

### D4: SQL-to-Qdrant Mapping

| SQL Operation | Qdrant Operation |
|---|---|
| `CREATE TABLE t (id VARCHAR, text VARCHAR)` | `PUT /collections/{t}` with named vectors config |
| `INSERT INTO t VALUES (id, text)` | `PUT /collections/{t}/points` with `{id, payload: {text}, vector: {name: text}}` |
| `SELECT ... WHERE text_query = '...' LIMIT k` | `POST /collections/{t}/points/search` with `{query: {nearest: {text: '...'}}, limit: k}` |

The query string is passed via a virtual schema filter condition; the adapter extracts it from the push-down request.

---

### D5: Credential Storage via Exasol Connection Object

**Decision**: API key and Qdrant URL are stored in an Exasol `CONNECTION` object, referenced by name in the virtual schema properties.

**Rationale**: Follows Exasol's standard pattern for external connections. Avoids storing credentials in plaintext in virtual schema properties. Users and DBAs already understand this mechanism.

## Risks / Trade-offs

- [Qdrant inference API availability] Not all Qdrant deployments have inference API enabled or the required model loaded. → Mitigation: validate at `CREATE TABLE` time; fail fast with a descriptive error if the model is unavailable.
- [SQL push-down coverage] Exasol's virtual schema push-down may not forward all query shapes (e.g., complex joins involving the virtual table). → Mitigation: scope v1 to simple `SELECT ... WHERE ... LIMIT k` patterns; document unsupported query shapes.
- [ID type mismatch] Qdrant point IDs must be unsigned integers or UUIDs; Exasol VARCHAR IDs need conversion. → Mitigation: adapter hashes VARCHAR IDs to UUID v5 deterministically, stores original ID in payload.
- [Batch insert performance] Large `INSERT` batches are forwarded as a single Qdrant upsert call; very large batches may time out. → Mitigation: chunk batches at adapter level (configurable batch size, default 100).
- [Schema property updates] Changing the inference model after collections are created creates a mismatch between stored vectors and query vectors. → Mitigation: document that model changes require collection recreation; warn in adapter logs.

## Migration Plan

1. Deploy the adapter JAR to Exasol's BucketFS
2. Create an Exasol `CONNECTION` object with Qdrant URL and API key
3. Run `CREATE VIRTUAL SCHEMA` referencing the adapter and connection
4. Users can immediately run `CREATE TABLE`, `INSERT`, and `SELECT` against the virtual schema
5. Rollback: drop the virtual schema; Qdrant collections remain intact (no destructive rollback needed on the Qdrant side unless desired)

## Open Questions

- Should `DROP TABLE` on the virtual schema trigger `DELETE /collections/{name}` in Qdrant, or be a no-op? (risk: accidental data loss vs. resource leak)
- Should the adapter support multiple named vector fields per collection (multi-vector) in a future version?
- What is the max supported batch size before Qdrant inference API timeouts become a concern? Needs load testing.
