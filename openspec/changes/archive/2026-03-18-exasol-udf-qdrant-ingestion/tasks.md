## 1. SLC (Script Language Container) Setup

- [x] 1.1 Create `exasol_udfs/requirements.txt` with `openai`, `qdrant-client`, `sentence-transformers`, and `torch` (CPU-only)
- [x] 1.2 Create `exasol_udfs/requirements-slim.txt` (OpenAI-only variant without torch/sentence-transformers)
- [x] 1.3 Write `scripts/build_slc.sh` that uses `exaslct` to build the full and slim SLC flavours
- [x] 1.4 Write `scripts/deploy_udfs.sh` that uploads the SLC to BucketFS and runs `ALTER SESSION SET SCRIPT_LANGUAGES`

## 2. CREATE_QDRANT_COLLECTION UDF

- [x] 2.1 Create `exasol_udfs/create_collection.py` with the scalar UDF implementation
- [x] 2.2 Implement collection creation logic using `qdrant_client.QdrantClient`; handle the "already exists" case
- [x] 2.3 Implement vector-size inference for known OpenAI and sentence-transformers models
- [x] 2.4 Validate `distance_metric` input and raise a descriptive error for unknown values
- [x] 2.5 Add the `CREATE OR REPLACE PYTHON3 SCALAR SCRIPT` DDL to `scripts/create_udfs.sql`

## 3. EMBED_AND_PUSH UDF

- [x] 3.1 Create `exasol_udfs/embed_and_push.py` with the SET UDF skeleton (`run`, `emit`)
- [x] 3.2 Implement OpenAI embedding provider with batch size 100 and exponential back-off retry (3 attempts)
- [x] 3.3 Implement local sentence-transformers embedding provider loading from SLC model cache
- [x] 3.4 Implement Qdrant batch upsert logic; store `id` and `text` as payload fields
- [x] 3.5 Emit a summary row per partition: `(partition_id, upserted_count)`
- [x] 3.6 Add the `CREATE OR REPLACE PYTHON3 SET SCRIPT` DDL to `scripts/create_udfs.sql`

## 4. Tests

- [x] 4.1 Write unit tests for the OpenAI embedding provider (mock `openai.Embeddings.create`)
- [x] 4.2 Write unit tests for the sentence-transformers provider
- [x] 4.3 Write unit tests for the Qdrant upsert logic (mock `QdrantClient`)
- [x] 4.4 Write unit tests for `create_collection.py` (collection exists / does not exist / invalid metric)
- [x] 4.5 Write an integration test script (`tests/integration/test_udf_ingestion.py`) using a local Qdrant Docker container

## 5. Documentation

- [x] 5.1 Create `docs/udf-ingestion.md` with end-to-end SQL walkthrough (build SLC → deploy UDFs → create collection → run ingestion → run semantic search)
- [x] 5.2 Document the `EMBED_AND_PUSH` and `CREATE_QDRANT_COLLECTION` UDF signatures and all parameters
- [x] 5.3 Add a note about secrets-in-SQL risk and Exasol connection object alternative
- [x] 5.4 Update `README.md` with a "Ingestion via UDF" section linking to the new doc
