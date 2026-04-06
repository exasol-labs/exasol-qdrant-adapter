# Test Criteria: Topic 14 - No SCORE Filtering

## Test Cases
| # | Query | Pass Criteria |
|---|-------|---------------|
| 1 | `SELECT "ID", "TEXT", "SCORE" FROM vector_schema.bank_failures WHERE "QUERY" = 'banks in New York' AND "SCORE" > 0.6 LIMIT 5` | Returns rows with all SCORE > 0.6 |
| 2 | README documents SCORE filtering | Contains "SCORE filtering" section |
