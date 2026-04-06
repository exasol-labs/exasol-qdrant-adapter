# Test Criteria: Topic 2 - API Keys Exposed in Audit Logs

## Prerequisites
- Virtual schema `vector_schema` exists and is functional
- ADAPTER schema exists with both EMBED_AND_PUSH and EMBED_AND_PUSH_V2 scripts
- Qdrant has at least one collection with data (bank_failures)
- Ollama is running with nomic-embed-text model
- CONNECTION `embedding_conn` exists with config JSON

## Test Cases

| # | Query | Expected Outcome | Pass Criteria |
|---|-------|-----------------|---------------|
| 1 | `SELECT SCRIPT_TEXT FROM SYS.EXA_ALL_SCRIPTS WHERE SCRIPT_NAME = 'EMBED_AND_PUSH' AND SCRIPT_SCHEMA = 'ADAPTER'` | Script exists and contains deprecation warning | SCRIPT_TEXT contains 'DEPRECATED' or 'SECURITY WARNING' or 'audit' |
| 2 | `SELECT SCRIPT_TEXT FROM SYS.EXA_ALL_SCRIPTS WHERE SCRIPT_NAME = 'EMBED_AND_PUSH_V2' AND SCRIPT_SCHEMA = 'ADAPTER'` | V2 script exists and uses CONNECTION | SCRIPT_TEXT contains 'exa.get_connection' |
| 3 | `SELECT CONNECTION_NAME FROM SYS.EXA_ALL_CONNECTIONS WHERE CONNECTION_NAME = 'EMBEDDING_CONN'` | embedding_conn CONNECTION exists | Returns exactly 1 row |
| 4 | `SELECT "ID", "TEXT", "SCORE" FROM vector_schema.bank_failures WHERE "QUERY" = 'banks in New York' LIMIT 3` | Semantic search still works (no regression) | Returns rows with SCORE > 0, no error |

## Negative Tests

| # | Query | Expected Outcome | Pass Criteria |
|---|-------|-----------------|---------------|
| 1 | `SELECT CONNECTION_STRING FROM SYS.EXA_ALL_CONNECTIONS WHERE CONNECTION_NAME = 'EMBEDDING_CONN'` | CONNECTION address is visible (contains config JSON) but password field should not expose secrets | CONNECTION_STRING contains 'qdrant_url' (config is in address, not password) |
