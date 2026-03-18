## ADDED Requirements

### Requirement: Insert text rows via INSERT INTO
The adapter SHALL intercept `INSERT INTO` statements targeting a vector virtual schema table and forward each row's text value to Qdrant as a point upsert. Qdrant SHALL compute and store the embedding using the collection's configured inference model. The original text SHALL be stored as a Qdrant payload field.

#### Scenario: Single row insert
- **WHEN** a user executes `INSERT INTO <schema>.<table> VALUES ('<id>', '<text>')`
- **THEN** the adapter upserts a point to the corresponding Qdrant collection with a UUID derived from `<id>`, the original `<id>` stored in payload, the `<text>` stored in payload, and the embedding computed by Qdrant's inference API

#### Scenario: Batch insert
- **WHEN** a user inserts multiple rows in a single `INSERT INTO` statement
- **THEN** the adapter batches the upsert requests (up to 100 points per Qdrant API call) and forwards all rows to Qdrant
- **AND** all rows are stored after the statement completes

#### Scenario: Insert failure
- **WHEN** the Qdrant API returns an error during ingestion (e.g., inference failure, network error)
- **THEN** the adapter returns a clear error message identifying the failure cause
- **AND** the `INSERT` statement fails

#### Scenario: Duplicate ID upsert
- **WHEN** a user inserts a row with an ID that already exists in the collection
- **THEN** the adapter upserts the point, replacing the existing embedding and payload with the new values
