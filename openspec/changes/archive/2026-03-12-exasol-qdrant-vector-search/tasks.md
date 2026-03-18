## 1. Project Setup

- [x] 1.1 Create a new Maven project with Exasol `virtual-schema-api` and `virtual-schema-common-java` dependencies
- [x] 1.2 Add OkHttp (or Apache HttpClient) dependency for Qdrant REST API calls
- [x] 1.3 Add Jackson dependency for JSON serialisation/deserialisation
- [x] 1.4 Configure Maven Shade plugin to produce a fat JAR for BucketFS deployment
- [x] 1.5 Set up unit test framework (JUnit 5 + Mockito)

## 2. Virtual Schema Configuration (US-04)

- [x] 2.1 Define virtual schema property constants: `QDRANT_URL`, `CONNECTION_NAME`, `QDRANT_MODEL`
- [x] 2.2 Implement `AdapterProperties` class that reads and validates properties from the virtual schema definition
- [x] 2.3 Implement credential resolution: read `CONNECTION_NAME` property, look up Exasol connection object for URL and API key
- [x] 2.4 Write unit tests for property validation (missing required props, invalid values)

## 3. Qdrant REST Client

- [x] 3.1 Implement `QdrantClient` with base URL + API key authentication headers
- [x] 3.2 Implement `createCollection(name, modelName)` → `PUT /collections/{name}`
- [x] 3.3 Implement `upsertPoints(collectionName, List<Point>)` → `PUT /collections/{name}/points` (with batching at 100 points)
- [x] 3.4 Implement `searchPoints(collectionName, queryText, limit)` → `POST /collections/{name}/points/query` using Qdrant inference
- [x] 3.5 Implement `collectionExists(name)` → `GET /collections/{name}` (used for duplicate-check on CREATE TABLE)
- [x] 3.6 Implement error handling: map Qdrant HTTP error responses to descriptive adapter exceptions
- [x] 3.7 Write unit tests for `QdrantClient` using a mock HTTP server

## 4. ID Mapping

- [x] 4.1 Implement `IdMapper` that converts VARCHAR IDs to deterministic UUID v5 (namespace: adapter-specific)
- [x] 4.2 Store the original VARCHAR ID in the Qdrant point payload under key `_original_id`
- [x] 4.3 Write unit tests for deterministic UUID generation and round-trip ID recovery

## 5. DDL Handler — CREATE TABLE (US-01)

- [x] 5.1 Implement `CreateTableHandler` that receives the push-down DDL request and extracts the table name
- [x] 5.2 Call `QdrantClient.collectionExists()` — throw a descriptive error if it does; proceed otherwise
- [x] 5.3 Call `QdrantClient.createCollection()` with the table name and schema-level model
- [x] 5.4 Register the new table in the virtual schema metadata so it appears immediately queryable
- [x] 5.5 Write integration tests for CREATE TABLE against a real (or testcontainer) Qdrant instance

## 6. DML Handler — INSERT INTO (US-02)

- [x] 6.1 Implement `InsertHandler` that parses the push-down insert rows (id + text columns)
- [x] 6.2 Map each row to a `Point` using `IdMapper` for ID and raw text as payload
- [x] 6.3 Call `QdrantClient.upsertPoints()` in batches
- [x] 6.4 Propagate Qdrant errors back as adapter exceptions with clear messages
- [x] 6.5 Write unit tests for batch chunking logic (verify chunks of ≤100)
- [x] 6.6 Write integration tests for single and batch inserts

## 7. Query Handler — SELECT / Similarity Search (US-03)

- [x] 7.1 Implement `SelectHandler` that identifies similarity search requests (filter contains query string condition)
- [x] 7.2 Extract query string from the push-down filter/function argument
- [x] 7.3 Extract LIMIT value from push-down request (default to 10 if absent)
- [x] 7.4 Call `QdrantClient.searchPoints()` and map results to Exasol rows: `(id VARCHAR, text VARCHAR, score DOUBLE)`
- [x] 7.5 Return original VARCHAR ID from payload (`_original_id`), not the UUID
- [x] 7.6 Handle empty result sets (return zero rows, no error)
- [x] 7.7 Write unit tests for query string extraction and result mapping
- [x] 7.8 Write integration tests for end-to-end similarity search

## 8. Adapter Wiring

- [x] 8.1 Implement the main `VectorSchemaAdapter` class extending `AbstractVirtualSchemaAdapter`
- [x] 8.2 Route `CREATE TABLE`, `INSERT`, and `SELECT` push-downs to the correct handler
- [x] 8.3 Implement `getCapabilities()` returning only the capabilities the adapter supports
- [x] 8.4 Write integration tests that exercise the full adapter via Exasol's virtual schema adapter test harness

## 9. Deployment & Documentation

- [x] 9.1 Build the fat JAR via `mvn package`
- [x] 9.2 Write deployment instructions: upload JAR to BucketFS, create CONNECTION object, create VIRTUAL SCHEMA
- [x] 9.3 Write a usage guide with example SQL for CREATE TABLE, INSERT, and SELECT
- [x] 9.4 Document limitations: unsupported DDL operations, model-change behaviour, ID conversion
- [x] 9.5 Test end-to-end on a real Exasol + Qdrant environment
