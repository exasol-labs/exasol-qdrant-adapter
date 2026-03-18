## ADDED Requirements

### Requirement: Create vector collection via CREATE TABLE
The adapter SHALL intercept a `CREATE TABLE` statement targeting the vector virtual schema and translate it into a Qdrant collection creation request. The collection SHALL be configured with the embedding model specified in the virtual schema properties, using cosine similarity as the distance metric.

#### Scenario: Successful collection creation
- **WHEN** a user executes `CREATE TABLE <schema>.<name> (id VARCHAR(36), text VARCHAR(2000000))` against the vector virtual schema
- **THEN** the adapter creates a Qdrant collection named `<name>` with a named vector field configured for the schema's inference model and cosine distance
- **AND** the table becomes immediately queryable in the virtual schema

#### Scenario: Collection already exists
- **WHEN** a user executes `CREATE TABLE` for a name that already exists as a Qdrant collection
- **THEN** the adapter returns a meaningful error message indicating the collection already exists
- **AND** no changes are made to the existing collection

#### Scenario: Inference model unavailable
- **WHEN** a user executes `CREATE TABLE` and the configured inference model is not available in Qdrant
- **THEN** the adapter returns an error message identifying the unavailable model
- **AND** no collection is created

#### Scenario: Collection appears in virtual schema
- **WHEN** a collection is successfully created
- **THEN** the table is visible and queryable in the virtual schema without requiring a schema refresh
