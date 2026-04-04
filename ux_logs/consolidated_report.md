# Exasol Qdrant Adapter — UX Improvement Report

## 10-Iteration Study (2026-04-03)

Each iteration deployed the full semantic search stack from scratch using the `MUFA.SEMANTIC` table (544 bank failure records) and logged UX improvements from a different perspective.

---

## Overall Scores

| Iter | Focus Area | Score | Key Finding |
|------|-----------|-------|-------------|
| 1 | First-time Setup Friction | N/A* | Setup completed; detailed log lost to permission issue |
| 2 | Error Handling | 5/10 | Empty query produces misleading column-count error |
| 3 | Documentation & Discoverability | 4/10 | No sequential setup guide; steps scattered across files |
| 4 | Data Ingestion Experience | 5/10 | 9-parameter positional UDF interface is unintuitive |
| 5 | Query Experience | 5/10 | Query without WHERE clause crashes the adapter |
| 6 | Deployment & Infrastructure | 5/10 | 3,527-line Lua file causes double-header bugs when copying |
| 7 | Scalability & Performance | 6/10 | No ingestion progress feedback; 1M rows ~14hrs with no visibility |
| 8 | Security & Permissions | 5/10 | UDF credentials visible in audit logs; no collection isolation |
| 9 | Maintenance & Operations | 5/10 | No incremental ingestion; no health monitoring; no retry/backoff |
| 10 | Holistic Review & v2 Vision | 4/10 | 3-5x more setup complexity than any competitor |

**Average UX Score: 4.9/10**

*Iteration 1 completed setup and queries successfully but detailed findings were truncated.

---

## Critical Issues (Immediate Action Required)

### 1. Empty/Missing Query Crashes the Adapter
- **Source**: Iterations 2, 5
- **Problem**: `SELECT * FROM VS.collection` without a WHERE clause sends an empty string to Ollama for embedding, which fails. The error message is a cryptic column-count mismatch instead of "QUERY filter required."
- **Impact**: First thing any SQL user will try. Instant confusion.
- **Fix**: Return an empty result set or a clear error: "Semantic search requires WHERE \"QUERY\" = 'your search text'"

### 2. 3,500-Line Lua File Deployment is Impractical
- **Source**: Iterations 3, 6, 7, 10
- **Problem**: The adapter is a 134KB single file that must be pasted into a CREATE ADAPTER SCRIPT statement. Single-quote escaping, client buffer limits, and `SYS.EXA_ALL_SCRIPTS.SCRIPT_TEXT` including the CREATE header cause double-header syntax errors when copying between schemas.
- **Impact**: Biggest barrier to adoption. Every competitor ships as an installable package.
- **Fix**: Provide a deployment SQL script that wraps the adapter in proper escaping, or an installer UDF.

### 3. UDF Credentials Exposed in Audit Logs
- **Source**: Iteration 8
- **Problem**: EMBED_AND_PUSH takes the Qdrant API key as an inline SQL parameter. This appears in `EXA_DBA_AUDIT_SQL` and any query logging.
- **Impact**: Security risk in production environments.
- **Fix**: Read credentials from a CONNECTION object inside the UDF instead of passing as parameters.

### 4. No Collection-Level Isolation
- **Source**: Iterations 3, 6, 8, 10
- **Problem**: Virtual schema exposes ALL Qdrant collections. No way to scope or filter.
- **Impact**: Multi-tenant and multi-project environments cannot isolate data.
- **Fix**: Add a `COLLECTION_FILTER` or `COLLECTION_NAME` property to the virtual schema.

---

## High-Priority Issues

### 5. No Ingestion Progress Feedback
- **Source**: Iterations 4, 7, 9
- **Problem**: EMBED_AND_PUSH is a black box — no progress output during execution. At 544 rows it's tolerable; at 100K+ rows it's unacceptable.
- **Impact**: Users can't tell if ingestion is running, stuck, or failed.
- **Fix**: Emit per-batch progress rows (e.g., "Batch 5/50: 500 rows embedded, 44 remaining").

### 6. EMBED_AND_PUSH 9-Parameter Positional Interface
- **Source**: Iteration 4
- **Problem**: The UDF takes 9 positional parameters: `(qdrant_url, collection, text, id, provider, model, embedding_key, batch_size, qdrant_api_key)`. No named parameters, no defaults, easy to mix up order.
- **Impact**: Error-prone; users must memorize parameter positions.
- **Fix**: Use a CONNECTION object for infrastructure config, reducing to 2-3 parameters.

### 7. Property Name Typos Silently Ignored
- **Source**: Iteration 2
- **Problem**: Setting `CONECTION_NAME` (typo) instead of `CONNECTION_NAME` produces no error — the property is just ignored, and the adapter fails later with an unrelated message.
- **Impact**: Debugging takes much longer than it should.
- **Fix**: Validate property names and warn about unrecognized keys.

### 8. Docker Networking IP is Tribal Knowledge
- **Source**: Iterations 6, 10
- **Problem**: `172.17.0.1` (Docker bridge gateway) is required for Exasol-to-host communication. `host.docker.internal` doesn't work in Exasol UDF sandbox on Linux, contradicting common Docker advice.
- **Impact**: Every new user hits this. Not documented prominently.
- **Fix**: Auto-detect Docker bridge IP, or provide a connectivity test UDF that reports the correct IP.

### 9. GROUP BY IPROC() Requirement is Undiscoverable
- **Source**: Iteration 4
- **Problem**: EMBED_AND_PUSH requires `GROUP BY IPROC()` in the SELECT statement. This is an Exasol SET UDF requirement, but it's not mentioned in the adapter docs.
- **Impact**: Users get cryptic errors on first ingestion attempt.
- **Fix**: Document prominently; consider wrapping in a simpler SCALAR UDF that handles this internally.

### 10. No Pre-flight Health Check
- **Source**: Iterations 2, 6
- **Problem**: No way to verify Qdrant and Ollama are reachable before creating the virtual schema. First failure comes at query time with an opaque error.
- **Fix**: Add a `TEST_CONNECTIVITY` property or UDF that validates all endpoints before setup.

---

## Medium-Priority Issues

| # | Issue | Source |
|---|-------|--------|
| 11 | `QDRANT_MODEL` property is misleadingly named (it's the Ollama model) | Iter 3 |
| 12 | Embedding model specified in two places (VS property + UDF parameter) | Iter 10 |
| 13 | CONNECTION vs property split is asymmetric (Qdrant in CONNECTION, Ollama in property) | Iter 6 |
| 14 | `embedding_key` parameter has overloaded semantics (URL for Ollama, API key for OpenAI) | Iter 4 |
| 15 | Network errors produce raw 40-line Python tracebacks | Iter 2 |
| 16 | Reserved word collisions (STATE, DATE) produce unhelpful syntax errors | Iters 3, 6 |
| 17 | Validation reports only the first missing property, not all | Iter 2 |
| 18 | Non-EQUAL predicates on QUERY column silently fall through | Iter 2 |
| 19 | No incremental ingestion — re-running re-embeds everything | Iter 9 |
| 20 | No retry/backoff in HTTP calls; fragile on service restarts | Iter 9 |
| 21 | Batch size hardcoded at 100, no user tuning | Iter 7 |
| 22 | No way to inspect embeddings or explain similarity scores | Iter 9 |
| 23 | 6,000-char text truncation limit hidden in code, not documented | Iter 3 |
| 24 | No production deployment guide (TLS, authentication, networking) | Iter 6 |
| 25 | No upgrade/migration story — no versioning, no changelog, no migration scripts | Iter 9 |

---

## What Works Well (Consistent Across All Iterations)

1. **SQL-native query syntax** — `WHERE "QUERY" = 'search text'` is intuitive once you know it
2. **Zero external dependencies** — Python UDFs use stdlib only; Lua adapter is self-contained
3. **No JAR, no BucketFS, no Maven** — dramatically simpler than Java-based adapters
4. **Clean 4-column abstraction** — ID, TEXT, SCORE, QUERY is easy to understand
5. **Idempotent collection creation** — safe to re-run
6. **Meaningful semantic results** — cosine similarity scores are consistent and useful
7. **CREATE_QDRANT_COLLECTION auto-dimension detection** — nice convenience feature
8. **Virtual schema auto-discovers collections** — REFRESH picks up new data automatically

---

## Competitive Comparison (from Iteration 10)

| | Exasol Qdrant | pgvector | Databricks | Snowflake Cortex |
|---|---|---|---|---|
| Setup steps | 6+ manual SQL | 1 DDL | 1 DDL | 1 DDL |
| Embedding | External UDF | pgai extension | Built-in | Built-in |
| Hybrid search | No | Yes | Yes | Automatic |
| Query syntax | Non-standard | `<=>` operator | SQL function | SQL function |
| Auto-sync | Manual | Manual | Delta Sync | Automatic |

**Gap**: 3-5x more setup complexity than any competitor. The gap is entirely developer experience and packaging, not architecture.

---

## v2 Ideal Workflow (from Iteration 10)

```sql
-- 1. Install (one-time)
INSTALL EXTENSION 'qdrant-vector-search' VERSION '2.0';

-- 2. Configure (one-time)
CREATE VECTOR SEARCH CONFIGURATION my_config
    EMBEDDING_SERVICE = 'http://auto-detect:11434'
    EMBEDDING_MODEL = 'nomic-embed-text'
    VECTOR_STORE = 'http://auto-detect:6333';

-- 3. Index a table
CREATE VECTOR SEARCH INDEX bank_search
    ON mufa.semantic("Bank" || ' ' || "City" || ' ' || "State")
    USING my_config;

-- 4. Search
SELECT * FROM SEMANTIC_SEARCH(bank_search, 'community banks Midwest', TOP 10)
WHERE score > 0.6;

-- 5. Refresh
REFRESH VECTOR SEARCH INDEX bank_search;
```

**Principles**: Zero Docker-IP guessing, declarative setup, SQL-native syntax, built-in hybrid search, automatic embedding management, incremental refresh.

---

## Top 5 Most Impactful Improvements (Ranked)

1. **One-command installer / deployment script** — Eliminates the #1 adoption barrier (pasting 3,500 lines of Lua)
2. **Graceful empty-query handling** — Return empty results or clear error instead of crashing
3. **Collection scoping on virtual schemas** — Enable multi-tenant and multi-project use
4. **CONNECTION-based UDF config** — Reduce EMBED_AND_PUSH from 9 parameters to 2-3, hide credentials
5. **Pre-flight health check** — Validate Qdrant + Ollama connectivity before setup begins

---

## Conclusion

The Exasol Qdrant adapter has a **strong architectural foundation** — Exasol's MPP engine + Qdrant's vector search + Ollama's local embeddings is a compelling stack. The query-time experience post-setup is genuinely good.

The gap is **developer experience**: deployment friction, error handling, documentation, and operational tooling. Addressing the top 5 improvements above would likely raise the UX score from **4.9/10 to 7-8/10** and make the adapter accessible to general data engineers rather than only deep Exasol experts.

**Single biggest barrier to adoption**: Pasting a 3,500-line Lua file into a SQL statement with manual quote escaping.
