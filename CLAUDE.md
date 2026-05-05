# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

Exasol Virtual Schema adapter for semantic similarity search using Qdrant (vector store) and an in-database `sentence-transformers` UDF for embeddings. Written in Lua, runs inside Exasol's UDF sandbox. Companion Python UDFs handle data ingestion and query-time embedding — no external embedding service required.

**Data flow:** Exasol SQL query -> Lua adapter (inside Exasol) generates pushdown SQL that calls `ADAPTER.SEARCH_QDRANT_LOCAL` (a SET UDF) -> the SET UDF embeds the query text in-process via SLC + BucketFS model and runs Qdrant hybrid search (vector similarity + per-keyword RRF fusion) -> rows emitted back to Exasol. The Lua adapter itself does no HTTP and no embedding — Exasol forbids `exa.pquery_no_preprocessing` during pushdown, so all query-time work lives in the SET UDF.

## Build

The modular source lives in `src/lua/`. A bundled version (`dist/adapter.lua`) is built by lua-amalg, but deployment no longer requires pasting it — see Deployment below.

```bash
# Install dev dependencies (once)
luarocks install amalg
luarocks install virtual-schema-common-lua

# Rebuild after modifying src/lua/
lua build/amalg.lua
```

Output: `dist/adapter.lua` (bundled single file). The standalone adapter in `scripts/install_adapter.sql` and `scripts/install_all.sql` is a self-contained flattened version that does not depend on this build step.

## Tests

```bash
# Unit tests
python -m pytest tests/unit/

# Integration tests (requires running Exasol and Qdrant; SLC + model already in BucketFS)
python -m pytest tests/integration/

# Single test file
python -m pytest tests/unit/test_embed_text.py
```

Tests use `unittest.mock` (MagicMock, patch). No Lua tests exist currently — only the Python UDFs are tested.

## Architecture

### Lua Adapter (`src/lua/`)

- `entry.lua` — Global `adapter_call()` entrypoint, delegates to RequestDispatcher
- `adapter/QdrantAdapter.lua` — Adapter lifecycle: createVirtualSchema, refresh, setProperties, pushDown, dropVirtualSchema. Extends `AbstractVirtualSchemaAdapter` from `virtual-schema-common-lua`
- `adapter/AdapterProperties.lua` — Property keys (CONNECTION_NAME, QDRANT_MODEL, QDRANT_URL, COLLECTION_FILTER), validation, defaults. `OLLAMA_URL` is a removed property and rejected with a migration error if present.
- `adapter/MetadataReader.lua` — Maps Qdrant collections to Exasol tables with fixed 4-column schema: ID (VARCHAR), TEXT (VARCHAR), SCORE (DOUBLE), QUERY (VARCHAR). Supports glob-based collection filtering via COLLECTION_FILTER property.
- `adapter/QueryRewriter.lua` — Builds the pushdown SQL that calls `ADAPTER.SEARCH_QDRANT_LOCAL(connection, collection, query_text, limit)` and aliases its emitted columns back to `"ID"`, `"TEXT"`, `"SCORE"`, `"QUERY"`. The Lua adapter itself does no HTTP, no embedding, and no tokenization. Gracefully handles empty/missing query text or unsupported predicates by returning a single-row hint via `VALUES` instead of failing.
- `adapter/capabilities.lua` — Declares supported capabilities (SELECTLIST_EXPRESSIONS, FILTER_EXPRESSIONS, LIMIT, EQUAL predicate, STRING literal)
- `util/http.lua` — LuaSocket + cjson HTTP wrapper (get_json, post_json, post_raw)

### Python UDFs (`exasol_udfs/`)

- `search_qdrant_local.py` — SET UDF: owns the entire query path. Embeds the query text in-process, builds and executes a Qdrant hybrid search (vector leg + per-keyword RRF fusion, capped at 12 keywords; falls back to pure-vector when no keywords survive stopword filtering), emits one row per hit `(result_id, result_text, result_score, result_query)`. Called by the Lua adapter via the pushdown SQL it generates. The stopword list and `extract_keywords` tokenizer live here — they used to live in `tokenizer.lua` but that file was removed.
- `embed_and_push_local.py` — SET UDF: in-process embedding ingest. Loads `sentence-transformers` with `nomic-embed-text-v1.5` from BucketFS at module-load time and writes points directly to Qdrant. Requires the `qdrant-embed` SLC plus the model tarball uploaded to BucketFS, and `PYTHON3_QDRANT` registered in `SCRIPT_LANGUAGES`. See `docs/local-embeddings.md` and `scripts/install_local_embeddings.sql`.
- `embed_text.py` — SCALAR UDF: utility/parity scalar that returns the 768-float vector as a JSON string for input text. Same SLC + model as the other UDFs. Not on the query hot path (the Lua adapter does NOT call this UDF) — kept for parity testing and ad-hoc SQL-side embedding. Returns NULL on NULL/empty input.
- `create_collection.py` → registered as `ADAPTER.CREATE_QDRANT_COLLECTION` — Scalar UDF: create a Qdrant collection with specified dimensions and distance metric, plus a `text` payload index for hybrid search.
- `preflight_check` — (in `install_all.sql`) Scalar UDF: `PREFLIGHT_CHECK(qdrant_url)` (single argument) — validates Qdrant connectivity and runs an in-process `SentenceTransformer.encode('preflight')` round-trip (loads the same SLC + BucketFS model directly; does not call `EMBED_TEXT`). Returns structured pass/fail report.

### Key Patterns

- Lua OOP via metatables (`QdrantAdapter:new()`, etc.)
- Module pattern: `local M = {}; return M`
- Private methods prefixed with `_`
- All column names must be double-quoted in SQL (`"QUERY"`, `"SCORE"`) — Exasol reserves some of these words

## Deployment

No JAR, no Maven. One-time SLC + model upload to BucketFS.

**Primary method:** Run `scripts/install_all.sql` in any SQL client. This single file deploys the entire stack — schema, two CONNECTION objects (`qdrant_conn`, `embedding_conn`), `PYTHON3_QDRANT` script-language alias, Lua adapter, Python UDFs (`CREATE_QDRANT_COLLECTION`, `EMBED_AND_PUSH_LOCAL`, `EMBED_TEXT`, `SEARCH_QDRANT_LOCAL`, `PREFLIGHT_CHECK`), and virtual schema. Idempotent — safe to re-run.

**Individual components:**
- `scripts/install_adapter.sql` — Lua adapter script only. The pushdown SQL it generates calls `ADAPTER.SEARCH_QDRANT_LOCAL`, so `install_local_embeddings.sql` must have already been run (or `install_all.sql`).
- `scripts/install_local_embeddings.sql` — Adds the `PYTHON3_QDRANT` alias and the `EMBED_AND_PUSH_LOCAL`, `EMBED_TEXT`, and `SEARCH_QDRANT_LOCAL` UDFs. Requires the `qdrant-embed` SLC + model tarball already uploaded to BucketFS via `scripts/build_and_upload_slc.sh`. See `docs/local-embeddings.md`.

## Infrastructure

- **Exasol 7.x+** (typically Docker for dev)
- **Qdrant 1.9+** on port 6333
- `qdrant-embed` SLC + `nomic-embed-text-v1.5` model (768 dimensions, cosine) in BucketFS
- Docker bridge gateway IP (usually `172.17.0.1`) used for container-to-container communication — `host.docker.internal` does not work in Exasol's UDF sandbox on Linux

No Ollama. No external embedding service. Both ingest and query embed in-process via the SLC.

## Test Dataset

**Always use `MUFA.BANK_FAILURES` as the test/demo dataset** when deploying, testing, or demonstrating the semantic search stack. Do not create ad-hoc sample data — use this table.

- **Table:** `MUFA.BANK_FAILURES` (544 rows — US bank failures)
- **Columns** — case-sensitive; the table was loaded with mixed-case quoted identifiers, so the uppercase forms (`"BANK"`, `"CITY"`, etc.) WILL FAIL with `object BANK not found`. Verify against `SYS.EXA_ALL_COLUMNS` before editing examples:
  - `c1` (DECIMAL(3,0))
  - `"Bank"` (VARCHAR(84))
  - `"City"` (VARCHAR(23))
  - `"State"` (VARCHAR(18))
  - `"Date"` (DATE)
  - `"Acquired by"` (VARCHAR(100))   *(note the space — quoting required)*
  - `"Assets ($mil.)"` (DECIMAL(7,1)) *(note the space, parens, and dot)*
- **Qdrant collection name:** `bank_failures`
- **ID column:** `CAST(ROWNUM AS VARCHAR(36))` (note: `c1` is NOT unique — it repeats per year, only 157 distinct values across 544 rows)
- **Reserved keywords:** `"State"` and `"Date"` collide with Exasol reserved words — always quote them in SQL (which the mixed-case form already requires).
- **Text column:** Concatenate into a descriptive sentence for best embedding quality:
  ```sql
  "Bank" || ' in ' || "City" || ', ' || "State" || '. Failed on ' || CAST("Date" AS VARCHAR(10)) || '. Acquired by ' || "Acquired by" || '. Assets: $' || CAST("Assets ($mil.)" AS VARCHAR(20)) || ' million.'
  ```

**Ingestion command (after deploying via install_all.sql):**
```sql
SELECT ADAPTER.CREATE_QDRANT_COLLECTION('172.17.0.1', 6333, '', 'bank_failures', 768, 'Cosine', '');

SELECT ADAPTER.EMBED_AND_PUSH_LOCAL(
    'embedding_conn',
    'bank_failures',
    CAST(ROWNUM AS VARCHAR(36)),
    "Bank" || ' in ' || "City" || ', ' || "State" || '. Failed on ' || CAST("Date" AS VARCHAR(10)) || '. Acquired by ' || "Acquired by" || '. Assets: $' || CAST("Assets ($mil.)" AS VARCHAR(20)) || ' million.'
)
FROM MUFA.BANK_FAILURES
GROUP BY IPROC();

ALTER VIRTUAL SCHEMA VECTOR_SCHEMA REFRESH;
```

**Example queries:**
```sql
SELECT "ID", "TEXT", "SCORE" FROM vector_schema.bank_failures WHERE "QUERY" = 'banks acquired by JP Morgan' LIMIT 5;
SELECT "ID", "TEXT", "SCORE" FROM vector_schema.bank_failures WHERE "QUERY" = 'large bank failures in New York' LIMIT 5;
SELECT "ID", "TEXT", "SCORE" FROM vector_schema.bank_failures WHERE "QUERY" = 'small community banks in the midwest' LIMIT 5;
```

## UX Pipeline

The `ux-pipeline/` folder contains an automated agent pipeline for implementing and testing UX fixes. Entry point: `.claude/agents/ux-pipeline.md`. See `ux-pipeline/README.md` for details. Test artifacts are committed in `ux-pipeline/tests/topic-N/`.

## OpenSpec

The project uses an OpenSpec workflow for spec-driven changes. Specs and change proposals live in `openspec/`. The Lua port spec is at `openspec/specs/lua-port/specs.md`.
