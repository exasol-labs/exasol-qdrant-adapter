# UX Study Consolidated Findings

**Date:** 2026-04-05
**Method:** 15 automated iterations, each simulating a different user persona deploying the Exasol Qdrant semantic search stack from scratch.
**Average UX Score: 6.5/10** (up from 4.9/10 baseline on 2026-04-03)

---

## Scorecard

| # | Persona | Score | Focus Area |
|---|---------|-------|------------|
| 1 | Cautious beginner | 6.8 | First-time setup |
| 2 | Impatient expert | 8.8 | Speed, skip-the-docs |
| 3 | Security DBA | 6.2 | Credentials, audit logs |
| 4 | Copy-paste dev | 7.0 | Example accuracy |
| 5 | Edge case tester | 6.8 | Error handling |
| 6 | Multi-tenant admin | 4.1 | Collection scoping |
| 7 | Docs auditor | 7.4 | Documentation accuracy |
| 8 | Minimalist | 5.8 | Simplicity |
| 9 | Troubleshooter | 7.2 | Error messages, debuggability |
| 10 | Data scientist | 7.8 | Search quality |
| 11 | Migration user | 5.8 | Elasticsearch parity |
| 12 | Weekend hobbyist | 7.2 | Newcomer accessibility |
| 13 | Automation engineer | 7.2 | CI/CD readiness |
| 14 | Performance tester | 4.8 | Latency, throughput |
| 15 | Skeptical evaluator | 5.8 | Enterprise readiness |

---

## Issues Ranked by Impact and Frequency

### P0 — Critical (blocks adoption or causes data loss)

#### 1. Virtual Schema Ghost State
- **Frequency:** 10/15 reports
- **Reported by:** #1, #2, #4, #5, #6, #7, #8, #11, #12, #15
- **Problem:** `DROP VIRTUAL SCHEMA IF EXISTS ... CASCADE` reports success but the schema persists. Subsequent `CREATE VIRTUAL SCHEMA` fails with "already exists." Metadata queries show nothing. Only `DROP FORCE VIRTUAL SCHEMA` sometimes resolves it; other times a new schema name is required.
- **Impact:** Single biggest time-waster across all personas. 60% of beginner time (#1) spent on this.
- **Root cause:** Exasol platform bug — session-level metadata caching after DROP+CREATE in the same session.
- **Fix options:**
  - A. Document the workaround prominently (use `DROP FORCE`, or use a different schema name)
  - B. Add retry logic in `install_all.sql` (DROP, wait, verify, CREATE)
  - C. Use unique schema names with a timestamp suffix
  - D. Report to Exasol as a platform bug

#### 2. API Keys Exposed in Audit Logs
- **Frequency:** 3/15 reports (but critical severity)
- **Reported by:** #3, #8, #15
- **Problem:** The original `EMBED_AND_PUSH` UDF takes API keys as plain-text SQL parameters. These appear verbatim in `EXA_DBA_AUDIT_SQL`. Anyone with SELECT on audit tables can harvest credentials.
- **Impact:** Security blocker for any environment with API keys (OpenAI, Qdrant with auth).
- **Fix:** `EMBED_AND_PUSH_V2` (CONNECTION-based) solves this — CONNECTION passwords are redacted as `<SECRET>` in audit logs. Make V2 the default, deprecate V1, add a security warning to V1's docs.

#### 3. CASCADE Destroys ADAPTER Schema
- **Frequency:** 1/15 reports (but catastrophic when it happens)
- **Reported by:** #1
- **Problem:** `DROP VIRTUAL SCHEMA vector_schema CASCADE` can destroy the entire ADAPTER schema, including all UDF scripts and connections — not just the virtual schema.
- **Impact:** Full stack must be redeployed from scratch.
- **Fix:** Remove `CASCADE` from all DROP VIRTUAL SCHEMA statements. Use `DROP FORCE VIRTUAL SCHEMA IF EXISTS vector_schema` instead. Add a warning in docs.

### P1 — High (significant friction, causes confusion or wasted time)

#### 4. Python UDF Raw Tracebacks
- **Frequency:** 5/15 reports
- **Reported by:** #5, #9, #11, #14, #15
- **Problem:** Python UDF errors (EMBED_AND_PUSH, CREATE_QDRANT_COLLECTION) produce 30-40 line stack traces from `urllib` internals. The useful info (which URL failed, what the status code was) is buried at the very end.
- **Impact:** Beginners and troubleshooters waste time parsing tracebacks. Contrast with the Lua adapter which produces clean one-line errors.
- **Fix:** Wrap `urllib.error.URLError` and `urllib.error.HTTPError` in all Python UDFs with a one-line format: `"Connection to {url} failed: {reason}"` or `"HTTP {status} from {url}: {body}"`.

#### 5. No Sample Data / Hello World Block
- **Frequency:** 5/15 reports
- **Reported by:** #4, #8, #11, #12, #15
- **Problem:** After deploying the stack, there's no ready-to-run example that creates a table, inserts sample documents, ingests them, and queries. The README shows `FROM MY_SCHEMA.MY_TABLE` as a placeholder.
- **Impact:** Every new user must figure out data ingestion on their own before seeing a result.
- **Fix:** Add a "Hello World" section to the README and/or `install_all.sql` that creates a sample table, inserts 5-8 docs, runs EMBED_AND_PUSH (or V2), refreshes, and queries.

#### 6. OLLAMA_URL Default Misleading
- **Frequency:** 5/15 reports
- **Reported by:** #4, #5, #7, #9, #11
- **Problem:** The `OLLAMA_URL` property defaults to `http://localhost:11434`. This never works in Docker because Exasol can't reach the host's localhost. Every user must override it with the Docker bridge IP.
- **Impact:** Silent failure on first query if the user doesn't know to change it.
- **Fix options:**
  - A. Remove the default (make it required)
  - B. Change default to `http://172.17.0.1:11434` (common Docker bridge)
  - C. Keep the default but add a prominent warning in docs and install_all.sql

#### 7. No Exasol Docker Run Command
- **Frequency:** 3/15 reports
- **Reported by:** #1, #12, #15
- **Problem:** The Quick Start provides `docker run` commands for Qdrant and Ollama but not for Exasol itself. Exasol is the hardest to set up (privileged flag, slow boot, default credentials).
- **Impact:** Newcomers who don't already have Exasol running are stuck at step 1.
- **Fix:** Add to Quick Start:
  ```bash
  docker run -d --name exasoldb -p 8563:8563 --privileged exasol/docker-db:latest
  # Wait ~90 seconds for initialization
  # Connect: host=localhost, port=8563, user=sys, password=exasol
  ```

#### 8. Silent Behavior on Unsupported Predicates
- **Frequency:** 3/15 reports
- **Reported by:** #5, #10, #11
- **Problem:** Using `WHERE "QUERY" LIKE '%AI%'`, `WHERE "SCORE" > 0.5`, or compound `AND`/`OR` filters returns empty results silently — no error, no hint.
- **Impact:** Users think there's no data when actually the predicate was ignored.
- **Fix:** Return a hint row (like the NO_QUERY pattern) explaining that only `WHERE "QUERY" = 'text'` is supported, or expand capability support.

### P2 — Medium (improvement opportunities)

#### 9. UX Pipeline Fixes Not Deployed
- **Frequency:** 6/15 reports
- **Reported by:** #6, #7, #11, #13, #14, #15
- **Problem:** Topics 2-5 (COLLECTION_FILTER, EMBED_AND_PUSH_V2, PREFLIGHT_CHECK, empty-query handling) exist in source code but were not deployed to the running Exasol instance. There's no version tracking — no way to know which adapter version is live.
- **Impact:** Code/deployment drift. Users see features in docs that don't exist in the deployed adapter.
- **Fix:** Add a version constant to the Lua adapter (e.g., `ADAPTER_VERSION = "2.1.0"`) queryable via `SELECT * FROM SYS.EXA_ALL_SCRIPTS WHERE SCRIPT_NAME = 'QDRANT_ADAPTER'` or a dedicated UDF.

#### 10. 7-Second Query Latency
- **Frequency:** 2/15 reports
- **Reported by:** #14, #15
- **Problem:** Every search query takes 5-8 seconds regardless of collection size. ~80% of time is Exasol's Lua sandbox initialization. Raw Ollama+Qdrant is ~150ms.
- **Impact:** Unusable for interactive/real-time search. Undocumented — users discover it by surprise.
- **Fix options:**
  - A. Document the latency profile prominently (set expectations)
  - B. Investigate Exasol UDF caching / sandbox reuse options
  - C. Add timing instrumentation output (optional verbose mode)
  - D. Consider a Python UDF alternative that avoids Lua sandbox overhead

#### 11. REFRESH After CREATE is Redundant
- **Frequency:** 2/15 reports
- **Reported by:** #13, #8
- **Problem:** `CREATE VIRTUAL SCHEMA` already performs an implicit refresh. The explicit `ALTER VIRTUAL SCHEMA REFRESH` in install_all.sql can fail with session ghost state on re-runs.
- **Impact:** Breaks idempotency for CI/CD pipelines.
- **Fix:** Remove the explicit REFRESH from install_all.sql. Add a comment explaining why.

#### 12. No Performance Tuning Knobs
- **Frequency:** 1/15 reports
- **Reported by:** #14
- **Problem:** BATCH_SIZE, MAX_CHARS, and connection timeouts are all hardcoded. No timing instrumentation. No embedding cache.
- **Impact:** Users can't optimize for their workload.
- **Fix:** Expose BATCH_SIZE and MAX_CHARS as UDF parameters with defaults.

#### 13. Ollama IP Split (Gateway vs Container)
- **Frequency:** 3/15 reports
- **Reported by:** #4, #11, #12
- **Problem:** The Lua adapter uses the Docker bridge gateway IP (172.17.0.1) for Ollama. The Python UDFs may need the Ollama container IP (172.17.0.4). This inconsistency is undocumented.
- **Impact:** UDF ingestion silently fails when users use the same IP everywhere.
- **Fix:** Document clearly in README and install_all.sql. Or, make the UDFs use the same gateway IP that the adapter uses.

### P3 — Low (polish and future features)

#### 14. No SCORE Filtering
- **Reported by:** #5, #10, #11
- **Problem:** `WHERE "SCORE" > 0.5` is not supported. Users want to filter low-relevance results.
- **Fix:** Add GREATER_THAN capability for the SCORE column, pass as `score_threshold` to Qdrant.

#### 15. No Metadata Pass-Through
- **Reported by:** #10, #11
- **Problem:** Only 4 fixed columns (ID, TEXT, SCORE, QUERY). Users want to access custom Qdrant payload fields.
- **Fix:** Consider dynamic column mapping from Qdrant payload keys.

#### 16. No BM25 / Hybrid Search
- **Reported by:** #11
- **Problem:** No keyword-based search. Semantic-only. Elasticsearch users expect BM25 + vector hybrid.
- **Fix:** Future feature — out of scope for current adapter architecture.

#### 17. Broken Unit Test Suite
- **Reported by:** #15
- **Problem:** Tests import `qdrant_client` which the code no longer uses. Tests will fail on import.
- **Fix:** Update test imports to match current stdlib-only approach.

#### 18. PowerShell-Only Option B
- **Reported by:** #4, #12
- **Problem:** Direct HTTP ingestion example uses PowerShell only. No curl alternative.
- **Fix:** Add a curl example alongside the PowerShell one.

---

## Strengths Consistently Praised

These should be preserved and built upon:

1. **Search quality** — 100% top-1 accuracy, meaningful score differentiation (cited by #2, #10, #11, #14)
2. **install_all.sql structure** — well-organized, self-documenting, box-drawing headers (cited by #2, #4, #7, #12)
3. **Lua adapter error messages** — clean one-line format with URL and status (cited by #5, #9)
4. **SQL-native query syntax** — `WHERE "QUERY" = 'text'` is intuitive (cited by #2, #10, #12)
5. **Zero pip dependencies** — Python UDFs use stdlib only (cited by #15)
6. **NO_QUERY hint row** — teaches correct syntax on empty query (cited by #1, #5, #9)

---

## Recommended Fix Priority

Based on impact x frequency x effort:

| Priority | Issue | Effort | Expected Score Lift |
|----------|-------|--------|-------------------|
| 1 | Document ghost state workaround + remove CASCADE | Low | +0.5 |
| 2 | Make EMBED_AND_PUSH_V2 the default | Low | +0.3 |
| 3 | Add hello world / sample data block | Low | +0.4 |
| 4 | Wrap Python UDF errors | Low | +0.3 |
| 5 | Add Exasol docker run to Quick Start | Low | +0.2 |
| 6 | Fix OLLAMA_URL default | Low | +0.2 |
| 7 | Deploy topics 2-5 + add version tracking | Medium | +0.5 |
| 8 | Remove redundant REFRESH | Low | +0.1 |
| 9 | Add unsupported predicate hints | Medium | +0.2 |
| 10 | Document latency profile | Low | +0.1 |

**Estimated score after top 7 fixes: 6.5 -> 8.5-9.0/10**

---

## Individual Reports

Full iteration reports are in `ux-pipeline/ux-study/iteration-NN.md` (15 files, ~230KB total).
