## MODIFIED Requirements

### Requirement: Configure virtual schema with Qdrant connection properties
The adapter SHALL allow an Exasol administrator to define the Qdrant connection URL, API key, and inference model name once at virtual schema creation time via a `CREATE OR REPLACE LUA ADAPTER SCRIPT` statement followed by `CREATE VIRTUAL SCHEMA`. Individual users SHALL NOT need to specify credentials or model selection per query or per insert. The adapter script body SHALL be the contents of `dist/adapter.lua` — no BucketFS upload or JAR file is required.

#### Scenario: Virtual schema creation with connection object
- **WHEN** an administrator executes `CREATE VIRTUAL SCHEMA` referencing an Exasol `CONNECTION` object that contains the Qdrant URL and API key, and sets the inference model name as a virtual schema property
- **THEN** the adapter uses those values for all subsequent operations against the schema without requiring per-query credential input

#### Scenario: Credentials stored via connection object
- **WHEN** the virtual schema is created
- **THEN** the Qdrant API key is stored exclusively in the Exasol `CONNECTION` object and not in plaintext virtual schema properties

#### Scenario: Adapter installed via LUA ADAPTER SCRIPT, not BucketFS
- **WHEN** an administrator installs the adapter
- **THEN** they execute `CREATE OR REPLACE LUA ADAPTER SCRIPT ADAPTER.VECTOR_SCHEMA_ADAPTER AS <dist/adapter.lua contents> /`
- **AND** no JAR upload, BucketFS path, or Maven build is required

#### Scenario: Model implicit for queries
- **WHEN** a user runs `SELECT` against the virtual schema
- **THEN** the adapter uses the schema-level inference model without requiring the user to specify it
