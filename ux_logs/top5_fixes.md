# Top 5 Most Impactful UX Fixes

Identified from a 10-iteration UX study (2026-04-03) where the full Exasol Qdrant semantic search stack was deployed from scratch 10 times, each iteration focusing on a different UX dimension. Average UX score: **4.9/10**.

---

## 1. One-Command Installer / Deployment Script -- IMPLEMENTED

**Status**: Implemented in commit `75dd951` (2026-04-04). See `scripts/install_all.sql`.

**What was done**: Created `scripts/install_all.sql` — a single SQL file that deploys the entire stack (schema, connection, Lua adapter, Python UDFs, virtual schema) with no pasting required. Users update 5 config values and run one file.

**Previous state**: The Lua adapter was a 3,527-line / 134KB single file (`dist/adapter.lua`) that had to be manually pasted into a `CREATE LUA ADAPTER SCRIPT` statement. Single-quote escaping, SQL client buffer limits, and `SYS.EXA_ALL_SCRIPTS.SCRIPT_TEXT` including the CREATE header caused double-header syntax errors when copying between schemas.

**Estimated UX lift**: 4.9 -> 6.5 (this fix alone addresses the #1 complaint across all iterations)

---

## 2. Graceful Empty-Query Handling

**Current state**: Running `SELECT * FROM VS.collection` without a `WHERE "QUERY" = '...'` clause sends an empty string to Ollama for embedding, which crashes. The error is a cryptic column-count mismatch instead of a clear message.

**Impact**: This is the first thing any SQL user will try. Instant confusion and loss of trust. Reported in iterations 2, 5.

**Proposed fix** (in `src/lua/adapter/QueryRewriter.lua`):
- Detect empty/nil query text before calling Ollama
- Return an empty result set (`SELECT * FROM (VALUES (NULL, NULL, NULL, NULL)) WHERE FALSE`)
- Or return a clear error: `Semantic search requires WHERE "QUERY" = 'your search text'`

**Estimated UX lift**: +0.5 points

---

## 3. Collection Scoping on Virtual Schemas

**Current state**: The virtual schema exposes ALL Qdrant collections as tables. There is no way to filter or scope which collections are visible.

**Impact**: Multi-tenant environments, multi-project setups, and even development workflows (where test collections coexist with production) cannot isolate data. Reported in iterations 3, 6, 8, 10.

**Proposed fix** (in `src/lua/adapter/MetadataReader.lua` and `src/lua/adapter/AdapterProperties.lua`):
- Add a `COLLECTION_FILTER` property (glob or comma-separated list)
- Example: `COLLECTION_FILTER='bank_*,products'`
- Filter collections in `MetadataReader` before returning table metadata

**Estimated UX lift**: +0.3 points

---

## 4. CONNECTION-Based UDF Configuration

**Current state**: `EMBED_AND_PUSH` takes 9 positional parameters: `(qdrant_url, collection, text, id, provider, model, embedding_key, batch_size, qdrant_api_key)`. No named parameters, no defaults, easy to mix up order. The `qdrant_api_key` appears in plain text in `EXA_DBA_AUDIT_SQL`.

**Impact**: Error-prone interface (users must memorize parameter positions), and a security risk (credentials in audit logs). Reported in iterations 4, 8.

**Proposed fix** (in `exasol_udfs/embed_and_push.py`):
- Read infrastructure config (URLs, API keys, model) from a CONNECTION object
- Reduce the UDF signature to: `EMBED_AND_PUSH(connection_name, collection, text, id)`
- Credentials never appear in SQL text, only in the CONNECTION object
- Add `GROUP BY IPROC()` note prominently in docs (iteration 4 flagged this as undiscoverable)

**Estimated UX lift**: +0.4 points (usability + security combined)

---

## 5. Pre-Flight Health Check

**Current state**: No way to verify Qdrant and Ollama are reachable before creating the virtual schema or ingesting data. The first indication of a connectivity failure comes at query time or during ingestion with opaque error messages. Docker bridge IP (`172.17.0.1`) is tribal knowledge.

**Impact**: Every new user wastes time debugging connectivity. Network errors produce raw 40-line Python tracebacks. Reported in iterations 2, 6, 10.

**Proposed fix**:
- Create a `PREFLIGHT_CHECK(qdrant_url, ollama_url, model)` scalar UDF that:
  - Pings Qdrant `/collections` endpoint
  - Pings Ollama `/api/tags` endpoint
  - Verifies the embedding model is available
  - Tests a sample embedding round-trip
  - Returns a structured pass/fail report
- Run automatically during `CREATE VIRTUAL SCHEMA` (validate CONNECTION + OLLAMA_URL)
- Auto-detect Docker bridge IP when possible

**Estimated UX lift**: +0.3 points

---

## Summary

| # | Fix | Effort | UX Lift |
|---|-----|--------|---------|
| 1 | ~~One-command installer~~ | ~~Medium~~ | ~~+1.6~~ DONE |
| 2 | Graceful empty-query | Low | +0.5 |
| 3 | Collection scoping | Low-Medium | +0.3 |
| 4 | CONNECTION-based UDF config | Medium | +0.4 |
| 5 | Pre-flight health check | Medium | +0.3 |
| | **Total estimated** | | **4.9 -> 8.0** |

Implementing all 5 fixes would raise the UX score from **4.9/10 to approximately 8.0/10**, making the adapter accessible to general data engineers rather than only deep Exasol experts.
