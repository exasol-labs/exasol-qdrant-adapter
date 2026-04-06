# Test Criteria: Topic 1 - Virtual Schema Ghost State

## Prerequisites
- Exasol is running and reachable
- Qdrant is running with at least one collection
- Ollama is running with nomic-embed-text model
- The adapter has been deployed via install_all.sql

## Test Cases

| # | Query / Action | Expected Outcome | Pass Criteria |
|---|----------------|-----------------|---------------|
| 1 | `SELECT SCHEMA_NAME FROM SYS.EXA_ALL_VIRTUAL_SCHEMAS WHERE SCHEMA_NAME = 'VS'` | Virtual schema VS exists | Returns exactly 1 row |
| 2 | `SELECT SCRIPT_NAME FROM SYS.EXA_ALL_SCRIPTS WHERE SCRIPT_SCHEMA = 'ADAPTER'` | ADAPTER schema scripts still exist after deployment | Returns at least 1 row (scripts not destroyed by CASCADE) |
| 3 | Read install_all.sql and check for CASCADE | No CASCADE in DROP VIRTUAL SCHEMA statements | The string `CASCADE` does not appear in any DROP VIRTUAL SCHEMA line |
| 4 | Read install_all.sql and check for DROP FORCE | Uses DROP FORCE instead of plain DROP | The line contains `DROP FORCE VIRTUAL SCHEMA IF EXISTS` |
| 5 | Read install_all.sql and check REFRESH is commented out | No active ALTER VIRTUAL SCHEMA REFRESH statement | The REFRESH is commented out or removed |
| 6 | Read README.md for troubleshooting section | Ghost state workaround is documented | README contains a Troubleshooting section mentioning "ghost", "DROP FORCE", and session reconnect |

## Negative Tests

| # | Query | Expected Outcome | Pass Criteria |
|---|-------|-----------------|---------------|
| 1 | `DROP FORCE VIRTUAL SCHEMA IF EXISTS nonexistent_schema_xyz` | Should succeed silently (IF EXISTS handles missing schema) | No error thrown |
