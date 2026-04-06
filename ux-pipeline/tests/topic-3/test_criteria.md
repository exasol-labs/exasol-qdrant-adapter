# Test Criteria: Topic 3 - CASCADE Destroys ADAPTER Schema

## Prerequisites
- Virtual schema `vector_schema` exists and is functional
- ADAPTER schema exists with scripts and connections
- Qdrant has bank_failures collection with data

## Test Cases

| # | Query / Check | Expected Outcome | Pass Criteria |
|---|-------|-----------------|---------------|
| 1 | Read `scripts/install_all.sql` and search for `DROP.*VIRTUAL.*SCHEMA.*CASCADE` | No CASCADE on virtual schema drops | No match found in install_all.sql |
| 2 | Read `docs/deployment.md` and search for `DROP.*VIRTUAL.*SCHEMA.*CASCADE` | No CASCADE on virtual schema drops in docs | No match found |
| 3 | Read `scripts/install_all.sql` and search for `DROP FORCE VIRTUAL SCHEMA` | Uses DROP FORCE instead | Match found |
| 4 | Read `README.md` and search for `Why not CASCADE` | Warning about CASCADE danger exists | Match found explaining CASCADE destroys ADAPTER schema |
| 5 | `SELECT "ID", "TEXT", "SCORE" FROM vector_schema.bank_failures WHERE "QUERY" = 'bank failure' LIMIT 3` | Semantic search still works | Returns rows with SCORE > 0 |

## Negative Tests

| # | Query | Expected Outcome | Pass Criteria |
|---|-------|-----------------|---------------|
| 1 | Search all .sql files in scripts/ for `DROP VIRTUAL SCHEMA.*CASCADE` (not inside comments) | No actionable CASCADE statements | No matches in executable SQL |
