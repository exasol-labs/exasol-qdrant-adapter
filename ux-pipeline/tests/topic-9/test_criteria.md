# Test Criteria: Topic 9 - Version Tracking

## Test Cases

| # | Query | Expected Outcome | Pass Criteria |
|---|-------|-----------------|---------------|
| 1 | `SELECT SCRIPT_TEXT FROM SYS.EXA_ALL_SCRIPTS WHERE SCRIPT_NAME = 'VECTOR_SCHEMA_ADAPTER' AND SCRIPT_SCHEMA = 'ADAPTER'` | Script text contains version constant | Contains 'ADAPTER_VERSION = "2.1.0"' |
| 2 | `SELECT "ID", "TEXT", "SCORE" FROM vector_schema.bank_failures WHERE "QUERY" = 'test' LIMIT 1` | Search still works (regression) | Returns at least 1 row |
