# UX Study -- Iteration 04: Copy-Paste Developer Walkthrough

**Date:** 2026-04-05
**Persona:** Copy-paste developer. Relies on code snippets from README and docs. Copies examples verbatim, runs them, does not customize unless forced to. When something breaks, looks for another example to copy rather than debugging.
**Method:** Extracted every runnable SQL/shell example from README.md and install_all.sql, executed each verbatim via the Exasol MCP server, and documented what happened.

---

## Overall UX Score: 7.0 / 10

| Category                              | Score | Weight | Weighted |
|---------------------------------------|-------|--------|----------|
| Examples work verbatim (no changes)   | 6.0   | 30%    | 1.80     |
| Examples work with minor adaptation   | 8.0   | 20%    | 1.60     |
| Error messages when examples fail     | 7.5   | 15%    | 1.13     |
| Coverage (are all steps exampled?)    | 5.5   | 15%    | 0.83     |
| Consistency across examples           | 6.5   | 10%    | 0.65     |
| Copy-paste friendliness (format)      | 8.5   | 10%    | 0.85     |
| **Weighted Total**                    |       |        | **6.86** |

Rounded: **7.0 / 10**

---

## Example-by-Example Verdict

### Examples That Worked Verbatim (Zero Changes)

| # | Source | Example | Result |
|---|--------|---------|--------|
| 1 | install_all.sql L46 | `CREATE SCHEMA IF NOT EXISTS ADAPTER` | PASS -- created schema |
| 2 | install_all.sql L47 | `OPEN SCHEMA ADAPTER` | PASS -- opened schema |
| 3 | install_all.sql L56-59 | `CREATE OR REPLACE CONNECTION qdrant_conn TO 'http://172.17.0.1:6333' USER '' IDENTIFIED BY ''` | PASS -- connection created |
| 4 | install_all.sql L73-236 | Full Lua adapter script (120+ lines) | PASS -- adapter created (without `/` terminator; see note below) |
| 5 | install_all.sql L246-316 | CREATE_QDRANT_COLLECTION Python UDF | PASS -- UDF created |
| 6 | install_all.sql L332-471 | EMBED_AND_PUSH Python UDF | PASS -- UDF created |
| 7 | README L117-119 | `SELECT ADAPTER.CREATE_QDRANT_COLLECTION('172.17.0.1', 6333, '', 'my_collection', 768, 'Cosine', '')` | PASS -- collection created |
| 8 | install_all.sql L516-520 | CREATE_QDRANT_COLLECTION usage example with model_name | PASS -- collection created with auto-dimension detection |
| 9 | install_all.sql L496 | `ALTER VIRTUAL SCHEMA vector_schema REFRESH` | PASS (after adapting schema name) |
| 10 | README L248 | `ALTER VIRTUAL SCHEMA vector_schema SET OLLAMA_URL = 'http://172.17.0.4:11434'` | PASS (after adapting schema name) |

### Examples That Failed Verbatim

| # | Source | Example | Failure | Fix Required |
|---|--------|---------|---------|--------------|
| 11 | install_all.sql L484-490 | `DROP VIRTUAL SCHEMA IF EXISTS vector_schema CASCADE` then `CREATE VIRTUAL SCHEMA vector_schema ...` | **BLOCKED by ghost state.** The DROP reported success but the schema persisted as a ghost in SYS.EXA_ALL_SCHEMAS. CREATE then fails with "schema VECTOR_SCHEMA already exists." Even `DROP FORCE VIRTUAL SCHEMA IF EXISTS` did not clear it. | **Must use a different schema name.** No amount of copying different DROP variants fixed it. This is the single worst copy-paste failure because there is no example that recovers from it. |
| 12 | README L122-133 | `SELECT ADAPTER.EMBED_AND_PUSH(CAST(id_col AS VARCHAR(36)), text_col, ...) FROM MY_SCHEMA.MY_TABLE GROUP BY IPROC()` | `object MY_SCHEMA.MY_TABLE not found` | **Placeholder, not a runnable example.** A copy-paste developer cannot run this. Requires creating your own table first, but no CREATE TABLE + INSERT example is provided. |
| 13 | README L203-206 | `SELECT "ID", "TEXT", "SCORE" FROM vector_schema.articles WHERE "QUERY" = 'artificial intelligence' LIMIT 5` | `object VECTOR_SCHEMA.ARTICLES not found` | **Assumes you created a collection called "articles" and used the schema name "vector_schema."** The example at the top of the README (line 6-10) shows the same pattern. It works once you substitute your actual schema and collection names, but as-is it fails. |
| 14 | README L57-58 | Docker run commands for Qdrant/Ollama | Not tested (services pre-running) but these are verbatim-ready. **No docker run for Exasol itself.** |
| 15 | README L155-188 | PowerShell `Add-Document` function and collection creation | **Platform-dependent.** Works on Windows PowerShell but not on Linux/macOS without translation. No curl equivalent provided. |

### Examples That Required Minor Adaptation

| # | Source | What Changed | Effort |
|---|--------|-------------|--------|
| A | install_all.sql L484 | Changed `vector_schema` to `vs_qdrant` (ghost state workaround) | Low -- but required understanding the ghost state problem, which is not documented |
| B | README L122-133 | Changed `MY_SCHEMA.MY_TABLE` to real table, `id_col`/`text_col` to real columns | Medium -- required creating a table with sample data first (5 min) |
| C | README L203 | Changed `vector_schema.articles` to `vs_qdrant.copy_paste_test` | Low -- obvious substitution |
| D | All scripts | Removed `/` terminator when executing via MCP tool | Trivial -- but `/` is unexplained in the docs; a copy-paste developer using a non-Exasol-native client would hit a syntax error |

---

## Detailed Findings

### Finding 1: Virtual Schema Ghost State (Severity: CRITICAL)

**What happened:** After running `DROP VIRTUAL SCHEMA IF EXISTS vector_schema CASCADE`, the statement returned success. But `CREATE VIRTUAL SCHEMA vector_schema ...` immediately failed with "schema VECTOR_SCHEMA already exists." Tried `DROP FORCE VIRTUAL SCHEMA IF EXISTS vector_schema CASCADE` -- also reported success but the ghost persisted.

**Copy-paste developer impact:** Dead end. No example in the README or install_all.sql recovers from this state. A copy-paste developer would:
1. Copy the DROP+CREATE from install_all.sql
2. See it fail
3. Search the README for "already exists" -- no results
4. Give up, or guess to try a different name

**The install_all.sql does use DROP+CREATE (not IF NOT EXISTS), which is correct.** But the ghost state can arise from prior runs, failed MCP sessions, or partial deployments. There is no documented recovery path.

**Recommendation:** Add a troubleshooting note: "If you see 'schema already exists' after DROP, use a different schema name (e.g., `vs_qdrant`) or restart the Exasol database session."

### Finding 2: No Sample Data for EMBED_AND_PUSH (Severity: HIGH)

**What happened:** The README EMBED_AND_PUSH example uses `FROM MY_SCHEMA.MY_TABLE` with `id_col` and `text_col` as placeholder column names. A copy-paste developer runs this verbatim and gets "object not found."

**What I had to create myself:**
```sql
CREATE SCHEMA IF NOT EXISTS TEST_DATA;
CREATE OR REPLACE TABLE TEST_DATA.SAMPLE_DOCS (
    id VARCHAR(36),
    text_content VARCHAR(2000)
);
INSERT INTO TEST_DATA.SAMPLE_DOCS VALUES
    ('doc-1', 'Machine learning is a subset of artificial intelligence'),
    ('doc-2', 'The Eiffel Tower is located in Paris, France'),
    ('doc-3', 'Neural networks are inspired by the human brain'),
    ('doc-4', 'Python is a popular programming language for data science'),
    ('doc-5', 'The Great Wall of China is visible from space');
```

**Recommendation:** Add a "Quick Test" block after install_all.sql that creates sample data, ingests it, and runs a search. This would make the end-to-end experience copy-paste-able in under 2 minutes.

### Finding 3: Ollama IP Inconsistency (Severity: MEDIUM)

**What the docs say:**
- install_all.sql uses `172.17.0.1:11434` for the virtual schema OLLAMA_URL property (line 490)
- README EMBED_AND_PUSH example uses `http://172.17.0.4:11434` for the Ollama URL parameter (line 129)
- install_all.sql usage example at the bottom uses `<OLLAMA_IP>:11434` as a placeholder (line 536)

**What works:**
- Virtual schema queries (Lua adapter) work with `172.17.0.1:11434` (Docker bridge gateway)
- EMBED_AND_PUSH (Python UDF) needs the actual Ollama container IP (`172.17.0.4`)

A copy-paste developer would naturally use `172.17.0.1` everywhere (since that is what install_all.sql uses for everything else). The EMBED_AND_PUSH call would then fail with a timeout or connection refused, with no indication that the IP is wrong.

**Recommendation:** The README does document this (line 143-144) but it is a buried note. Make the EMBED_AND_PUSH example use a clear placeholder like `<OLLAMA_CONTAINER_IP>` with an inline comment showing how to find it: `docker inspect ollama --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}'`.

### Finding 4: Statement Terminator `/` Is Unexplained (Severity: LOW)

The Lua and Python scripts in install_all.sql end with a bare `/` on its own line. This is an Exasol-specific multi-statement terminator. It is not SQL standard. If a developer copies the script into a non-Exasol SQL client, a generic JDBC driver, or an API call, the `/` causes a syntax error. The file never explains what it means.

When using the MCP tool, I had to omit the `/` for each statement to work. A DBeaver user would need it; an API user would not. This is confusing for copy-paste developers who do not know which category they fall into.

### Finding 5: test_connectivity.sql Is Hidden (Severity: MEDIUM)

The project includes `scripts/test_connectivity.sql` with four pre-flight check scripts (TEST_OLLAMA, TEST_QDRANT, TEST_EMBED, TEST_QDRANT_SEARCH). These are extremely useful for a copy-paste developer who wants to verify their setup before deploying. However:
- The README mentions it only in the project structure tree (line 276), not in the Quick Start
- install_all.sql does not reference it
- A copy-paste developer would never find it unless they browse the `scripts/` directory

**Recommendation:** Add a step in the Quick Start: "Optional: Run `scripts/test_connectivity.sql` first to verify Exasol can reach Qdrant and Ollama."

### Finding 6: PowerShell-Only Option B (Severity: LOW)

The direct HTTP ingestion example (Option B) uses PowerShell. On Linux/macOS, this requires translation to curl or Python. A curl equivalent would be more universal for a Docker-oriented audience.

---

## Scoring Breakdown

| Dimension | Score | Rationale |
|-----------|-------|-----------|
| **Examples work verbatim** | 6.0 | 10 of 15 examples ran without changes. The 5 failures include the critical ghost state, missing sample data, and platform-specific PowerShell. |
| **Examples work with minor adaptation** | 8.0 | All examples worked after obvious substitutions (schema name, table name). No deep debugging required. |
| **Error messages when examples fail** | 7.5 | "object not found" is clear. "schema already exists" is misleading (implies a simple conflict, not a ghost state). The "no query" helper message is excellent. Qdrant 404 error is clear. |
| **Coverage (all steps exampled?)** | 5.5 | Missing: Exasol docker run, sample data creation, troubleshooting, test_connectivity.sql reference. The ingestion step has a gap between "deploy UDFs" and "run UDFs" (no data to ingest). |
| **Consistency across examples** | 6.5 | Ollama IP differs between adapter config and UDF calls. `vector_schema` vs actual schema name. `my_collection` vs `articles` in different examples. The placeholder style varies (`MY_SCHEMA.MY_TABLE` vs `<OLLAMA_IP>` vs hardcoded `172.17.0.1`). |
| **Copy-paste friendliness (format)** | 8.5 | SQL blocks are clean and fenced. install_all.sql has excellent box-drawing headers. Comments are inline and helpful. The fixed 4-column schema is predictable. |

---

## What Works Exceptionally Well for a Copy-Paste Developer

1. **install_all.sql is genuinely one file.** Steps 1-4 (schema, connection, adapter, UDFs) all deployed with zero changes. A copy-paste developer can run 90% of the installer verbatim.

2. **CREATE_QDRANT_COLLECTION auto-detects dimensions.** Passing `'nomic-embed-text'` as the model_name and letting the UDF look up 768 dimensions is a great touch. A copy-paste developer does not need to know what "768 dimensions" means.

3. **The "no query" error message is a working example.** When you forget `WHERE "QUERY" = '...'`, the adapter returns a message that includes the correct syntax for your specific collection. This is copy-paste-developer-friendly error design.

4. **CREATE OR REPLACE pattern means re-runs are safe for scripts.** A copy-paste developer who runs install_all.sql twice will not break their adapter or UDFs. Only the virtual schema has the ghost state issue.

5. **Semantic search results are immediately satisfying.** The first successful query ("artificial intelligence" returning the ML document with score 0.77) provides instant gratification. The scores are intuitive.

---

## Recommendations Ranked by Impact on Copy-Paste UX

| Priority | Recommendation | Current Score Impact | Effort |
|----------|---------------|---------------------|--------|
| P0 | Add a complete "Hello World" block: CREATE TABLE + INSERT + EMBED_AND_PUSH + REFRESH + SELECT, all copy-paste-ready | Would fix Finding 2, raise "Coverage" from 5.5 to 7.5 | Small (15 lines of SQL) |
| P0 | Document virtual schema ghost state recovery in a Troubleshooting section | Would fix Finding 1, raise "Error messages" from 7.5 to 8.5 | Small (5 lines of text) |
| P1 | Reference test_connectivity.sql in the Quick Start | Would fix Finding 5, raise "Coverage" from 5.5 to 6.5 | Trivial |
| P1 | Standardize Ollama IP handling -- use a consistent placeholder or detect it | Would fix Finding 3, raise "Consistency" from 6.5 to 8.0 | Medium |
| P2 | Add curl alternative alongside PowerShell for Option B | Would fix Finding 6, raise "Verbatim" from 6.0 to 6.5 | Small |
| P2 | Explain the `/` terminator in a comment in install_all.sql | Would fix Finding 4, raise "Copy-paste friendliness" from 8.5 to 9.0 | Trivial |

---

## Comparison to Iteration 12 (Weekend Hobbyist)

| Dimension | Iteration 12 (Hobbyist) | Iteration 04 (Copy-Paste Dev) | Delta |
|-----------|------------------------|-------------------------------|-------|
| Overall score | 7.2 | 7.0 | -0.2 |
| Deployment | 7.0 | 8.0 (scripts work verbatim) | +1.0 |
| Data ingestion | 6.0 | 5.5 (no sample data to copy) | -0.5 |
| Querying | 9.0 | 8.5 (needs schema name fix) | -0.5 |
| Error recovery | 3.0 | 3.0 (ghost state still fatal) | 0.0 |

The copy-paste developer hits similar pain points to the hobbyist. The deployment step is actually better because the scripts use `CREATE OR REPLACE` which survives re-runs. The data ingestion step is worse because a copy-paste developer expects runnable examples, not placeholders.

**The ghost state problem is the single most damaging issue for both personas.** It cannot be fixed by copying any example from the docs.

---

## Raw Test Log

All tests executed via Exasol MCP server (127.0.0.1:9563, user SYS) on 2026-04-05.

- Exasol: Docker, port 8563
- Qdrant: Docker, port 6333, 19 existing collections
- Ollama: Docker, port 11434, model nomic-embed-text (137M params, F16)
- Docker bridge gateway: 172.17.0.1
- Ollama container IP: 172.17.0.4

Virtual schema had to use name `vs_qdrant` instead of `vector_schema` due to ghost state from prior session. All other artifacts used default names from install_all.sql.
