## ADDED Requirements

### Requirement: EMBED_AND_PUSH SET UDF embeds text rows and upserts them into Qdrant
The system SHALL provide an Exasol SET UDF named `EMBED_AND_PUSH` that accepts text rows from an Exasol table, generates vector embeddings via a configurable provider, and upserts the resulting points into a Qdrant collection in batches.

#### Scenario: Successful ingestion with OpenAI embeddings
- **WHEN** a user executes `SELECT EMBED_AND_PUSH(id, text, qdrant_host, qdrant_port, qdrant_api_key, collection_name, 'openai', openai_api_key, model_name) FROM source_table GROUP BY IPROC()`
- **THEN** the UDF SHALL call the OpenAI embeddings API in batches of up to 100 texts
- **AND** upsert all resulting points to the specified Qdrant collection
- **AND** store the original `id` and `text` as Qdrant payload fields on each point
- **AND** return a single summary row per partition with the count of successfully upserted points

#### Scenario: Successful ingestion with local sentence-transformers
- **WHEN** a user specifies `provider='local'` and a sentence-transformers model name
- **THEN** the UDF SHALL load the model from the SLC's bundled model cache
- **AND** generate embeddings locally without calling any external API
- **AND** upsert resulting points to Qdrant

#### Scenario: Batch size respected
- **WHEN** the source table partition contains more than 100 rows
- **THEN** the UDF SHALL split the rows into batches of 100
- **AND** call the embedding API and Qdrant upsert once per batch, not once per row

#### Scenario: Duplicate ID upsert
- **WHEN** a point with the same `id` already exists in the Qdrant collection
- **THEN** the UDF SHALL upsert (overwrite) the existing point with the new embedding and payload

#### Scenario: Embedding API failure
- **WHEN** the embedding provider returns an error (rate limit, invalid key, network timeout)
- **THEN** the UDF SHALL retry up to 3 times with exponential back-off
- **AND** if all retries fail, raise an Exasol UDF error with a message identifying the failure cause and the batch that failed

#### Scenario: Qdrant upsert failure
- **WHEN** the Qdrant API returns an error during upsert
- **THEN** the UDF SHALL raise an Exasol UDF error with the Qdrant error message
- **AND** the calling SELECT statement SHALL fail

### Requirement: UDF is partitioned across Exasol nodes using IPROC()
The system SHALL support partitioning the ingestion workload across Exasol cluster nodes by grouping on `IPROC()`, so each node processes its local data slice independently.

#### Scenario: Multi-node partitioned ingestion
- **WHEN** a user groups by `IPROC()` in the SELECT statement
- **THEN** each Exasol node SHALL run the UDF independently for its partition
- **AND** all partitions SHALL be upserted to the same Qdrant collection

#### Scenario: Single-node unpartitioned ingestion
- **WHEN** a user omits `GROUP BY IPROC()` (single partition)
- **THEN** all rows SHALL be processed by a single UDF invocation
- **AND** ingestion SHALL still complete successfully
