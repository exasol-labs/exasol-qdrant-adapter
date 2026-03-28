# Lua Port Specification — Exasol Qdrant Vector Search Adapter

**Status:** Planned
**Goal:** Replace the Java Virtual Schema adapter with a Lua adapter to eliminate BucketFS dependency and reduce startup latency.
**Skill reference:** `docs/lua-port/SKILL.md`

---

## Why Port to Lua

The current adapter is a Java Virtual Schema JAR deployed via BucketFS. This works but creates friction:

| Problem today | After Lua port |
|---|---|
| Must build a fat JAR with Maven | No build step — just a `.lua` text file |
| Must upload JAR to BucketFS | Paste script directly into `CREATE LUA ADAPTER SCRIPT` |
| JVM cold-start on each adapter call | Lua starts in milliseconds |
| Complex deployment (Docker copy / curl upload) | One SQL statement |

The Virtual Schema adapter itself only does three things — all plain HTTP:
1. Call Qdrant REST API to list collections (metadata)
2. Call Ollama REST API to embed a query string
3. Call Qdrant REST API to run a vector similarity search

All three are doable in Lua using `socket.http` (LuaSocket) and `cjson`, both bundled in Exasol's Lua runtime.

---

## Scope

### In scope
- Port `VectorSchemaAdapter.java` → `QdrantAdapter.lua`
- Port `AdapterProperties.java` → `AdapterProperties.lua`
- Port `QdrantClient.java` (collection listing + vector search) → `MetadataReader.lua` + `QueryRewriter.lua`
- Port `OllamaEmbeddingClient.java` → inline HTTP call in `QueryRewriter.lua`
- Packaging via `lua-amalg` → single `dist/adapter.lua`
- Update README deployment section

### Out of scope
- The `EMBED_AND_PUSH` UDF (Python, stays as-is)
- The `CREATE_QDRANT_COLLECTION` UDF (Python, stays as-is)
- InsertHandler / CreateCollectionHandler (not used in the virtual schema path)

---

## Tradeoffs & Constraints

### TLS limitation (critical)
Lua adapters cannot load custom CA certificates (no filesystem access).

- ✅ Works: plain HTTP to Qdrant and Ollama (current Docker setup)
- ✅ Works: Qdrant Cloud with public CA–signed HTTPS
- ❌ Breaks: self-signed TLS on Qdrant/Ollama

**Decision:** Keep the Java adapter in the repo as a fallback for users who need custom TLS. Lua adapter becomes the default for the standard Docker deployment.

### No persistence, no state
Lua adapters are stateless per call. All configuration comes from adapter properties and the CONNECTION object — same as the current Java adapter.

### Capabilities to advertise (conservative, match current Java adapter)
- `SELECTLIST_EXPRESSIONS`
- `FILTER_EXPRESSIONS`
- `LIMIT`
- `LIMIT_WITH_OFFSET`
- Predicate: `EQUAL`
- Literal: `STRING`

---

## Target File Structure

```
src/lua/
  entry.lua                     ← thin entrypoint, defines adapter_call()
  adapter/
    QdrantAdapter.lua           ← inherits AbstractVirtualSchemaAdapter
    AdapterProperties.lua       ← CONNECTION_NAME, QDRANT_MODEL, OLLAMA_URL validation
    capabilities.lua            ← capability list
    MetadataReader.lua          ← HTTP GET /collections → TableMetadata list
    QueryRewriter.lua           ← embed via Ollama → search Qdrant → VALUES SQL
  util/
    http.lua                    ← LuaSocket HTTP wrapper (GET/POST with JSON body)
dist/
  adapter.lua                   ← lua-amalg single-file output (what gets deployed)
```

---

## Adapter Properties (unchanged from Java)

| Property | Required | Default | Description |
|---|---|---|---|
| `CONNECTION_NAME` | Yes | — | Exasol CONNECTION object with Qdrant base URL |
| `QDRANT_MODEL` | Yes | — | Ollama model name for embeddings |
| `OLLAMA_URL` | No | `http://localhost:11434` | Ollama base URL reachable from Exasol |
| `QDRANT_URL` | No | — | Override Qdrant URL (ignores CONNECTION address) |

---

## HTTP calls the Lua adapter must make

### 1. List Qdrant collections (MetadataReader)
```
GET {qdrant_url}/collections
Headers: api-key: {api_key}   (if set)
Response: { "result": { "collections": [ { "name": "..." }, ... ] } }
```

### 2. Embed query text (QueryRewriter — Ollama)
```
POST {ollama_url}/api/embeddings
Body: { "model": "{qdrant_model}", "prompt": "{query_text}" }
Response: { "embedding": [ 0.1, 0.2, ... ] }
```

### 3. Vector search (QueryRewriter — Qdrant)
```
POST {qdrant_url}/collections/{collection}/points/search
Headers: api-key: {api_key}   (if set)
Body: {
  "vector": { "name": "text", "vector": [ ... ] },
  "limit": N,
  "with_payload": true
}
Response: {
  "result": [
    { "id": "...", "score": 0.92, "payload": { "_original_id": "...", "text": "..." } },
    ...
  ]
}
```

---

## Push-down SQL output (unchanged from Java)

On results:
```sql
SELECT * FROM VALUES
  (CAST('id1' AS VARCHAR(2000000) UTF8), CAST('text...' AS VARCHAR(2000000) UTF8), CAST(0.92 AS DOUBLE), CAST('query' AS VARCHAR(2000000) UTF8)),
  ...
AS t(ID, TEXT, SCORE, QUERY)
```

On empty results:
```sql
SELECT CAST('' AS VARCHAR(36) UTF8) AS ID,
       CAST('' AS VARCHAR(2000000) UTF8) AS TEXT,
       CAST(0 AS DOUBLE) AS SCORE,
       CAST('' AS VARCHAR(2000000) UTF8) AS QUERY
FROM DUAL WHERE FALSE
```

---

## Deployment (target experience)

```sql
-- 1. Create connection (same as today)
CREATE OR REPLACE CONNECTION qdrant_conn
  TO 'http://172.17.0.1:6333'
  USER '' IDENTIFIED BY '';

-- 2. Install adapter (no BucketFS, no JAR, no Maven)
CREATE OR REPLACE LUA ADAPTER SCRIPT ADAPTER.VECTOR_SCHEMA_ADAPTER AS
  -- paste contents of dist/adapter.lua here
/

-- 3. Create virtual schema (same as today)
CREATE VIRTUAL SCHEMA vector_schema
  USING ADAPTER.VECTOR_SCHEMA_ADAPTER
  WITH CONNECTION_NAME = 'qdrant_conn'
       QDRANT_MODEL    = 'nomic-embed-text'
       OLLAMA_URL      = 'http://172.17.0.1:11434';
```

---

## Implementation Tasks

- [ ] `util/http.lua` — LuaSocket wrapper for JSON GET/POST
- [ ] `adapter/AdapterProperties.lua` — property constants + validation + merge semantics
- [ ] `adapter/capabilities.lua` — capability list matching current Java adapter
- [ ] `adapter/MetadataReader.lua` — calls Qdrant `/collections`, returns table metadata
- [ ] `adapter/QueryRewriter.lua` — embeds via Ollama, searches Qdrant, builds VALUES SQL
- [ ] `adapter/QdrantAdapter.lua` — inherits `AbstractVirtualSchemaAdapter`, wires all modules
- [ ] `entry.lua` — thin entrypoint, delegates to dispatcher
- [ ] `build/` — lua-amalg packaging script producing `dist/adapter.lua`
- [ ] Update `README.md` — replace BucketFS/JAR deployment with Lua script deployment
- [ ] Add `docs/lua-port/limitations.md` — document TLS caveat clearly

---

## Notes for the next session

- The Java adapter source remains in `src/main/java/` — do not delete it
- The Lua adapter goes in `src/lua/` (new directory)
- Start with `util/http.lua` and `adapter/AdapterProperties.lua` — these have no dependencies
- Framework: `virtual-schema-common-lua` via LuaRocks — study `AbstractVirtualSchemaAdapter` interface before writing `QdrantAdapter.lua`
- Logging: use `remotelog-lua` (bundled with `virtual-schema-common-lua`) — never use `print()`
- Bundle everything with `lua-amalg` before testing — Exasol cannot resolve `require()` at runtime
