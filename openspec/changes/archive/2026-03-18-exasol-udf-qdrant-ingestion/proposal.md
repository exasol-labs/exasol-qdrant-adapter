## Why

Exasol virtual schemas are read-only, making it impossible to push data from Exasol into Qdrant via the existing adapter. Users need a way to load data that already lives in Exasol tables — such as documents, product descriptions, or knowledge-base entries — into Qdrant as embeddings so they can run semantic search over it.

## What Changes

- Introduce an Exasol UDF-based ingestion pipeline that reads rows from an Exasol table, generates vector embeddings, and upserts them into a Qdrant collection.
- Provide a `EMBED_AND_PUSH` SET UDF (Python) that accepts text columns, calls an embedding model (e.g. OpenAI or a local model), and writes the resulting vectors to Qdrant in batches.
- Provide a helper `CREATE_QDRANT_COLLECTION` scalar UDF to create/ensure the target Qdrant collection with the correct vector dimensions before ingestion.
- Document the SQL workflow users follow to trigger ingestion from within Exasol SQL.

## Capabilities

### New Capabilities

- `udf-qdrant-ingestion`: SET UDF that reads text rows from Exasol, embeds them, and upserts vectors into Qdrant with configurable batch size, embedding model, and payload fields.
- `udf-collection-setup`: Scalar UDF that creates or verifies a Qdrant collection with the specified vector size and distance metric before ingestion.

### Modified Capabilities

- `text-ingestion`: The existing text-ingestion spec handled ingestion from outside Exasol; update requirements to acknowledge the Exasol-internal ingestion path and shared payload conventions (ID field, metadata fields).

## Impact

- **New files**: `exasol_udfs/embed_and_push.py`, `exasol_udfs/create_collection.py`, `exasol_udfs/requirements.txt`, `scripts/deploy_udfs.sh`
- **Dependencies added**: `openai` (or `sentence-transformers` for local embeddings), `qdrant-client` — packaged into an Exasol Script Language Container (SLC)
- **Existing code**: No changes to the virtual schema adapter code
- **Documentation**: New `docs/udf-ingestion.md` walkthrough
