## Context

The Exasol–Qdrant adapter exposes Qdrant collections as read-only Exasol virtual schema tables. Because virtual schemas are read-only at the Exasol protocol level, `INSERT INTO` statements via the virtual schema cannot be used to populate Qdrant from existing Exasol tables.

Users who already have data in Exasol (e.g. product descriptions, support tickets, knowledge-base articles) need an in-database pipeline that: reads rows from a native Exasol table, generates vector embeddings, and upserts the results into a Qdrant collection — all without leaving the Exasol SQL environment.

Exasol UDFs (User Defined Functions) run inside Exasol alongside the data and can call external services, making them the natural choice for this pipeline.

## Goals / Non-Goals

**Goals:**
- Provide a `EMBED_AND_PUSH` SET UDF that accepts text rows from an Exasol table and upserts embeddings into Qdrant.
- Provide a `CREATE_QDRANT_COLLECTION` scalar UDF to create or verify a Qdrant collection before ingestion.
- Support configurable embedding models (OpenAI `text-embedding-*` and local `sentence-transformers`).
- Support configurable Qdrant connection (host, port, API key, collection name).
- Package all Python dependencies into an Exasol Script Language Container (SLC) so UDFs work without internet access at runtime.
- Document the full SQL workflow users follow in Exasol SQL Client or DBeaver.

**Non-Goals:**
- Real-time / CDC (change data capture) streaming from Exasol to Qdrant.
- Modifying the existing virtual schema adapter code.
- Supporting embedding models other than OpenAI and sentence-transformers in the initial release.
- Incremental / delta ingestion (only full or user-filtered re-ingestion is in scope).

## Decisions

### Decision 1: SET UDF over SCALAR UDF for ingestion

**Choice**: Use a `SET` (aggregate) UDF rather than a `SCALAR` UDF.

**Rationale**: A SET UDF receives all rows of a partition in one Python process invocation via the `ExaIterator` API. This allows batch-assembling embedding requests (e.g. 100 texts per OpenAI API call) and batch-upserting to Qdrant, drastically reducing round-trips compared to one API call per row with a SCALAR UDF.

**Alternative considered**: SCALAR UDF — simpler to write but calls the embedding API once per row; impractical for large tables.

### Decision 2: Pass connection config via UDF parameters, not environment variables

**Choice**: Qdrant host/port/API key and embedding model/API key are passed as explicit UDF arguments.

**Rationale**: Exasol does not expose environment variables to UDFs. Passing config as arguments keeps the UDF stateless and testable, and lets users control which Qdrant instance and which embedding model to use per call.

**Alternative considered**: BucketFS config file — possible but adds deployment complexity for a first version.

### Decision 3: OpenAI embeddings as primary, sentence-transformers as local fallback

**Choice**: Default to OpenAI `text-embedding-3-small`; allow `provider=local` to switch to a `sentence-transformers` model bundled in the SLC.

**Rationale**: OpenAI gives state-of-the-art quality with no GPU required. The local option lets users work in air-gapped or cost-sensitive environments without changing the calling SQL.

**Alternative considered**: Only support OpenAI — simpler SLC, but excludes offline users.

### Decision 4: SLC (Script Language Container) for Python dependencies

**Choice**: Package `openai`, `sentence-transformers`, `qdrant-client`, and `torch` (CPU-only) into a custom SLC uploaded to BucketFS.

**Rationale**: Exasol's built-in Python environment does not include these packages. An SLC is the standard Exasol mechanism for custom Python UDF dependencies.

**Alternative considered**: `pip install` at UDF runtime — blocked by Exasol's sandboxed execution environment.

### Decision 5: ID field convention shared with virtual schema adapter

**Choice**: Use the same payload field names (`id`, `text`) as the existing virtual schema ingestion path so search results are consistent regardless of how data was ingested.

**Rationale**: Users may ingest via UDF and query via the virtual schema SELECT adapter. Consistent payload keys ensure the adapter's result mapping works for UDF-ingested data.

## Risks / Trade-offs

- **OpenAI rate limits** → Mitigation: implement exponential back-off with retry in the UDF; surface clear error messages when rate-limited.
- **Large SLC size** (`torch` CPU is ~500 MB) → Mitigation: provide a slim SLC variant without sentence-transformers for users who only need OpenAI.
- **BucketFS upload step adds deployment friction** → Mitigation: provide a `scripts/deploy_udfs.sh` script that automates the upload and `ALTER SESSION` steps.
- **No incremental ingestion** → Users re-run the full `SELECT EMBED_AND_PUSH(...)` query to refresh; for very large tables this is expensive. Accepted for v1; delta support is a future enhancement.
- **Secrets in SQL** → Passing API keys as SQL string literals may appear in Exasol audit logs. Mitigation: document use of Exasol connection objects or Exasol secrets management as an alternative, and note the risk in the docs.

## Migration Plan

1. Build and upload the SLC to BucketFS (`scripts/deploy_udfs.sh`).
2. Execute the DDL script that creates the two UDFs in the target Exasol schema (`scripts/create_udfs.sql`).
3. Optionally run `SELECT CREATE_QDRANT_COLLECTION(...)` to ensure the target collection exists.
4. Run `SELECT EMBED_AND_PUSH(id_col, text_col, ...) FROM source_table GROUP BY IPROC()` to ingest.

Rollback: drop the two UDF scripts from Exasol; the SLC in BucketFS can remain (it is inert until referenced).

## Open Questions

- Should we support Exasol `CONNECTION` objects (storing Qdrant/OpenAI credentials securely) instead of plain string parameters? This would require using `IMPORT` inside the UDF — needs investigation.
- What is the target vector dimension for the default collection? Should `CREATE_QDRANT_COLLECTION` infer it from the chosen model automatically?
