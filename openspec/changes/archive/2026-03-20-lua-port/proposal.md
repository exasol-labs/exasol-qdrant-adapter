## Why

The Java Virtual Schema adapter requires a Maven build, BucketFS JAR upload, and incurs JVM cold-start latency on every call. Replacing it with a Lua adapter eliminates the build and deployment friction — the adapter becomes a single `.lua` file installed via one SQL statement, with millisecond startup.

## What Changes

- **BREAKING** Remove `src/main/java/` Java adapter source and `pom.xml`
- **BREAKING** Remove BucketFS-based deployment (no more JAR upload)
- Add `src/lua/` with the full Lua Virtual Schema adapter (`entry.lua`, `adapter/`, `util/`)
- Add `build/amalg.lua` packaging script using `lua-amalg`
- Add `dist/adapter.lua` — single-file zero-dependency artifact for deployment
- Update `README.md` deployment section to reflect `CREATE LUA ADAPTER SCRIPT` install path
- Add `docs/lua-port/limitations.md` documenting accepted Lua runtime constraints
- Python UDFs (`EMBED_AND_PUSH`, `CREATE_QDRANT_COLLECTION`) remain untouched

## Capabilities

### New Capabilities
- `lua-adapter-core`: Lua entrypoint, dispatcher wiring, and full request lifecycle (createVirtualSchema, refresh, setProperties, pushDown) via `virtual-schema-common-lua`
- `lua-metadata-reader`: HTTP GET to Qdrant `/collections` returning virtual schema table metadata
- `lua-query-rewriter`: Embed query via Ollama REST API, vector search via Qdrant REST API, return VALUES SQL or empty-result SQL
- `lua-adapter-properties`: Property constants, validation, and merge semantics for `CONNECTION_NAME`, `QDRANT_MODEL`, `OLLAMA_URL`, `QDRANT_URL`
- `lua-packaging`: `lua-amalg`-based build producing `dist/adapter.lua` as a single deployable file

### Modified Capabilities
- `virtual-schema-config`: Deployment instructions change from BucketFS JAR to `CREATE LUA ADAPTER SCRIPT` with inline script body

## Impact

- **New files:** `src/lua/entry.lua`, `src/lua/adapter/QdrantAdapter.lua`, `src/lua/adapter/AdapterProperties.lua`, `src/lua/adapter/capabilities.lua`, `src/lua/adapter/MetadataReader.lua`, `src/lua/adapter/QueryRewriter.lua`, `src/lua/util/http.lua`, `build/amalg.lua`, `dist/adapter.lua`, `docs/lua-port/limitations.md`
- **Modified files:** `README.md`
- **Deleted:** `src/main/java/`, `pom.xml`
- **Retained:** `exasol_udfs/`, `tests/`, `scripts/`
- **New dev dependencies:** `virtual-schema-common-lua` (LuaRocks), `remotelog` (LuaRocks), `lua-amalg`
- **Runtime:** no new dependencies — uses Exasol's bundled `socket.http` and `cjson`
