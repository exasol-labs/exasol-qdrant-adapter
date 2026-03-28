## Context

The adapter currently ships as a Java Virtual Schema JAR deployed via Exasol BucketFS. The Java implementation wraps three HTTP calls (Qdrant collection listing, Ollama embedding, Qdrant vector search) with significant build and deployment overhead. The Lua runtime already bundled in Exasol (`socket.http`, `cjson`, `ssl`) is sufficient to make all three calls. The `virtual-schema-common-lua` framework provides the request dispatcher, abstract adapter base class, and logging infrastructure needed to build a compliant Virtual Schema without reimplementing the protocol.

## Goals / Non-Goals

**Goals:**
- Replace the Java adapter entirely with a Lua adapter that is functionally equivalent
- Produce a single-file `dist/adapter.lua` deployable via one SQL statement
- Follow `virtual-schema-common-lua` conventions exactly (RequestDispatcher, AbstractVirtualSchemaAdapter)
- Delete the Java source tree and Maven build

**Non-Goals:**
- Supporting self-signed or private CA TLS (accepted limitation, documented in `docs/lua-port/limitations.md`)
- Porting the Python UDFs (`EMBED_AND_PUSH`, `CREATE_QDRANT_COLLECTION`)
- Adding new adapter capabilities beyond the current Java adapter's capability set

## Decisions

### D1: Use `virtual-schema-common-lua` framework (not hand-rolled)
`virtual-schema-common-lua` provides `RequestDispatcher`, `AbstractVirtualSchemaAdapter`, and `remotelog` integration. Hand-rolling the JSON protocol or request routing would be non-standard and fragile.
**Alternatives considered:** Hand-rolled dispatcher — rejected, duplicates framework work and bypasses dispatcher-level error handling and logging.

### D2: Module layout mirrors canonical Exasol Lua adapters
```
src/lua/
  entry.lua
  adapter/
    QdrantAdapter.lua
    AdapterProperties.lua
    capabilities.lua
    MetadataReader.lua
    QueryRewriter.lua
  util/
    http.lua
dist/
  adapter.lua          ← lua-amalg output
build/
  amalg.lua
```
`entry.lua` is the thin global entrypoint. All logic lives in `adapter/` and `util/`. This matches `exasol-virtual-schema-lua` and `databricks-virtual-schema` structure.

### D3: HTTP via `socket.http` (bundled LuaSocket), JSON via `cjson` (bundled)
No additional runtime dependencies. `util/http.lua` wraps LuaSocket with a minimal GET/POST helper that sets `Content-Type: application/json` and handles response body aggregation.
**Alternatives considered:** `lua-requests` — not bundled, would require vendoring. Rejected for simplicity.

### D4: Packaging via `lua-amalg`
`lua-amalg` concatenates all `require()`d modules into a single file. This is the standard pattern for Exasol Lua adapters. The output `dist/adapter.lua` has no `require()` calls at install time.
**Alternatives considered:** Manual concatenation — error-prone, no dependency graph resolution. Rejected.

### D5: QueryRewriter returns VALUES SQL (not IMPORT)
Qdrant search results are small (default limit ≤ 1000 rows) and returned as a JSON payload. Inlining results as a `VALUES` clause is the correct approach for this pattern — it avoids needing an IMPORT source. The Java adapter uses the same approach.

### D6: Java adapter and `pom.xml` are deleted
The Java adapter is fully replaced. No parallel maintenance. Users needing custom TLS must maintain their own fork.

## Risks / Trade-offs

- **TLS limitation** → No mitigation within this project. Documented in `docs/lua-port/limitations.md`. Users with self-signed endpoints must fork.
- **lua-amalg availability** → Must be installed as a dev dependency. Document in README dev setup section. Risk is low — it's a standard LuaRocks package.
- **Framework API changes in `virtual-schema-common-lua`** → Pin the LuaRocks version in `build/amalg.lua` and document the pinned version.
- **Exasol Lua runtime changes** → `socket.http` and `cjson` are part of the official Exasol Lua UDF spec. Breaking changes would require Exasol version pinning.

## Migration Plan

1. Delete `src/main/java/` and `pom.xml`
2. Implement `src/lua/` modules in dependency order: `util/http.lua` → `AdapterProperties.lua` → `capabilities.lua` → `MetadataReader.lua` → `QueryRewriter.lua` → `QdrantAdapter.lua` → `entry.lua`
3. Run `lua-amalg` to produce `dist/adapter.lua`
4. Update `README.md` deployment section
5. Validate with `CREATE OR REPLACE LUA ADAPTER SCRIPT` + `CREATE VIRTUAL SCHEMA` + a test `SELECT`

**Rollback:** Git history retains the Java adapter source. Any deployment currently using the JAR continues to work until explicitly migrated to the Lua adapter.

## Open Questions

- None — all design decisions are resolved. TLS trade-off is accepted.
