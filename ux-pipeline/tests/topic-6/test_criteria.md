# Test Criteria: Topic 6 - OLLAMA_URL Default Misleading

## Prerequisites
- Virtual schema `VS` or `vector_schema` exists and is functional
- Qdrant has the `bank_failures` collection with data
- Ollama is running with nomic-embed-text model

## Test Cases

| # | Query | Expected Outcome | Pass Criteria |
|---|-------|-----------------|---------------|
| 1 | `SELECT "ID", "TEXT", "SCORE" FROM vector_schema.bank_failures WHERE "QUERY" = 'large bank failures' LIMIT 3` | Returns results — proves OLLAMA_URL is correctly set via property | Returns rows with non-null ID, TEXT, and SCORE > 0 |
| 2 | `SELECT SCRIPT_TEXT FROM SYS.EXA_ALL_SCRIPTS WHERE SCRIPT_NAME = 'VECTOR_SCHEMA_ADAPTER' AND SCRIPT_SCHEMA = 'ADAPTER'` | Script contains assert for OLLAMA_URL | Script text contains "OLLAMA_URL property is not set" |

## Negative Tests

| # | Query | Expected Outcome | Pass Criteria |
|---|-------|-----------------|---------------|
| 1 | Create a virtual schema without OLLAMA_URL and try to query it | Should fail with a clear error mentioning OLLAMA_URL | Error message contains "OLLAMA_URL" and mentions Docker bridge or localhost |
