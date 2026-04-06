# Iteration 07 -- Documentation-First User Study

**Date:** 2026-04-05
**Persona:** Documentation-first user who reads the entire README top to bottom before touching anything.
**Focus:** Documentation accuracy, example runnability, gaps between docs and actual behavior.
**Method:** Read README.md completely, then follow every step sequentially, testing every example and claim.

---

## UX Score: 7.4 / 10

**Scoring weights (documentation-first persona):**

| Dimension | Weight | Score | Weighted |
|-----------|--------|-------|----------|
| README accuracy (claims vs reality) | 30% | 8.0 | 2.40 |
| Example runnability (can I copy-paste and run?) | 25% | 6.5 | 1.63 |
| Completeness (are all behaviors documented?) | 20% | 7.0 | 1.40 |
| Error message quality | 10% | 8.5 | 0.85 |
| Onboarding flow (does the order make sense?) | 15% | 7.5 | 1.13 |
| **Total** | **100%** | | **7.41** |

---

## Doc Claim vs Actual Behavior Table

| # | Doc Claim (README section) | Location | Actual Behavior | Verdict |
|---|---------------------------|----------|-----------------|---------|
| 1 | "No BucketFS, no JAR, no Maven, no pasting. One file, one run, everything deployed." | Quick Start, Step 3 | True when using a SQL client (DBeaver, DbVisualizer). The file uses `/` terminators which SQL clients handle but programmatic APIs (MCP, JDBC batch) do not. | MOSTLY TRUE -- needs clarification for non-GUI users |
| 2 | "Default: When no LIMIT clause is specified, results are capped at 10 rows." | Querying section | Confirmed. Query without LIMIT returns exactly 10 rows. The Lua adapter defaults `limit` to 10 in `rewrite()`. | TRUE |
| 3 | "Cosine similarity (0--1, higher = more similar)" | How It Works / Table columns | Confirmed. Observed scores range 0.37--0.70 for mixed-relevance queries. All within 0--1. | TRUE |
| 4 | "Each Qdrant collection appears as a table" | Querying section | Confirmed. After REFRESH, all Qdrant collections appear as virtual tables. Collection names are uppercased (e.g., `knowledge_base` becomes `KNOWLEDGE_BASE`). | TRUE -- but case transformation is undocumented |
| 5 | "Fixed 4-column schema: ID (VARCHAR), TEXT (VARCHAR), SCORE (DOUBLE), QUERY (VARCHAR)" | Table columns section | Confirmed exactly. All virtual tables have exactly these 4 columns in this order. | TRUE |
| 6 | "Always quote column names with double quotes" | Querying note | Necessary and correctly documented. Unquoted `QUERY` and `TEXT` would conflict with Exasol reserved words. | TRUE |
| 7 | "CONNECTION_NAME: Required" and "QDRANT_MODEL: Required" | Virtual Schema Properties | Confirmed. The Lua adapter's `check()` function asserts both are non-empty. | TRUE |
| 8 | "OLLAMA_URL: Default http://localhost:11434" | Virtual Schema Properties | True in the code. However, `localhost` is unreachable from inside the Exasol container, making the default useless in Docker deployments. | TRUE but misleading -- default never works in Docker |
| 9 | "host.docker.internal does NOT work in Exasol's UDF sandbox on Linux" | Docker networking note | Correctly documented. The note recommends `docker exec exasoldb ip route show default` to find the gateway IP. | TRUE |
| 10 | "Deployed as a single SQL statement" | How It Works | Partially true. The adapter itself is one CREATE ADAPTER SCRIPT statement. But the full stack is 6 statements (schema, connection, adapter, 2 UDFs, virtual schema). install_all.sql handles this. | MISLEADING -- one file, not one statement |
| 11 | "Update the 5 values in the CONFIGURATION section" (install_all.sql) | Quick Start | The 5 values are: schema name, host IP, Qdrant port, Ollama port, model name. Correctly documented and identified in the file header. | TRUE |
| 12 | "Use the Ollama container IP (find it with `docker inspect ollama`)" for UDFs | Loading Data, Option A | Correctly documented and essential. Using 172.17.0.1 for Ollama in EMBED_AND_PUSH fails; must use direct container IP (e.g., 172.17.0.4). | TRUE |
| 13 | Example: `SELECT ADAPTER.CREATE_QDRANT_COLLECTION('172.17.0.1', 6333, '', 'my_collection', 768, 'Cosine', '')` | Loading Data | Works. Returns "created: my_collection" on first run, "exists: my_collection" on subsequent runs. | TRUE |
| 14 | Example: `SELECT ADAPTER.EMBED_AND_PUSH(...)` with GROUP BY IPROC() | Loading Data | Works. Returns (partition_id, upserted_count). The GROUP BY IPROC() is required and documented. | TRUE |
| 15 | "No SLC or extra packages required" | Loading Data | True. Both UDFs use only Python stdlib (json, urllib, uuid, hashlib, socket, time). | TRUE |
| 16 | "Supported distance metrics: Cosine, Dot, Euclid, Manhattan" | docs/udf-ingestion.md | Confirmed in code: `_VALID_DISTANCES = {"Cosine", "Dot", "Euclid", "Manhattan"}`. | TRUE |
| 17 | "Texts longer than 6000 characters are automatically truncated" | docs/udf-ingestion.md | Confirmed in code: `MAX_CHARS = 6000` with `_truncate()` function. | TRUE |
| 18 | Project Structure: all listed files exist | Project Structure section | All 14 files/directories listed in the tree structure exist in the repository. | TRUE |
| 19 | `scripts/test_connectivity.sql` documented usage: `SELECT ADAPTER.TEST_OLLAMA()` etc. | test_connectivity.sql header | All 4 test functions work correctly: TEST_OLLAMA (HTTP 200), TEST_QDRANT (HTTP 200), TEST_EMBED (768-dim embedding), TEST_QDRANT_SEARCH. | TRUE |
| 20 | "Change properties without dropping the schema: ALTER VIRTUAL SCHEMA SET" | Virtual Schema Properties | Partially works but dangerous. ALTER SET triggers metadata re-read; if the adapter encounters an error during re-read, the virtual schema can enter a corrupted ghost state where it exists in SYS catalogs but is inaccessible to queries. | PARTIALLY TRUE -- silent corruption risk |
| 21 | "Results are ranked by cosine similarity score" | How It Works | Confirmed. Results come back sorted by SCORE descending (highest similarity first). | TRUE |
| 22 | "Works with any Ollama embedding model" | How It Works | Partially confirmed. Only tested with nomic-embed-text. The code is model-agnostic (passes model name to Ollama API). The CREATE_QDRANT_COLLECTION UDF has a dimension lookup table for 8 known models. | TRUE (with caveat: dimension lookup only covers 8 models) |
| 23 | README links: `docs/udf-ingestion.md` and `docs/lua-port/limitations.md` | Loading Data / Limitations | Both files exist and contain the content referenced. | TRUE |
| 24 | PowerShell Option B example | Loading Data | Syntactically correct. Uses proper Qdrant REST API endpoints and named vectors format. Not tested end-to-end but structure matches the working adapter. | LIKELY TRUE (not live-tested) |
| 25 | "No pre-computed embeddings needed -- the adapter calls Ollama automatically at query time" | How It Works | Confirmed. Each query triggers a real-time call to Ollama's /api/embeddings endpoint. | TRUE |

---

## Features Requested in Task but Not Found

| Feature | Status | Notes |
|---------|--------|-------|
| PREFLIGHT_CHECK UDF | NOT IMPLEMENTED | Referenced in ux_logs/top5_fixes.md as a proposed feature. The README documents TEST_OLLAMA, TEST_QDRANT, TEST_EMBED, and TEST_QDRANT_SEARCH in test_connectivity.sql -- these serve a similar purpose but are separate scripts, not a unified preflight check. |
| EMBED_AND_PUSH_V2 | NOT IMPLEMENTED | No reference anywhere in the codebase. Only EMBED_AND_PUSH exists. |
| Collection filtering | NOT IMPLEMENTED | The virtual schema exposes ALL Qdrant collections. There is no mechanism to filter which collections appear as tables. This was identified as a gap in the consolidated_report.md (issue #4). |

---

## Documentation Gaps Found

### Gap 1: Collection name case transformation is undocumented

Qdrant collection `knowledge_base` becomes virtual table `KNOWLEDGE_BASE`. The Lua adapter uppercases collection names for Exasol metadata and lowercases table names when querying Qdrant. This bidirectional transformation is never mentioned in the README or docs.

**Impact:** Low. Works transparently. But a user searching for why their lowercase collection name appears uppercase would find no explanation.

### Gap 2: Empty query behavior is undocumented

When a user queries without `WHERE "QUERY" = '...'`, the adapter returns a helpful error row:
```
ID=NO_QUERY, TEXT="Semantic search requires: WHERE \"QUERY\" = 'your search text'...", SCORE=0
```

This is excellent UX (improved from the original crash documented in iteration 2/5), but the README doesn't mention this behavior. Users should know what to expect.

### Gap 3: Virtual schema ghost state after ALTER SET failure

When `ALTER VIRTUAL SCHEMA ... SET` triggers a metadata re-read that fails (e.g., wrong Ollama URL), the virtual schema can enter a corrupted state where:
- It appears in `SYS.EXA_ALL_VIRTUAL_SCHEMAS`
- But `ALTER VIRTUAL SCHEMA ... REFRESH` returns "schema not found"
- And `DROP VIRTUAL SCHEMA ... CASCADE` claims success but leaves residual metadata

The only recovery is `DROP SCHEMA IF EXISTS <name> CASCADE` (dropping as regular schema) followed by recreation. This is not documented anywhere.

### Gap 4: MCP server / programmatic deployment not addressed

The README assumes deployment through a SQL GUI client. The `/` statement terminators in install_all.sql are a SQL client convention, not standard SQL. Users deploying via programmatic interfaces (JDBC, Python exasol driver, MCP) need to split the file into individual statements and remove the `/` terminators. This is not mentioned.

### Gap 5: test_connectivity.sql is not referenced in the Quick Start

The README's Quick Start jumps from "install everything" to "query." There's no mention of running preflight connectivity checks first. The test_connectivity.sql file is only shown in the Project Structure tree. A "Step 2.5: Verify connectivity" would save users significant debugging time.

### Gap 6: No guidance on what to do when search returns zero results

The README says "Zero search results: Query text not semantically matching content" in the troubleshooting table (docs/udf-ingestion.md). But the zero-results case returns an empty result set (via `WHERE FALSE`), which may confuse users into thinking the adapter is broken rather than the query being too different from the corpus.

### Gap 7: CREATE_QDRANT_COLLECTION said "created" but reality was ambiguous

During testing, the CREATE_QDRANT_COLLECTION UDF reported "created: iter7_test_collection" but immediate verification from the host showed the collection didn't exist. This turned out to be a Qdrant propagation timing issue (the collection did exist moments later). The UDF could verify creation success before returning.

---

## Positive Documentation Findings

1. **Hero example works exactly as shown.** Copy-paste `SELECT "ID", "TEXT", "SCORE" FROM vector_schema.articles WHERE "QUERY" = 'artificial intelligence' LIMIT 5;` works (after substituting the actual collection name).

2. **install_all.sql is genuinely one-file deployment.** The structured sections (STEP 1-6) with clear comments make it easy to follow. The CONFIGURATION section at the top is immediately visible.

3. **Docker networking is well-explained.** The distinction between gateway IP (for Qdrant via port mapping) and container IP (for Ollama in UDFs) is clearly documented with the `docker inspect` commands to find them.

4. **Error messages are dramatically improved.** Empty query returns a helpful message with an example query. Adapter errors are caught and returned as data rows rather than crashing. This is a significant improvement over the 4.9/10 average from the original 10-iteration study.

5. **The troubleshooting table in docs/udf-ingestion.md is comprehensive.** Covers 8 common error scenarios with cause and fix.

6. **The Limitations page is honest and actionable.** Each limitation includes what breaks, why, and workarounds.

7. **USAGE EXAMPLES at the bottom of install_all.sql** provide immediate next steps after installation.

---

## Recommendations for Documentation Improvements

| Priority | Recommendation |
|----------|---------------|
| HIGH | Add "Step 2.5: Verify connectivity" to Quick Start, referencing test_connectivity.sql |
| HIGH | Document the virtual schema ghost state issue and its recovery procedure |
| MEDIUM | Document collection name case transformation (lowercase in Qdrant, uppercase in Exasol) |
| MEDIUM | Document empty-query behavior in the Querying section |
| MEDIUM | Add a note about programmatic deployment (strip `/` terminators, execute statements individually) |
| LOW | Add a "Verify" step after CREATE_QDRANT_COLLECTION showing how to confirm the collection exists |
| LOW | Clarify "deployed as a single SQL statement" to "deployed from a single SQL file" |

---

## Test Execution Summary

| Test | Description | Result |
|------|-------------|--------|
| MCP connectivity | SELECT 1 | PASS |
| Schema creation | CREATE SCHEMA IF NOT EXISTS ADAPTER | PASS |
| Connection creation | CREATE OR REPLACE CONNECTION qdrant_conn | PASS |
| Lua adapter deploy | CREATE OR REPLACE LUA ADAPTER SCRIPT | PASS (after removing `/` terminator) |
| Python UDF deploy (CREATE_QDRANT_COLLECTION) | CREATE OR REPLACE PYTHON3 SCALAR SCRIPT | PASS |
| Python UDF deploy (EMBED_AND_PUSH) | CREATE OR REPLACE PYTHON3 SET SCRIPT | PASS |
| Virtual schema creation | CREATE VIRTUAL SCHEMA | PASS (after clearing ghost state) |
| Virtual schema refresh | ALTER VIRTUAL SCHEMA REFRESH | PASS (intermittent session issues) |
| Preflight: TEST_OLLAMA | SELECT ADAPTER.TEST_OLLAMA() | PASS -- HTTP 200 |
| Preflight: TEST_QDRANT | SELECT ADAPTER.TEST_QDRANT() | PASS -- HTTP 200 |
| Preflight: TEST_EMBED | SELECT ADAPTER.TEST_EMBED('hello world') | PASS -- 768-dim embedding |
| CREATE_QDRANT_COLLECTION | Create new collection | PASS -- "created: iter7_test_collection" |
| CREATE_QDRANT_COLLECTION idempotent | Re-create existing collection | PASS -- "exists: iter7_test_collection" |
| CREATE_QDRANT_COLLECTION auto-detect | NULL vector_size with model name | PASS -- inferred 768 for nomic-embed-text |
| EMBED_AND_PUSH | Ingest 5 docs from Exasol table | PASS -- upserted_count=5 |
| Semantic search | WHERE "QUERY" = 'artificial intelligence' LIMIT 5 | PASS -- 5 ranked results |
| Default limit | Query without LIMIT | PASS -- returns exactly 10 rows |
| Empty query handling | Query without WHERE "QUERY" = | PASS -- returns helpful NO_QUERY error row |
| Score range | Check SCORE values | PASS -- all between 0 and 1 |
| Column schema | Verify 4-column layout | PASS -- ID, TEXT, SCORE, QUERY |
| Subquery/ORDER BY | Nested SELECT with ORDER BY SCORE DESC | PASS |
| ALTER SET properties | Change OLLAMA_URL | FAIL -- caused ghost state corruption |
| PREFLIGHT_CHECK UDF | Test unified preflight check | N/A -- not implemented |
| EMBED_AND_PUSH_V2 | Test v2 ingestion UDF | N/A -- not implemented |

---

## Comparison to Prior Iterations

| Metric | Iterations 1-10 Average (2026-04-03) | Iteration 07 (2026-04-05) | Delta |
|--------|---------------------------------------|---------------------------|-------|
| UX Score | 4.9/10 | 7.4/10 | +2.5 |
| Empty query handling | Crash with cryptic error | Helpful NO_QUERY message with example | Fixed |
| Deployment method | 3,527-line Lua paste | Single SQL file (install_all.sql) | Fixed |
| Documentation | Scattered across files, no sequential guide | Comprehensive README with step-by-step Quick Start | Improved |
| Error handling | Cryptic column-count mismatches | Errors returned as data rows with messages | Improved |
| Preflight checks | None | test_connectivity.sql with 4 test functions | New |
| Ghost state issue | Not identified | Identified but undocumented | Ongoing |

The project has improved significantly from the original 4.9/10. The main remaining issues are: (1) virtual schema ghost state corruption, (2) missing unified preflight check UDF, and (3) several documentation gaps that would help first-time users avoid common pitfalls.
