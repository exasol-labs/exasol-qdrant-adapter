# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

Exasol Virtual Schema adapter for semantic similarity search using Qdrant (vector store) and Ollama (local embeddings). Written in Lua, runs inside Exasol's UDF sandbox. Companion Python UDFs handle data ingestion.

**Data flow:** Exasol SQL query -> Lua adapter (inside Exasol) -> Ollama (embed query text) -> Qdrant (cosine similarity search) -> VALUES SQL returned to Exasol.

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
- `adapter/AdapterProperties.lua` — Property keys (CONNECTION_NAME, QDRANT_MODEL, OLLAMA_URL, QDRANT_URL), validation, defaults
- `adapter/MetadataReader.lua` — Maps Qdrant collections to Exasol tables with fixed 4-column schema: ID (VARCHAR), TEXT (VARCHAR), SCORE (DOUBLE), QUERY (VARCHAR)
- `adapter/QueryRewriter.lua` — Embeds query text via Ollama, searches Qdrant, builds VALUES SQL for pushDown response
- `adapter/capabilities.lua` — Declares supported capabilities (SELECTLIST_EXPRESSIONS, FILTER_EXPRESSIONS, LIMIT, EQUAL predicate, STRING literal)
- `util/http.lua` — LuaSocket + cjson HTTP wrapper (get_json, post_json, post_raw)

### Python UDFs (`exasol_udfs/`)

- `embed_and_push.py` — SET UDF: batch embed text via Ollama/OpenAI -> upsert into Qdrant. Uses only Python stdlib (no pip packages)
- `create_collection.py` — Scalar UDF: create a Qdrant collection with specified dimensions and distance metric

### Key Patterns

- Lua OOP via metatables (`QdrantAdapter:new()`, etc.)
- Module pattern: `local M = {}; return M`
- Private methods prefixed with `_`
- All column names must be double-quoted in SQL (`"QUERY"`, `"SCORE"`) — Exasol reserves some of these words

## Deployment

No JAR, no BucketFS, no Maven.

**Primary method:** Run `scripts/install_all.sql` in any SQL client. This single file deploys the entire stack — schema, connection, Lua adapter, Python UDFs (`CREATE_QDRANT_COLLECTION`, `EMBED_AND_PUSH`), and virtual schema. Users update 5 config values (host IP, ports, model, schema name) and execute.

**Individual components:**
- `scripts/install_adapter.sql` — Lua adapter script only
- `scripts/create_udfs_ollama.sql` — Python UDFs only

## Infrastructure

- **Exasol 7.x+** (typically Docker for dev)
- **Qdrant 1.9+** on port 6333
- **Ollama** on port 11434 with `nomic-embed-text` model (768 dimensions)
- Docker bridge gateway IP (usually `172.17.0.1`) used for container-to-container communication — `host.docker.internal` does not work in Exasol's UDF sandbox on Linux

## OpenSpec

The project uses an OpenSpec workflow for spec-driven changes. Specs and change proposals live in `openspec/`. The Lua port spec is at `openspec/specs/lua-port/specs.md`.
