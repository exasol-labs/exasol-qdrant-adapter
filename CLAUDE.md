# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

Exasol Virtual Schema adapter for semantic similarity search using Qdrant (vector store) and Ollama (local embeddings). Written in Lua, runs inside Exasol's UDF sandbox. Companion Python UDFs handle data ingestion.

**Data flow:** Exasol SQL query -> Lua adapter (inside Exasol) -> Ollama (embed query text) -> Qdrant (hybrid search: vector similarity + keyword RRF fusion) -> VALUES SQL returned to Exasol.

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

# Integration tests (requires running Exasol, Qdrant, Ollama)
python -m pytest tests/integration/

# Single test file
python -m pytest tests/unit/test_embed_and_push.py

# Single test class
python -m pytest tests/unit/test_embed_and_push.py::TestEmbedOpenAI
```

Tests use `unittest.mock` (MagicMock, patch). No Lua tests exist currently — only the Python UDFs are tested.

## Architecture

### Lua Adapter (`src/lua/`)

- `entry.lua` — Global `adapter_call()` entrypoint, delegates to RequestDispatcher
- `adapter/QdrantAdapter.lua` — Adapter lifecycle: createVirtualSchema, refresh, setProperties, pushDown, dropVirtualSchema. Extends `AbstractVirtualSchemaAdapter` from `virtual-schema-common-lua`
- `adapter/AdapterProperties.lua` — Property keys (CONNECTION_NAME, QDRANT_MODEL, OLLAMA_URL, QDRANT_URL, COLLECTION_FILTER), validation, defaults
- `adapter/MetadataReader.lua` — Maps Qdrant collections to Exasol tables with fixed 4-column schema: ID (VARCHAR), TEXT (VARCHAR), SCORE (DOUBLE), QUERY (VARCHAR). Supports glob-based collection filtering via COLLECTION_FILTER property.
- `adapter/QueryRewriter.lua` — Embeds query text via Ollama, performs hybrid search (vector + keyword RRF fusion) against Qdrant, builds VALUES SQL for pushDown response. Falls back to pure vector search when no meaningful keywords are extracted. Gracefully handles empty/missing query text (returns hint row instead of crashing).
- `adapter/tokenizer.lua` — Pure-Lua keyword extractor for hybrid search. Splits query text, removes stopwords, deduplicates, and generates compound tokens from adjacent pairs (e.g., "JP" + "Morgan" -> "jpmorgan"). Capped at 12 tokens. Used by QueryRewriter to build per-keyword Qdrant filter legs.
- `adapter/capabilities.lua` — Declares supported capabilities (SELECTLIST_EXPRESSIONS, FILTER_EXPRESSIONS, LIMIT, EQUAL predicate, STRING literal)
- `util/http.lua` — LuaSocket + cjson HTTP wrapper (get_json, post_json, post_raw)

### Python UDFs (`exasol_udfs/`)

- `embed_and_push.py` — SET UDF: batch embed text via Ollama/OpenAI -> upsert into Qdrant. Uses only Python stdlib (no pip packages)
- `embed_and_push_v2` — (in `install_all.sql`) Simplified 4-parameter SET UDF that reads config from a CONNECTION object: `EMBED_AND_PUSH_V2(connection_name, collection, id, text)`. Credentials stay in the CONNECTION, not in SQL text.
- `create_collection.py` — Scalar UDF: create a Qdrant collection with specified dimensions and distance metric
- `preflight_check` — (in `install_all.sql`) Scalar UDF: `PREFLIGHT_CHECK(qdrant_url, ollama_url, model)` validates Qdrant connectivity, Ollama connectivity, model availability, and embedding round-trip. Returns structured pass/fail report.

### Key Patterns

- Lua OOP via metatables (`QdrantAdapter:new()`, etc.)
- Module pattern: `local M = {}; return M`
- Private methods prefixed with `_`
- All column names must be double-quoted in SQL (`"QUERY"`, `"SCORE"`) — Exasol reserves some of these words

## Deployment

No JAR, no BucketFS, no Maven.

**Primary method:** Run `scripts/install_all.sql` in any SQL client. This single file deploys the entire stack — schema, connection, Lua adapter, Python UDFs (`CREATE_QDRANT_COLLECTION`, `EMBED_AND_PUSH`, `EMBED_AND_PUSH_V2`, `PREFLIGHT_CHECK`), and virtual schema. Users update 5 config values (host IP, ports, model, schema name) and execute.

**Individual components:**
- `scripts/install_adapter.sql` — Lua adapter script only
- `scripts/create_udfs_ollama.sql` — Python UDFs only

## Infrastructure

- **Exasol 7.x+** (typically Docker for dev)
- **Qdrant 1.9+** on port 6333
- **Ollama** on port 11434 with `nomic-embed-text` model (768 dimensions)
- Docker bridge gateway IP (usually `172.17.0.1`) used for container-to-container communication — `host.docker.internal` does not work in Exasol's UDF sandbox on Linux

## Test Dataset

**Always use `MUFA.BANK_FAILURES` as the test/demo dataset** when deploying, testing, or demonstrating the semantic search stack. Do not create ad-hoc sample data — use this table.

- **Table:** `MUFA.BANK_FAILURES` (544 rows — US bank failures)
- **Columns:** `C1` (DECIMAL(3,0)), `BANK` (VARCHAR(84)), `CITY` (VARCHAR(23)), `STATE` (VARCHAR(18)), `DATE` (DATE), `ACQUIRED_BY` (VARCHAR(100)), `ASSETS_MIL` (DECIMAL(7,1))
- **Qdrant collection name:** `bank_failures`
- **ID column:** `CAST(ROWNUM AS VARCHAR(36))` (note: `C1` is NOT unique — it repeats per year, only 157 distinct values across 544 rows)
- **Reserved keywords:** `STATE` and `DATE` are Exasol reserved keywords — always double-quote them in SQL
- **Text column:** Concatenate into a descriptive sentence for best embedding quality:
  ```sql
  "BANK" || ' in ' || "CITY" || ', ' || "STATE" || '. Failed on ' || CAST("DATE" AS VARCHAR(10)) || '. Acquired by ' || "ACQUIRED_BY" || '. Assets: $' || CAST("ASSETS_MIL" AS VARCHAR(20)) || ' million.'
  ```

**Ingestion command (after deploying via install_all.sql):**
```sql
SELECT ADAPTER.CREATE_QDRANT_COLLECTION('172.17.0.1', 6333, '', 'bank_failures', 768, 'Cosine', '');

SELECT ADAPTER.EMBED_AND_PUSH(
    CAST(ROWNUM AS VARCHAR(36)),
    "BANK" || ' in ' || "CITY" || ', ' || "STATE" || '. Failed on ' || CAST("DATE" AS VARCHAR(10)) || '. Acquired by ' || "ACQUIRED_BY" || '. Assets: $' || CAST("ASSETS_MIL" AS VARCHAR(20)) || ' million.',
    '172.17.0.1', 6333, '',
    'bank_failures',
    'ollama',
    'http://172.17.0.1:11434',
    'nomic-embed-text'
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
