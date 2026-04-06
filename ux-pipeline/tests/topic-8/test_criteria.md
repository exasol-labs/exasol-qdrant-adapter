# Test Criteria: Topic 8 - Silent Behavior on Unsupported Predicates

## Prerequisites
- Virtual schema `vector_schema` exists and is functional
- Qdrant has the `bank_failures` collection with data
- Ollama is running with nomic-embed-text model

## Test Cases

| # | Query | Expected Outcome | Pass Criteria |
|---|-------|-----------------|---------------|
| 1 | `SELECT "ID", "TEXT", "SCORE" FROM vector_schema.bank_failures WHERE "QUERY" = 'banks in New York' LIMIT 3` | Normal search results | Returns rows with non-null ID, TEXT, and SCORE > 0 |
| 2 | `SELECT * FROM vector_schema.bank_failures` | Hint row with SCORE=1 | Returns at least 1 row; ID contains 'HINT'; SCORE = 1.0 |
| 3 | `SELECT "ID", "TEXT", "SCORE", "QUERY" FROM vector_schema.bank_failures` | Hint row with descriptive QUERY column | QUERY column contains text about supported predicates |

## Negative Tests

| # | Query | Expected Outcome | Pass Criteria |
|---|-------|-----------------|---------------|
| 1 | `SELECT * FROM vector_schema.bank_failures WHERE "SCORE" > 0.5` | Hint row survives the post-filter | Returns at least 1 row (the hint row has SCORE=1.0 which passes > 0.5) |
