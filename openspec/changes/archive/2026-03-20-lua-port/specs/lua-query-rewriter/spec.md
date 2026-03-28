## ADDED Requirements

### Requirement: QueryRewriter embeds query text via Ollama
`QueryRewriter` SHALL POST to `{ollama_url}/api/embeddings` with `{"model": "<qdrant_model>", "prompt": "<query_text>"}` and extract the `embedding` array from the response.

#### Scenario: Embedding request sent with correct model and prompt
- **WHEN** a pushDown request contains a filter `COLUMN = 'some query text'`
- **THEN** QueryRewriter POSTs to Ollama with the configured model name and the filter value as the prompt

#### Scenario: Embedding response parsed correctly
- **WHEN** Ollama responds with `{"embedding": [0.1, 0.2, ...]}`
- **THEN** QueryRewriter extracts the float array for use in the Qdrant search request

### Requirement: QueryRewriter searches Qdrant with the embedding vector
`QueryRewriter` SHALL POST to `{qdrant_url}/collections/{collection}/points/search` with the embedding vector, the requested limit, and `with_payload: true`. The `api-key` header SHALL be included when present.

#### Scenario: Vector search request uses correct collection and limit
- **WHEN** the pushDown request targets collection `my_docs` with LIMIT 10
- **THEN** QueryRewriter POSTs to `/collections/my_docs/points/search` with `"limit": 10`

#### Scenario: Named vector field used in search body
- **WHEN** QueryRewriter constructs the search request
- **THEN** the vector is sent as `{"vector": {"name": "text", "vector": [...]}}` in the request body

### Requirement: QueryRewriter returns VALUES SQL for non-empty results
When Qdrant returns one or more results, `QueryRewriter` SHALL return a SQL string of the form:
```
SELECT * FROM VALUES (CAST(...), ...), ... AS t(ID, TEXT, SCORE, QUERY)
```
with each column cast to its declared type.

#### Scenario: Results inlined as VALUES clause
- **WHEN** Qdrant returns N result objects
- **THEN** QueryRewriter produces a VALUES SQL with N rows
- **AND** each row contains CAST(id AS VARCHAR(2000000) UTF8), CAST(text AS VARCHAR(2000000) UTF8), CAST(score AS DOUBLE), CAST(query AS VARCHAR(2000000) UTF8)

### Requirement: QueryRewriter returns empty-result SQL when Qdrant returns no matches
When Qdrant returns zero results, `QueryRewriter` SHALL return a SQL string that produces zero rows with the correct column types.

#### Scenario: Empty result set SQL
- **WHEN** Qdrant returns an empty results array
- **THEN** QueryRewriter returns a SQL of the form:
  `SELECT CAST('' AS VARCHAR(36) UTF8) AS ID, CAST('' AS VARCHAR(2000000) UTF8) AS TEXT, CAST(0 AS DOUBLE) AS SCORE, CAST('' AS VARCHAR(2000000) UTF8) AS QUERY FROM DUAL WHERE FALSE`
