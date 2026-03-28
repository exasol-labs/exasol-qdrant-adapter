## 1. Remove Java Adapter

- [x] 1.1 Delete `src/main/java/` directory and all Java source files
- [x] 1.2 Delete `pom.xml`
- [x] 1.3 Remove any Maven-related CI configuration referencing the JAR build

## 2. HTTP Utility Layer

- [x] 2.1 Create `src/lua/util/http.lua` with a JSON GET helper using `socket.http`
- [x] 2.2 Add JSON POST helper to `src/lua/util/http.lua` with `Content-Type: application/json` header
- [x] 2.3 Handle HTTP response body aggregation (sink pattern for LuaSocket)

## 3. Adapter Properties

- [x] 3.1 Create `src/lua/adapter/AdapterProperties.lua` with constants for `CONNECTION_NAME`, `QDRANT_MODEL`, `OLLAMA_URL`, `QDRANT_URL`
- [x] 3.2 Implement `validate()` that raises actionable errors for missing required properties
- [x] 3.3 Implement merge semantics: new properties override old, empty string unsets
- [x] 3.4 Implement `get_qdrant_url()` to derive URL from CONNECTION object when `QDRANT_URL` not set
- [x] 3.5 Implement `get_ollama_url()` with default `http://localhost:11434`

## 4. Capabilities

- [x] 4.1 Create `src/lua/adapter/capabilities.lua` listing `SELECTLIST_EXPRESSIONS`, `FILTER_EXPRESSIONS`, `LIMIT`, `LIMIT_WITH_OFFSET`, predicate `EQUAL`, literal `STRING`
- [x] 4.2 Implement `with_exclusions(properties)` to honour `EXCLUDED_CAPABILITIES` property

## 5. Metadata Reader

- [x] 5.1 Create `src/lua/adapter/MetadataReader.lua`
- [x] 5.2 Implement HTTP GET to `{qdrant_url}/collections` with optional `api-key` header
- [x] 5.3 Parse response `result.collections[*].name` into table descriptors
- [x] 5.4 Return column list: ID VARCHAR(2000000), TEXT VARCHAR(2000000), SCORE DOUBLE, QUERY VARCHAR(2000000) for each collection

## 6. Query Rewriter

- [x] 6.1 Create `src/lua/adapter/QueryRewriter.lua`
- [x] 6.2 Implement Ollama embedding call: POST to `{ollama_url}/api/embeddings` with model and prompt
- [x] 6.3 Implement Qdrant vector search: POST to `{qdrant_url}/collections/{collection}/points/search` with named vector, limit, `with_payload: true`, optional `api-key` header
- [x] 6.4 Implement VALUES SQL builder for non-empty results with correct CAST expressions
- [x] 6.5 Implement empty-result SQL for zero Qdrant results
- [x] 6.6 Extract query text from pushDown filter expression (`EQUAL` predicate on `QUERY` column)

## 7. Qdrant Adapter

- [x] 7.1 Create `src/lua/adapter/QdrantAdapter.lua` inheriting `AbstractVirtualSchemaAdapter`
- [x] 7.2 Implement `create_virtual_schema`: validate properties, call MetadataReader, return schema metadata
- [x] 7.3 Implement `refresh`: validate properties, call MetadataReader, return updated schema metadata
- [x] 7.4 Implement `set_properties`: merge properties, validate, re-read metadata, return updated schema metadata
- [x] 7.5 Implement `push_down`: validate properties, delegate to QueryRewriter, return rewritten SQL
- [x] 7.6 Implement `get_capabilities`: return capabilities with exclusions

## 8. Entrypoint

- [x] 8.1 Create `src/lua/entry.lua` that defines global `adapter_call(request_json)`
- [x] 8.2 Wire `QdrantAdapter`, `AdapterProperties`, and `RequestDispatcher` in `entry.lua`
- [x] 8.3 Confirm no business logic exists in `entry.lua`

## 9. Packaging

- [x] 9.1 Install `lua-amalg` (LuaRocks or standalone) — manual step: `luarocks install amalg && luarocks install virtual-schema-common-lua`
- [x] 9.2 Create `build/amalg.lua` script that invokes `lua-amalg` with `src/lua/entry.lua` as entrypoint
- [x] 9.3 Run build script and verify `dist/adapter.lua` is produced — manual step: `lua build/amalg.lua`
- [x] 9.4 Verify `dist/adapter.lua` defines `adapter_call` globally and has no unresolved `require()` calls — manual step after 9.3

## 10. Documentation

- [x] 10.1 Update `README.md` deployment section: replace BucketFS/JAR instructions with `CREATE LUA ADAPTER SCRIPT` one-statement install
- [x] 10.2 Add dev setup instructions to README (installing `lua-amalg`, running the build)
- [x] 10.3 Confirm `docs/lua-port/limitations.md` is present and up to date
