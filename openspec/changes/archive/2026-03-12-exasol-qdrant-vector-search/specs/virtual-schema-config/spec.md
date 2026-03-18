## ADDED Requirements

### Requirement: Configure virtual schema with Qdrant connection properties
The adapter SHALL allow an Exasol administrator to define the Qdrant connection URL, API key, and inference model name once at virtual schema creation time. Individual users SHALL NOT need to specify credentials or model selection per query or per insert.

#### Scenario: Virtual schema creation with connection object
- **WHEN** an administrator executes `CREATE VIRTUAL SCHEMA` referencing an Exasol `CONNECTION` object that contains the Qdrant URL and API key, and sets the inference model name as a virtual schema property
- **THEN** the adapter uses those values for all subsequent operations against the schema without requiring per-query credential input

#### Scenario: Credentials stored via connection object
- **WHEN** the virtual schema is created
- **THEN** the Qdrant API key is stored exclusively in the Exasol `CONNECTION` object and not in plaintext virtual schema properties

#### Scenario: Model propagated to collection creation
- **WHEN** a user creates a table via `CREATE TABLE` after the virtual schema is configured
- **THEN** the adapter uses the schema-level inference model name when configuring the Qdrant collection
- **AND** the user does not specify the model name in the `CREATE TABLE` statement

#### Scenario: Model implicit for inserts and queries
- **WHEN** a user runs `INSERT INTO` or `SELECT` against the virtual schema
- **THEN** the adapter uses the schema-level inference model without requiring the user to specify it

### Requirement: Update virtual schema properties without recreation
The adapter SHALL support updating virtual schema properties (connection reference, model name) without requiring the virtual schema to be dropped and recreated.

#### Scenario: Property update takes effect immediately
- **WHEN** an administrator executes `ALTER VIRTUAL SCHEMA ... SET <property> = '<new_value>'`
- **THEN** subsequent operations against the schema use the updated property value
- **AND** previously created collections are not affected by the property change unless explicitly operated on
