## ADDED Requirements

### Requirement: MetadataReader fetches Qdrant collections and returns table metadata
`MetadataReader` SHALL make an HTTP GET request to `{qdrant_url}/collections`, parse the response, and return a list of table metadata objects — one per collection. Each table SHALL expose four columns: `ID` (VARCHAR), `TEXT` (VARCHAR), `SCORE` (DOUBLE), `QUERY` (VARCHAR).

#### Scenario: Collections returned as virtual tables
- **WHEN** Qdrant responds with a list of collection names
- **THEN** MetadataReader returns one table descriptor per collection
- **AND** each table has columns ID VARCHAR(2000000), TEXT VARCHAR(2000000), SCORE DOUBLE, QUERY VARCHAR(2000000)

#### Scenario: api-key header sent when present
- **WHEN** the Qdrant connection contains a non-empty API key
- **THEN** MetadataReader includes the `api-key` header on the GET request

#### Scenario: Empty collection list returns empty table list
- **WHEN** Qdrant responds with zero collections
- **THEN** MetadataReader returns an empty list without error

### Requirement: MetadataReader contains no query rewrite logic
`MetadataReader` SHALL only perform collection discovery. It SHALL NOT construct or return any SELECT or VALUES SQL.

#### Scenario: MetadataReader result contains only metadata
- **WHEN** MetadataReader is called
- **THEN** its return value contains only table and column descriptors
- **AND** it does not contain any SQL strings
