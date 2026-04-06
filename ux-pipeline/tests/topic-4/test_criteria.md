# Test Criteria: Topic 4 - Python UDF Raw Tracebacks

## Prerequisites
- ADAPTER schema exists with EMBED_AND_PUSH, EMBED_AND_PUSH_V2, CREATE_QDRANT_COLLECTION scripts
- Virtual schema `vector_schema` exists
- Qdrant and Ollama are running

## Test Cases

| # | Query | Expected Outcome | Pass Criteria |
|---|-------|-----------------|---------------|
| 1 | Check install_all.sql contains URLError handling | All HTTP functions handle URLError | File contains "urllib.error.URLError" in both V1 and V2 sections |
| 2 | Check install_all.sql error messages include URL | Error messages include the URL that failed | File contains "Connection to" and "failed:" pattern |
| 3 | `SELECT ADAPTER.CREATE_QDRANT_COLLECTION('192.168.99.99', 6333, '', 'test_unreachable', 768, 'Cosine', '')` | Clean error about connection failure | Error contains "Connection to" or "failed" (not raw urllib traceback) |
| 4 | `SELECT "ID", "TEXT", "SCORE" FROM vector_schema.bank_failures WHERE "QUERY" = 'bank failure' LIMIT 3` | Normal search still works (no regression) | Returns rows with SCORE > 0 |

## Negative Tests

| # | Query | Expected Outcome | Pass Criteria |
|---|-------|-----------------|---------------|
| 1 | Check that no bare `raise` without context exists in error paths | All errors wrapped with clean messages | URLError handlers always produce "Connection to X failed: reason" format |
