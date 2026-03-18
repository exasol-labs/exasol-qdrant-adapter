## ADDED Requirements

### Requirement: CREATE_QDRANT_COLLECTION scalar UDF creates or verifies a Qdrant collection
The system SHALL provide an Exasol scalar UDF named `CREATE_QDRANT_COLLECTION` that creates a Qdrant collection with the specified vector dimension and distance metric, or returns a confirmation message if the collection already exists.

#### Scenario: Collection does not exist — created successfully
- **WHEN** a user calls `SELECT CREATE_QDRANT_COLLECTION(host, port, api_key, collection_name, vector_size, distance_metric)`
- **AND** no collection with that name exists in Qdrant
- **THEN** the UDF SHALL create the collection with the given vector size and distance metric
- **AND** return the string `'created: <collection_name>'`

#### Scenario: Collection already exists
- **WHEN** a collection with the specified name already exists in Qdrant
- **THEN** the UDF SHALL NOT modify the existing collection
- **AND** return the string `'exists: <collection_name>'`

#### Scenario: Invalid distance metric
- **WHEN** the user passes a distance metric not supported by Qdrant (not one of `Cosine`, `Dot`, `Euclid`, `Manhattan`)
- **THEN** the UDF SHALL raise an Exasol UDF error listing the valid options

#### Scenario: Qdrant connection failure
- **WHEN** the Qdrant host is unreachable or the API key is invalid
- **THEN** the UDF SHALL raise an Exasol UDF error with the connection error details

### Requirement: Vector size is inferred automatically when model name is provided
The system SHALL allow users to omit the explicit `vector_size` parameter and instead pass a known embedding model name, from which the UDF SHALL infer the correct vector dimension.

#### Scenario: Vector size inferred from OpenAI model name
- **WHEN** the user passes `model_name='text-embedding-3-small'` and `vector_size=NULL`
- **THEN** the UDF SHALL use vector size `1536` automatically

#### Scenario: Vector size inferred from sentence-transformers model
- **WHEN** the user passes a known sentence-transformers model and `vector_size=NULL`
- **THEN** the UDF SHALL load the model, determine its output dimension, and use that value

#### Scenario: Unknown model and no explicit vector size
- **WHEN** both `model_name` is unknown/unrecognized and `vector_size` is NULL
- **THEN** the UDF SHALL raise an Exasol UDF error asking the user to provide an explicit vector size
