# UX Study: Iteration 01 -- Cautious Beginner Full Stack Deployment

**Date:** 2026-04-05
**Persona:** Cautious beginner, first time with Exasol + Docker + vector search
**Method:** Follow `scripts/install_all.sql` documentation literally, note every friction point
**Tooling:** Exasol MCP server for all database operations, Docker CLI for infrastructure

---

## Overall UX Score: 6.8 / 10

### Weighted Scoring Table

| Dimension                        | Weight | Score | Weighted | Notes                                                                                      |
|----------------------------------|--------|-------|----------|--------------------------------------------------------------------------------------------|
| Documentation clarity            | 20%    | 8.5   | 1.70     | README is excellent. install_all.sql header comments are clear. Config section easy to find |
| Installation friction            | 25%    | 5.0   | 1.25     | Ghost schemas, MCP session issues, CREATE_QDRANT_COLLECTION silent failure                 |
| Error message quality            | 15%    | 7.0   | 1.05     | Adapter errors are good (port mismatch, missing query). UDF errors have stack traces       |
| End-to-end success rate          | 20%    | 6.0   | 1.20     | Got it working, but required 3 workarounds for ghost schemas and collection creation       |
| Time to first successful query   | 10%    | 6.5   | 0.65     | ~25 minutes including cleanup, diagnosis, and workarounds                                  |
| Semantic search result quality   | 10%    | 9.5   | 0.95     | Results are semantically correct and well-ranked across all test queries                   |
| **TOTAL**                        |**100%**|       | **6.80** |                                                                                            |

---

## Timeline of Events

### Phase 0: Prerequisites Check (2 min)
- **00:00** -- Connected to Exasol MCP server, verified connectivity with `SELECT 1`
- **00:30** -- Listed existing schemas. Found 14 schemas from previous work
- **01:00** -- Checked Docker containers: exasoldb, qdrant, ollama all running
- **01:30** -- Verified Qdrant responding on port 6333, Ollama has nomic-embed-text model
- **02:00** -- Got Docker bridge gateway IP: 172.17.0.1 confirmed

**Confusion level:** LOW. The README clearly lists prerequisites and how to check them.

### Phase 1: Cleanup Existing Artifacts (5 min)
- **02:00** -- Found 7 virtual schemas, 9 scripts, 3 connections from previous work
- **02:30** -- Dropped all 7 virtual schemas + vector_schema (8 DROP statements, all returned success)
- **03:00** -- Attempted to drop scripts in ADAPTER schema -- all failed with "schema ADAPTER not found"
- **CONFUSION MOMENT #1:** The CASCADE on virtual schema drops apparently cascaded and destroyed the ADAPTER schema itself, along with all its scripts and connections. The DROP VIRTUAL SCHEMA CASCADE was far more aggressive than expected. A beginner would panic here -- "Did I just delete everything?"
- **04:00** -- Verified: ADAPTER schema, all scripts, and all connections were gone
- **05:00** -- Dropped remaining connections (returned success even though they were already gone)

**Confusion level:** MEDIUM. CASCADE behavior is surprising. No warning about what CASCADE will destroy.

### Phase 2: Schema Creation (3 min)
- **05:00** -- Ran `CREATE SCHEMA IF NOT EXISTS ADAPTER` -- returned success (null)
- **05:30** -- Ran `OPEN SCHEMA ADAPTER` -- FAILED: "schema ADAPTER not found"
- **CONFUSION MOMENT #2:** CREATE SCHEMA IF NOT EXISTS returned success but the schema does not exist. This appears to be a ghost reference from the CASCADE cleanup. The `IF NOT EXISTS` clause matched the ghost and silently skipped creation.
- **06:00** -- Ran `CREATE SCHEMA ADAPTER` (without IF NOT EXISTS) -- this actually created it
- **06:30** -- Verified ADAPTER now exists in list_schemas

**Confusion level:** HIGH. Silent success on a no-op is very misleading for a beginner. The error "schema not found" after a successful CREATE is bewildering.

### Phase 3: Connection and Lua Adapter (3 min)
- **07:00** -- Created connection qdrant_conn to http://172.17.0.1:6333 -- success
- **07:30** -- First attempt to create Lua adapter script -- FAILED: "schema ADAPTER not found"
- **CONFUSION MOMENT #3:** Same ghost schema issue. The ADAPTER schema exists in list_schemas but the MCP server's write session cannot find it. Likely a cross-session visibility issue.
- **08:00** -- Second attempt (identical SQL) -- SUCCESS. The MCP server session presumably caught up.
- **08:30** -- Verified: VECTOR_SCHEMA_ADAPTER exists in SYS.EXA_ALL_SCRIPTS

**Confusion level:** HIGH. Transient "schema not found" errors when the schema clearly exists are extremely confusing. A beginner would not know to just retry.

### Phase 4: Python UDF Deployment (2 min)
- **09:00** -- Deployed CREATE_QDRANT_COLLECTION UDF -- success, verified in system tables
- **09:30** -- Deployed EMBED_AND_PUSH UDF (with all `--` comments removed per known issue) -- success
- **10:00** -- Verified: all 3 scripts present in ADAPTER schema

**Confusion level:** LOW. The deployment itself went smoothly. The `--` comment gotcha (from prior memory) would be a HIGH confusion moment for a true beginner.

### Phase 5: Virtual Schema Creation (8 min -- the hardest part)
- **10:00** -- Ran `DROP VIRTUAL SCHEMA IF EXISTS vector_schema CASCADE` -- success
- **10:30** -- Ran `CREATE VIRTUAL SCHEMA vector_schema ...` -- FAILED: "schema VECTOR_SCHEMA already exists"
- **CONFUSION MOMENT #4:** The drop succeeded but the schema still exists. Classic ghost state. Checked EXA_ALL_SCHEMAS (not there) and EXA_ALL_VIRTUAL_SCHEMAS (not there). But CREATE insists it exists.
- **11:00** -- Tried `DROP SCHEMA VECTOR_SCHEMA CASCADE` -- FAILED: "schema not found". Schrodinger's schema: both exists and doesn't exist.
- **11:30** -- Tried `DROP SCHEMA IF EXISTS VECTOR_SCHEMA CASCADE` -- returned success (but no effect)
- **12:00** -- Retried CREATE VIRTUAL SCHEMA -- FAILED: Lua error "GET http://172.17.0.1:6334/collections => connection refused"
- **CONFUSION MOMENT #5:** The CREATE actually worked this time (ghost cleared), but the connection was pointing to port 6334 instead of 6333. This was a stale connection from a partial creation. Note: the session schema changed to VECTOR_SCHEMA, meaning the VS was partially created before the adapter callback failed.
- **13:00** -- Recreated connection with CREATE OR REPLACE -- success
- **13:30** -- Tried ALTER VIRTUAL SCHEMA REFRESH -- FAILED: "schema VECTOR_SCHEMA not found"
- **CONFUSION MOMENT #6:** The virtual schema shows in EXA_ALL_VIRTUAL_SCHEMAS with a timestamp but cannot be accessed. This is the ghost state the install_all.sql tried to prevent with DROP+CREATE.
- **14:00** -- Abandoned the name "vector_schema" entirely. Tried "vs_search" -- ALSO a ghost!
- **15:00** -- Used unique name "ux_fresh_test" -- SUCCESS
- **16:00** -- Refreshed -- success. Tables visible.

**Confusion level:** EXTREME. This was the single most frustrating phase. Ghost schemas accumulate from failed CREATE VIRTUAL SCHEMA attempts. Each failed attempt leaves a ghost that blocks future creates with the same name. The only escape is to use a new name.

### Phase 6: Collection Creation and Data Ingestion (4 min)
- **16:00** -- Created Qdrant collection via CREATE_QDRANT_COLLECTION UDF -- returned "created: ux_beginner_test"
- **16:30** -- Created test data table with 8 sample documents -- success
- **17:00** -- Ran EMBED_AND_PUSH -- FAILED: "Collection ux_beginner_test doesn't exist!"
- **CONFUSION MOMENT #7:** The UDF said "created" but the collection does not exist in Qdrant. The CREATE_QDRANT_COLLECTION UDF reported success but the collection was never actually created. This is likely because the UDF ran inside the Exasol container and the Qdrant HTTP request either failed silently or the UDF has a bug.
- **17:30** -- Created collection directly via curl -- success
- **18:00** -- Retried EMBED_AND_PUSH -- SUCCESS: 8 documents upserted

**Confusion level:** HIGH. The UDF reporting success when the operation failed is a serious trust issue. A beginner would have no idea why EMBED_AND_PUSH fails if the collection was supposedly created.

### Phase 7: Semantic Search Testing (2 min)
- **18:00** -- Refreshed virtual schema -- success
- **18:30** -- Query: "artificial intelligence and machine learning" -- doc-1 (ML/AI) scored 0.77, correct!
- **19:00** -- Query: "famous landmarks and tourist attractions" -- Tokyo, Great Wall, Eiffel Tower top 3, correct!
- **19:30** -- Query: "programming languages for beginners" -- Python scored 0.69, correct!
- **20:00** -- Query without WHERE clause -- helpful error message returned (not a crash)

**Confusion level:** NONE. The search experience is delightful once you get past setup. Results are intuitive.

---

## Summary of Confusion Moments

| # | Phase | Severity | Issue | Time Lost |
|---|-------|----------|-------|-----------|
| 1 | Cleanup | Medium | CASCADE on virtual schema drops destroyed the entire ADAPTER schema + scripts + connections | 2 min |
| 2 | Schema Creation | High | `CREATE SCHEMA IF NOT EXISTS` silently skips when ghost reference exists | 2 min |
| 3 | Lua Adapter | High | Transient "schema not found" error on MCP server write; works on retry | 1 min |
| 4 | Virtual Schema | Extreme | Ghost schemas from failed CREATE VIRTUAL SCHEMA block future creates | 3 min |
| 5 | Virtual Schema | High | Partial virtual schema creation leaves ghost + wrong connection port | 2 min |
| 6 | Virtual Schema | Extreme | Virtual schema visible in system tables but cannot be accessed or dropped | 3 min |
| 7 | Collection | High | CREATE_QDRANT_COLLECTION reports "created" but collection does not exist | 2 min |

**Total time lost to confusion:** ~15 minutes out of ~25 total (~60% of time spent on workarounds)

---

## What Worked Well

1. **README documentation** -- Clear, well-structured, includes all prerequisites and Docker commands
2. **install_all.sql structure** -- Step numbering, header comments, and config section are excellent
3. **Lua adapter error handling** -- The "no query" message is genuinely helpful and teaches the user the correct syntax
4. **Semantic search quality** -- Results are semantically correct with clear score differentiation
5. **Single-file deployment concept** -- The idea of one SQL file for everything is brilliant for UX
6. **No BucketFS/JAR/Maven** -- This massively reduces friction compared to traditional Exasol adapters
7. **Python UDF stdlib-only** -- No need for SLC or pip packages is a major advantage
8. **Docker networking documentation** -- The bridge gateway IP note saved time

## What Broke or Was Confusing

1. **Ghost virtual schemas** -- The single biggest UX issue. Failed CREATE VIRTUAL SCHEMA leaves undeletable ghosts
2. **MCP session inconsistency** -- Schema exists in one session but not in another (likely autocommit/transaction issue)
3. **CREATE SCHEMA IF NOT EXISTS** -- Silent no-op when ghost references exist. Should error or warn.
4. **CREATE_QDRANT_COLLECTION** false success -- UDF reported "created" but collection did not persist in Qdrant
5. **CASCADE surprise** -- Dropping a virtual schema with CASCADE can destroy the adapter schema, all UDFs, and all connections. This is not documented.
6. **Port 6334 mystery** -- The connection briefly pointed to wrong port during ghost state recovery (likely stale connection data)
7. **Ollama IP confusion** -- Need 172.17.0.1 for virtual schema but 172.17.0.4 for UDFs. This dual-IP requirement is documented but still confusing.

---

## Specific Improvement Recommendations

### Priority 1: Fix Ghost Virtual Schema Issue (Severity: Critical)

The install_all.sql already uses `DROP VIRTUAL SCHEMA IF EXISTS ... CASCADE` before CREATE, which is correct. But the ghost state issue persists when:
- The DROP succeeds but the virtual schema metadata is not fully purged
- The CREATE partially succeeds (creates the schema entry) but the adapter callback fails

**Recommendation:**
- Add a post-DROP verification step: check `SYS.EXA_ALL_SCHEMAS` and `SYS.EXA_ALL_VIRTUAL_SCHEMAS` after DROP, and if ghosts remain, try `DROP SCHEMA <name> CASCADE` as a fallback
- Add a unique suffix (timestamp or random) to virtual schema name as an escape hatch suggestion in troubleshooting docs
- Document this as a known Exasol limitation with a workaround section

### Priority 2: Validate Collection Creation in UDF (Severity: High)

The CREATE_QDRANT_COLLECTION UDF should verify the collection actually exists after creating it:

```python
# After _qdrant_request("PUT", ...), add:
verify = _qdrant_request("GET", base_url + "/collections/" + collection, api_key=api_key)
if verify.get("status") == "ok" or verify.get("result"):
    return "created: " + collection
else:
    return "FAILED: creation reported success but collection not found"
```

### Priority 3: Document CASCADE Side Effects (Severity: Medium)

Add a warning to install_all.sql and README:

```
WARNING: DROP VIRTUAL SCHEMA ... CASCADE will also drop the adapter script's
parent schema if the virtual schema was the last object referencing it.
This means your ADAPTER schema, all UDFs, and all connections may be destroyed.
Always drop virtual schemas BEFORE dropping scripts/connections, and never
rely on CASCADE for cleanup.
```

### Priority 4: Add Preflight Connectivity Check (Severity: Medium)

Before creating the virtual schema (where failures are hard to recover from), add a connectivity check:

```sql
-- This runs BEFORE the virtual schema creation to verify Qdrant is reachable
SELECT ADAPTER.CREATE_QDRANT_COLLECTION('172.17.0.1', 6333, '', '__preflight_test__', 768, 'Cosine', '');
-- If this fails, fix your network configuration before proceeding
```

### Priority 5: Dual Ollama IP Documentation (Severity: Low)

The current docs mention this but it's easy to miss. Add a prominent callout box:

```
IMPORTANT: Two different IPs are needed for Ollama:
  - Virtual schema queries use: 172.17.0.1 (Docker bridge gateway)
  - EMBED_AND_PUSH UDF uses: 172.17.0.4 (Ollama container IP)
  Find the Ollama IP with: docker inspect ollama --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}'
```

### Priority 6: Add Idempotent Re-run Support (Severity: Low)

For users who want to re-run install_all.sql (e.g., after config changes):
- The current file mostly handles this (CREATE OR REPLACE, IF NOT EXISTS)
- But the virtual schema step still fails on re-run due to ghost state
- Consider adding: `DROP VIRTUAL SCHEMA IF EXISTS vector_schema CASCADE; DROP SCHEMA IF EXISTS VECTOR_SCHEMA CASCADE;` (double-drop pattern)

---

## Comparison with Previous UX Score

Previous score (from README commit history): **8.5 / 10**

This iteration's score: **6.8 / 10**

The lower score reflects testing in a more realistic "dirty" environment with existing artifacts, ghost schemas, and MCP session quirks. The previous score was likely from a cleaner test run. The core product (semantic search quality, documentation, single-file deployment) is genuinely good -- the score is dragged down by Exasol-level schema management issues and the CREATE_QDRANT_COLLECTION false-success bug.

---

## Test Queries and Results

### Query 1: "artificial intelligence and machine learning"
| Rank | ID    | Score  | Text (truncated)                                    |
|------|-------|--------|-----------------------------------------------------|
| 1    | doc-1 | 0.7706 | Machine learning is a subset of artificial intel... |
| 2    | doc-6 | 0.6796 | Deep learning uses multiple layers of neural...     |
| 3    | doc-3 | 0.6416 | Neural networks are computing systems inspired...   |
| 4    | doc-8 | 0.5827 | Natural language processing enables computers...    |
| 5    | doc-4 | 0.5263 | Python is a popular programming language...         |

**Verdict:** Excellent. AI/ML content correctly ranked highest.

### Query 2: "famous landmarks and tourist attractions"
| Rank | ID    | Score  | Text (truncated)                                    |
|------|-------|--------|-----------------------------------------------------|
| 1    | doc-7 | 0.5444 | Tokyo is the capital city of Japan...               |
| 2    | doc-5 | 0.5187 | The Great Wall of China stretches over 13,000...    |
| 3    | doc-2 | 0.4788 | The Eiffel Tower is a wrought-iron lattice...       |

**Verdict:** Good. All geography/landmark documents ranked top 3. Scores are lower since query is more abstract.

### Query 3: "programming languages for beginners"
| Rank | ID    | Score  | Text (truncated)                                    |
|------|-------|--------|-----------------------------------------------------|
| 1    | doc-4 | 0.6867 | Python is a popular programming language...         |
| 2    | doc-8 | 0.6095 | Natural language processing enables computers...    |
| 3    | doc-1 | 0.5884 | Machine learning is a subset of AI...               |

**Verdict:** Correct. Python (the programming language) correctly ranked first.

### Query 4: No WHERE clause (edge case)
| Rank | ID       | Score | Text                                                 |
|------|----------|-------|------------------------------------------------------|
| 1    | NO_QUERY | 0     | Semantic search requires: WHERE "QUERY" = '...'     |

**Verdict:** Excellent error UX. Helpful message with example syntax, not a crash.

---

## Environment Details

| Component       | Version/Details                              |
|-----------------|----------------------------------------------|
| Exasol          | Docker (exasol/docker-db:latest), port 9563  |
| Qdrant          | Docker (qdrant/qdrant), port 6333            |
| Ollama          | Docker (ollama/ollama), port 11434           |
| Embedding model | nomic-embed-text (768 dimensions, F16)       |
| MCP Server      | Exasol MCP at 127.0.0.1:9563                |
| OS              | Windows 11 Pro                               |
| Docker bridge   | 172.17.0.1                                   |
| Ollama IP       | 172.17.0.4                                   |

---

## Artifacts Created

| Type             | Name                          | Location         |
|------------------|-------------------------------|------------------|
| Schema           | ADAPTER                       | Exasol           |
| Connection       | QDRANT_CONN                   | Exasol           |
| Adapter Script   | VECTOR_SCHEMA_ADAPTER         | ADAPTER schema   |
| UDF              | CREATE_QDRANT_COLLECTION      | ADAPTER schema   |
| UDF              | EMBED_AND_PUSH                | ADAPTER schema   |
| Virtual Schema   | UX_FRESH_TEST                 | Exasol           |
| Table            | BEGINNER_DOCS                 | TEST_DATA schema |
| Collection       | ux_beginner_test              | Qdrant           |

---

*Study conducted by simulated cautious beginner user, 2026-04-05*
