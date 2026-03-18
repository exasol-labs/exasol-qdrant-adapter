## ADDED Requirements

### Requirement: Semantic similarity search via SELECT
The adapter SHALL intercept `SELECT` statements against a vector virtual schema table that include a query string filter, forward the raw query text to Qdrant for embedding and similarity search, and return results as a standard Exasol result set containing the record ID, original text payload, and similarity score.

#### Scenario: Basic similarity search
- **WHEN** a user executes `SELECT id, text, score FROM <schema>.<table> WHERE query = '<query_string>' LIMIT <k>`
- **THEN** the adapter forwards `<query_string>` to Qdrant's search endpoint for the collection
- **AND** Qdrant computes the query embedding using the collection's inference model and returns the top `<k>` most similar points
- **AND** the adapter returns a result set with columns: `id` (VARCHAR), `text` (VARCHAR), `score` (DOUBLE)

#### Scenario: LIMIT controls top-k results
- **WHEN** a `LIMIT` clause is present in the `SELECT` statement
- **THEN** the adapter maps the limit value to Qdrant's `limit` (top-k) parameter
- **AND** no more than `<k>` rows are returned

#### Scenario: Results compatible with downstream SQL
- **WHEN** the search result set is returned
- **THEN** it can be used in downstream SQL operations such as `ORDER BY score DESC`, joins, and subqueries within Exasol

#### Scenario: No results found
- **WHEN** the Qdrant collection exists but no points are semantically close to the query
- **THEN** the adapter returns an empty result set (zero rows) without error

#### Scenario: Search on empty collection
- **WHEN** a `SELECT` with a query string is executed against a collection with no points
- **THEN** the adapter returns an empty result set without error
