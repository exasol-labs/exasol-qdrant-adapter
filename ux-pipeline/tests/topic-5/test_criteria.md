# Test Criteria: Topic 5 - No Sample Data / Hello World Block

## Prerequisites
- Virtual schema `vector_schema` exists and is functional
- ADAPTER schema exists with UDFs deployed
- Qdrant and Ollama are running

## Test Cases

| # | Query / Check | Expected Outcome | Pass Criteria |
|---|-------|-----------------|---------------|
| 1 | Search README.md for "Hello World" section | Hello World section exists | File contains "Hello World" heading and SQL examples |
| 2 | Search install_all.sql for "Hello World" section | Hello World example in usage comments | File contains "Hello World" in comments section |
| 3 | Verify Hello World example works: create table, insert, ingest, search | End-to-end hello world succeeds | Search returns relevant results ranked by similarity |
| 4 | `SELECT "ID", "TEXT", "SCORE" FROM vector_schema.bank_failures WHERE "QUERY" = 'bank failure' LIMIT 3` | Existing search still works | Returns rows with SCORE > 0 |

## Negative Tests

| # | Query | Expected Outcome | Pass Criteria |
|---|-------|-----------------|---------------|
| 1 | Hello World example uses EMBED_AND_PUSH_V2 (not V1) | V2 is the recommended method | README example uses EMBED_AND_PUSH_V2 |
