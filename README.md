<p align="center">
  <img src="assets/exasol-qdrant-banner.png" alt="Exasol Qdrant Adapter — Semantic similarity search in pure SQL" />
</p>

# Exasol Qdrant Vector Search Adapter

A Virtual Schema adapter that brings semantic similarity search into Exasol SQL using [Qdrant](https://qdrant.tech/) as the vector store and an in-database `sentence-transformers` UDF for text embeddings — no external embedding service required.

```sql
-- Find the most semantically similar documents — pure SQL
SELECT "ID", "TEXT", "SCORE"
FROM vector_schema.articles
WHERE "QUERY" = 'artificial intelligence'
LIMIT 5;
```

## How It Works

```
Exasol SQL query
      ↓
Virtual Schema Adapter (Lua, runs inside Exasol — no JAR)
      ↓
ADAPTER.SEARCH_QDRANT_LOCAL SET UDF (in-database, sentence-transformers + nomic-embed-text-v1.5)
      ↓
Qdrant (hybrid search: vector similarity + keyword matching via RRF)
      ↓
Ranked results back to Exasol
```

- **In-database embeddings** — both the query path and the ingest path call `sentence-transformers` inside Exasol's UDF VM. No Ollama, no out-of-database embedding service.
- **Hybrid search** — combines vector similarity with keyword matching using Qdrant's Reciprocal Rank Fusion (RRF), so entity-specific queries like "acquired by JP Morgan" surface exact matches alongside semantically similar results.
- No pre-computed embeddings needed — `ADAPTER.SEARCH_QDRANT_LOCAL` embeds and searches at query time inside the UDF VM (~50–150 ms after the first call).
- Results are ranked by fused similarity score (higher = more relevant).
- Single bundled SLC + model in BucketFS — one upload, used by every query and every ingest.

> **Migrating from earlier versions?** If you previously deployed this adapter with `OLLAMA_URL` or `EMBED_AND_PUSH` / `EMBED_AND_PUSH_V2`, see the migration steps in [`docs/local-embeddings.md`](docs/local-embeddings.md#migration-from-ollama). Short version: drop the virtual schema, re-run `scripts/install_all.sql`, re-ingest into a fresh collection via `EMBED_AND_PUSH_LOCAL`, and `docker rm -f ollama`.

---

## Prerequisites

| Component | Version | Notes                                |
| --------- | ------- | ------------------------------------ |
| Exasol    | 7.x+    | Docker or on-premise                 |
| Qdrant    | 1.7+    | Docker recommended (1.7+ required for hybrid search) |
| SLC + model | once  | Build and upload via `./scripts/build_and_upload_slc.sh` (one-time) |

The SLC ships `sentence-transformers` and `nomic-embed-text-v1.5` (768-dim cosine). Both `EMBED_TEXT` (query) and `EMBED_AND_PUSH_LOCAL` (ingest) load it at module-import time inside the UDF VM.

**Dev-only** (only needed to rebuild `dist/adapter.lua` after source changes):

| Tool                      | Install                                      |
| ------------------------- | -------------------------------------------- |
| Lua 5.4                   | `brew install lua` / apt                     |
| lua-amalg                 | `luarocks install amalg`                     |
| virtual-schema-common-lua | `luarocks install virtual-schema-common-lua` |

---

## Quick Start (Docker)

### 1. Start Exasol

```bash
docker run --name exasoldb -p 127.0.0.1:9563:8563 --detach --privileged --stop-timeout 120  exasol/docker-db:latest
```

Exasol takes about 90 seconds to initialize. Wait before connecting.
Default credentials: `host=localhost, port=8563, user=sys, password=exasol`.

### 2. Start Qdrant

```bash
docker run -d --name qdrant -p 6333:6333 qdrant/qdrant
```

### 3. Build and upload the SLC + model (one time)

```bash
./scripts/build_and_upload_slc.sh
```

Builds the `qdrant-embed` SLC and uploads it plus the `nomic-embed-text-v1.5` model tarball to Exasol's BucketFS. See [`docs/local-embeddings.md`](docs/local-embeddings.md) for build prerequisites and tuning.

### 4. Install everything in Exasol (one file)

Open [`scripts/install_all.sql`](scripts/install_all.sql) in your SQL client (DBeaver, DbVisualizer, etc.). Update the IPs in the `STEP 2` and `STEP 9` sections if needed, then run the entire file.

> **SQL client setup:** This file uses `/` (forward slash on its own line) as the
> statement separator — not `;`. Configure your SQL client accordingly:
>
> - **DBeaver:** Open the file, then use _SQL Editor → Execute SQL Script_ (Alt+X).
>   If it fails, go to _Window → Preferences → SQL Editor_ and set the
>   "Script statement delimiter" to `/`.
> - **DbVisualizer:** The `/` delimiter is supported by default when using
>   "Execute as Script."
> - **exaplus (CLI):** Run with `exaplus -f install_all.sql` — it handles `/` natively.

It deploys:

- Schema, two CONNECTION objects (`qdrant_conn`, `embedding_conn`), Lua adapter script
- Python UDFs: `CREATE_QDRANT_COLLECTION`, `EMBED_AND_PUSH_LOCAL`, `EMBED_TEXT`, `SEARCH_QDRANT_LOCAL`, `PREFLIGHT_CHECK`
- Virtual schema ready for queries

```bash
# Default config values (change if your setup differs):
#   Qdrant:  http://172.17.0.1:6333
#   Model:   nomic-embed-text-v1.5  (loaded from BucketFS, no Ollama)
#   Schema:  ADAPTER
```

> **No JAR, no Maven, no separate embedding service.** The SLC + model live in BucketFS once; everything else is a single SQL file.

> **Docker networking note:** `host.docker.internal` does not resolve inside Exasol's UDF sandbox on Linux. Use the Docker bridge gateway IP (typically `172.17.0.1`) for the Qdrant URL. Find it with:
>
> ```bash
> docker exec exasoldb ip route show default
> # --> default via 172.17.0.1 dev eth0
> # Use 172.17.0.1 for qdrant_url
> ```

---

## Step 5: Verify the Installation

> **Always run this example first** before loading your own data. If this works,
> your entire stack (Exasol, Qdrant, adapter, UDFs, virtual schema) is correctly
> deployed.

After running `install_all.sql`, try this complete example to see semantic search working in under a minute. It creates a small sample table, ingests it into Qdrant via the in-database SLC UDF, and queries it.

```sql
-- 1. Create a sample table with 5 documents
CREATE OR REPLACE TABLE ADAPTER.hello_world (
    id DECIMAL(5,0),
    doc VARCHAR(200)
);
INSERT INTO ADAPTER.hello_world VALUES (1, 'The quick brown fox jumps over the lazy dog');
INSERT INTO ADAPTER.hello_world VALUES (2, 'A fast red car drives down the highway at night');
INSERT INTO ADAPTER.hello_world VALUES (3, 'Machine learning models predict stock market trends');
INSERT INTO ADAPTER.hello_world VALUES (4, 'The chef prepared a delicious pasta with fresh tomatoes');
INSERT INTO ADAPTER.hello_world VALUES (5, 'Neural networks are inspired by biological brain structures');

-- 2. Create a Qdrant collection for the sample data
SELECT ADAPTER.CREATE_QDRANT_COLLECTION(
    '172.17.0.1', 6333, '', 'hello_world', 768, 'Cosine', ''
);

-- 3. Embed and push the documents (in-process via SLC, CONNECTION-driven)
SELECT ADAPTER.EMBED_AND_PUSH_LOCAL(
    'embedding_conn',
    'hello_world',
    CAST(ID AS VARCHAR(36)),
    DOC
)
FROM ADAPTER.hello_world
GROUP BY IPROC();

-- 4. Refresh the virtual schema to see the new collection
ALTER VIRTUAL SCHEMA vector_schema REFRESH;

-- 5. Search! Find documents about AI / machine learning
SELECT "ID", "TEXT", "SCORE"
FROM vector_schema.hello_world
WHERE "QUERY" = 'artificial intelligence'
LIMIT 5;
-- Expected: "Neural networks..." and "Machine learning..." rank highest

-- 6. Try another search
SELECT "ID", "TEXT", "SCORE"
FROM vector_schema.hello_world
WHERE "QUERY" = 'animals running fast'
LIMIT 5;
-- Expected: "The quick brown fox..." ranks highest
```

> **Timing:** First call after a UDF VM restart pays a 3–8 s model load from BucketFS.
> Subsequent calls in the same VM run at ~50–150 ms per encode. Ingest of 544 rows
> via `EMBED_AND_PUSH_LOCAL` typically completes in 60–90 s on a single-VM dev box.

> **Tip:** To ingest your own Exasol table, replace the placeholders below:
>
> ```sql
> -- 1. Create a collection for your data
> SELECT ADAPTER.CREATE_QDRANT_COLLECTION(
>     '172.17.0.1', 6333, '', 'my_collection', 768, 'Cosine', ''
> );
>
> -- 2. Embed and push rows from your table (in-process)
> SELECT ADAPTER.EMBED_AND_PUSH_LOCAL(
>     'embedding_conn',
>     'my_collection',
>     CAST(id_column AS VARCHAR(36)),
>     text_column
> )
> FROM MY_SCHEMA.MY_TABLE
> GROUP BY IPROC();
>
> -- 3. Refresh and query
> ALTER VIRTUAL SCHEMA vector_schema REFRESH;
> SELECT "ID", "TEXT", "SCORE"
> FROM vector_schema.my_collection
> WHERE "QUERY" = 'your search query'
> LIMIT 5;
> ```

---

## Loading Data

There are two ways to get data into Qdrant so you can query it via the virtual schema:

### Option A — Ingestion via `EMBED_AND_PUSH_LOCAL` (recommended)

If your source data already lives in Exasol tables, use the `EMBED_AND_PUSH_LOCAL` SET UDF to embed rows in-process via the BucketFS-resident SLC + model and push them to Qdrant — all without leaving SQL.

```sql
-- 1. The CONNECTION created by install_all.sql holds the Qdrant URL.
--    The address field is a JSON config blob. Reuse or recreate as needed:
CREATE OR REPLACE CONNECTION embedding_conn
    TO '{"qdrant_url":"http://172.17.0.1:6333","qdrant_api_key":""}'
    USER ''
    IDENTIFIED BY '';

-- 2. Create the Qdrant collection (768 dimensions for nomic-embed-text-v1.5)
SELECT ADAPTER.CREATE_QDRANT_COLLECTION(
    '172.17.0.1', 6333, '', 'my_collection', 768, 'Cosine', ''
);

-- 3. Embed and push — 4 parameters, same shape for every ingest
SELECT ADAPTER.EMBED_AND_PUSH_LOCAL(
    'embedding_conn',                   -- connection name
    'my_collection',                    -- Qdrant collection
    CAST(id_col AS VARCHAR(255)),       -- unique ID
    text_col                            -- text to embed
)
FROM MY_SCHEMA.MY_TABLE
GROUP BY IPROC();  -- REQUIRED for SET UDFs — fans work across cluster nodes

-- 4. Search
ALTER VIRTUAL SCHEMA vector_schema REFRESH;
SELECT "ID", "TEXT", "SCORE"
FROM vector_schema.my_collection
WHERE "QUERY" = 'your search query here'
LIMIT 10;
```

See [`docs/local-embeddings.md`](docs/local-embeddings.md) for SLC build details, sizing rules, and multi-node scaling notes. The full ingest UDF reference (parameters, error handling, examples) is in [`docs/udf-ingestion.md`](docs/udf-ingestion.md).

### Option B — Direct HTTP ingestion (no Exasol UDFs)

Since Exasol virtual schemas are read-only, data can also be inserted directly into Qdrant via its REST API. The adapter handles query-time embedding automatically via the in-database `SEARCH_QDRANT_LOCAL` UDF — you just need to put 768-dim normalized vectors into Qdrant.

You'll need to compute embeddings yourself (matching `nomic-embed-text-v1.5`, normalized) using a Python script, the `sentence-transformers` library, or any compatible inference service — and then PUT them to Qdrant's `/points` endpoint.

**Minimal Python example:**

```python
from sentence_transformers import SentenceTransformer
import json, urllib.request, uuid

model = SentenceTransformer("nomic-ai/nomic-embed-text-v1.5", trust_remote_code=True)
text = "Machine learning is a subset of AI"
vec = model.encode(text, normalize_embeddings=True).tolist()

# Create the collection (one-time)
urllib.request.Request("http://localhost:6333/collections/articles",
    method="PUT", data=json.dumps({"vectors":{"text":{"size":768,"distance":"Cosine"}}}).encode(),
    headers={"Content-Type":"application/json"})

# Upsert one point
body = json.dumps({"points":[{
    "id": str(uuid.uuid4()),
    "vector": {"text": vec},
    "payload": {"_original_id": "doc-1", "text": text}
}]}).encode()
urllib.request.urlopen(urllib.request.Request(
    "http://localhost:6333/collections/articles/points",
    method="PUT", data=body, headers={"Content-Type":"application/json"}))
```

After upsert, run `ALTER VIRTUAL SCHEMA vector_schema REFRESH` in Exasol and the new collection appears as a virtual table.

---

## Local Embeddings via SLC + BucketFS

`EMBED_AND_PUSH_LOCAL` and `EMBED_TEXT` both run `sentence-transformers` directly inside the UDF VM, sharing one BucketFS-resident `nomic-embed-text-v1.5` model copy per node. Per-node parallelism via `GROUP BY IPROC()` scales linearly across an Exasol cluster.

Setup is a one-time SLC build + BucketFS upload (Linux Docker host required). Full guide in [`docs/local-embeddings.md`](docs/local-embeddings.md).

---

## Refresh Virtual Schema

```sql
ALTER VIRTUAL SCHEMA vector_schema REFRESH;
```

## Pre-Flight Health Check

Before creating the virtual schema or ingesting data, verify that Qdrant is reachable and the in-database embedding model is loadable from BucketFS:

```sql
SELECT ADAPTER.PREFLIGHT_CHECK('http://172.17.0.1:6333');
```

Returns a structured report:

```
=== PREFLIGHT CHECK: ALL CHECKS PASSED ===
[PASS] Qdrant: reachable, 2 collection(s): articles, products
[PASS] Embedding round-trip: 768-dim vector from nomic-embed-text-v1.5
```

If any check fails, the report includes troubleshooting steps (Docker bridge IP, SLC install command).

---

## Querying

After refreshing the virtual schema, each Qdrant collection appears as a table.

```sql
-- Semantic similarity search
SELECT "ID", "TEXT", "SCORE"
FROM vector_schema.articles
WHERE "QUERY" = 'artificial intelligence'
LIMIT 5;

-- Join with other Exasol tables
SELECT s."ID", s."SCORE", m.author
FROM (
    SELECT "ID", "SCORE"
    FROM vector_schema.articles
    WHERE "QUERY" = 'machine learning'
    LIMIT 10
) s
JOIN my_schema.metadata m ON s."ID" = m.doc_id
ORDER BY s."SCORE" DESC;
```

**Table columns:**

| Column  | Type    | Description                                    |
| ------- | ------- | ---------------------------------------------- |
| `ID`    | VARCHAR | Original document ID as inserted               |
| `TEXT`  | VARCHAR | Original document text                         |
| `SCORE` | DOUBLE  | Relevance score (higher = more relevant). With hybrid search, this is an RRF fusion score; with pure vector search, it is cosine similarity (0–1) |
| `QUERY` | VARCHAR | The query string echoed back                   |

> **Accessing additional metadata:** The virtual schema returns a fixed 4-column schema. To access additional fields from your source data, JOIN the search results with your original table using the ID column:
>
> ```sql
> SELECT s."TEXT", s."SCORE", m.category, m.author
> FROM vector_schema.my_collection s
> JOIN MY_SCHEMA.MY_TABLE m ON s."ID" = CAST(m.id_column AS VARCHAR(36))
> WHERE s."QUERY" = 'your search query'
> LIMIT 5;
> ```

> Always quote column names with double quotes (`"QUERY"`) to avoid conflicts with Exasol reserved keywords.
>
> **Default limit:** When no `LIMIT` clause is specified, results are capped at **10 rows**. Always include an explicit `LIMIT` to control how many results you get back.

> **Empty query handling:** Running `SELECT * FROM vector_schema.collection` without a `WHERE "QUERY" = '...'` clause returns a single hint row with usage instructions instead of crashing. Always include a WHERE clause for actual searches.

> **SCORE filtering:** You can filter by relevance score using standard SQL. Exasol applies SCORE filters after the vector search:
>
> ```sql
> SELECT "ID", "TEXT", "SCORE" FROM vector_schema.my_collection
> WHERE "QUERY" = 'your search query' AND "SCORE" > 0.6 LIMIT 5;
> ```

### Hybrid Search

The adapter automatically combines vector similarity with keyword matching using Qdrant's [Reciprocal Rank Fusion (RRF)](https://qdrant.tech/documentation/concepts/hybrid-queries/). This significantly improves results for queries that reference specific names, places, or terms.

**How it works:**

1. Your query text is tokenized into keywords (stopwords like "the", "is", "in" are removed)
2. Adjacent keywords are also combined into compound tokens (e.g., "JP" + "Morgan" also generates "jpmorgan") to match concatenated terms in source data
3. The adapter sends multiple search legs to Qdrant in a single request:
   - One **vector-only leg** (broad semantic search)
   - One **keyword-filtered leg per keyword** (vector search narrowed to documents containing that keyword)
4. Qdrant merges all legs using RRF, which naturally weights rare keywords higher than common ones

**What this means in practice:**

- **Entity-specific queries work** -- searching for "banks acquired by JP Morgan" surfaces results containing "JPMorgan" and "J.P. Morgan", not just generically similar text
- **No configuration needed** -- hybrid search is the default behavior for all queries
- **Graceful fallback** -- if the query contains only stopwords (e.g., "what is the"), the adapter falls back to pure vector search
- **No performance penalty** -- all search legs execute in a single Qdrant API call

**Requirements:**

- **Qdrant 1.7+** (for text payload indexes and the prefetch/fusion query API)
- A **text payload index** on the `text` field in each Qdrant collection

Collections created via `CREATE_QDRANT_COLLECTION` (v2.2.0+) include the text index automatically. If you created collections via direct HTTP (Option B above), include the index creation step in your script.

**Upgrading older collections:** If you have collections created before v2.2.0, add the text index manually (the adapter still works without it, but falls back to pure vector search):

```bash
curl -X PUT 'http://localhost:6333/collections/<name>/index' \
  -H 'Content-Type: application/json' \
  -d '{"field_name":"text","field_schema":{"type":"text","tokenizer":"word","min_token_len":2,"max_token_len":40,"lowercase":true}}'
```

> **Note:** Creating the index on an existing collection is safe and non-destructive. Qdrant indexes the data asynchronously in the background.

### Performance Note

After the first call in a UDF VM, each query takes approximately **5-8 seconds**. This latency is dominated by Exasol's Lua sandbox initialization (~80% of total time), not by the embedding (~50–150 ms warm) or vector search (~50–100 ms). The very first query after a VM restart additionally pays a 3–8 s model-load cost for `nomic-embed-text-v1.5` from BucketFS.

For use cases requiring sub-second latency, consider querying Qdrant directly via its HTTP API and computing embeddings client-side with `sentence-transformers` (matching the SLC's `nomic-embed-text-v1.5`, normalized).

---

## Virtual Schema Properties

| Property            | Required | Default             | Description                                                                       |
| ------------------- | -------- | ------------------- | --------------------------------------------------------------------------------- |
| `CONNECTION_NAME`   | Yes      | —                   | Exasol CONNECTION object with Qdrant URL                                          |
| `QDRANT_MODEL`      | Yes      | —                   | Embedding model name (informational; surfaced in diagnostic errors)               |
| `QDRANT_URL`        | No       | —                   | Override Qdrant URL (ignores CONNECTION address)                                  |
| `COLLECTION_FILTER` | No       | — (all collections) | Comma-separated list of collection names or glob patterns to expose               |

> **Removed property:** `OLLAMA_URL` is no longer accepted. The adapter rejects any `CREATE VIRTUAL SCHEMA … WITH OLLAMA_URL = '…'` or `ALTER VIRTUAL SCHEMA … SET OLLAMA_URL = '…'` with a clear migration error. Drop and re-create the virtual schema after running `install_all.sql`.

Change properties without dropping the schema:

```sql
ALTER VIRTUAL SCHEMA vector_schema SET COLLECTION_FILTER = 'bank_*';
ALTER VIRTUAL SCHEMA vector_schema REFRESH;
```

### Collection Filtering

By default, the virtual schema exposes ALL Qdrant collections as tables. Use `COLLECTION_FILTER` to scope which collections are visible:

```sql
-- Only expose specific collections
CREATE VIRTUAL SCHEMA vector_schema
    USING ADAPTER.VECTOR_SCHEMA_ADAPTER
    WITH CONNECTION_NAME   = 'qdrant_conn'
         QDRANT_MODEL      = 'nomic-embed-text-v1.5'
         COLLECTION_FILTER = 'bank_*,products';

-- Update the filter later
ALTER VIRTUAL SCHEMA vector_schema SET COLLECTION_FILTER = 'prod_*';
ALTER VIRTUAL SCHEMA vector_schema REFRESH;
```

Supports glob patterns: `*` matches any characters, `?` matches a single character.

---

## Project Structure

```
src/lua/
├── entry.lua                    # Global adapter_call() entrypoint — no business logic
├── adapter/
│   ├── QdrantAdapter.lua        # Adapter lifecycle (create, refresh, setProperties, pushDown)
│   ├── AdapterProperties.lua    # Property constants, validation, merge semantics
│   ├── capabilities.lua         # Capability set declaration
│   ├── MetadataReader.lua       # HTTP GET /collections → table metadata
│   └── QueryRewriter.lua        # Builds pushdown SQL that calls SEARCH_QDRANT_LOCAL
└── util/
    └── http.lua                 # LuaSocket JSON GET/POST wrapper (Qdrant only)
dist/
└── adapter.lua                  # Single-file bundle (output of lua-amalg)
build/
└── amalg.lua                    # Build script: lua build/amalg.lua → regenerates dist/
scripts/
├── install_all.sql              # One-file installer (deploy entire stack)
├── install_adapter.sql          # Standalone Lua adapter script only
├── install_local_embeddings.sql # PYTHON3_QDRANT alias + EMBED_AND_PUSH_LOCAL + EMBED_TEXT + SEARCH_QDRANT_LOCAL
└── build_and_upload_slc.sh      # One-time SLC build + BucketFS upload
exasol_udfs/                     # Python UDF source: embed_and_push_local, embed_text, search_qdrant_local, create_collection
docs/
├── local-embeddings.md          # SLC build, BucketFS upload, throughput notes
├── quickstart.md                # Step-by-step Docker quickstart
├── udf-ingestion.md             # EMBED_AND_PUSH_LOCAL reference
└── ...
```

---

## Building

The adapter ships as `dist/adapter.lua` — a single file bundled by `lua-amalg`.
You only need to rebuild when modifying `src/lua/` source files.

```bash
# Install dev dependencies (once)
luarocks install amalg
luarocks install virtual-schema-common-lua

# Rebuild dist/adapter.lua
lua build/amalg.lua
```

---

## Known Limitations

- **Hybrid search requires Qdrant text index** -- collections created with `CREATE_QDRANT_COLLECTION` (v2.2.0+) include the text index automatically. For older collections, add the index manually (see [docs/limitations.md](docs/limitations.md)).
- **Fixed 4-column schema** -- each virtual table exposes ID, TEXT, SCORE, QUERY. Custom Qdrant payload fields are not directly accessible (use JOINs as a workaround, see above).
- **5-8 second query latency** -- dominated by Exasol's Lua sandbox initialization, not the search itself. Cold-VM first queries pay an additional 3–8 s for model load.
- **Single vector field** -- the adapter searches the `text` vector field. Multi-vector collections are not supported.

---

## Troubleshooting

### "Virtual schema already exists" after DROP

Exasol has a known session-level metadata caching bug where `DROP VIRTUAL SCHEMA` reports success but the schema persists as a "ghost." The next `CREATE VIRTUAL SCHEMA` then fails with "already exists," even though `SELECT * FROM SYS.EXA_ALL_VIRTUAL_SCHEMAS` shows nothing.

**Fix (try in order):**

1. Use `DROP FORCE ... CASCADE` on the virtual schema:
   ```sql
   DROP FORCE VIRTUAL SCHEMA IF EXISTS vector_schema CASCADE;
   ```
   This is safe — `CASCADE` on a **virtual** schema only drops the virtual table mappings, not the underlying ADAPTER schema or its scripts/connections.
2. If it still persists, **disconnect and reconnect** your SQL session, then re-run the DROP + CREATE.
3. As a last resort, use a different schema name (e.g., `vector_schema_2`).

> **Note:** Never use `CASCADE` on the `ADAPTER` schema itself — that would destroy the adapter scripts, UDFs, and connections. `CASCADE` is only safe on the `vector_schema` (virtual schema).

### "function or script ADAPTER.SEARCH_QDRANT_LOCAL not found"

The query path is owned by `SEARCH_QDRANT_LOCAL` (not `EMBED_TEXT` — that one is now a parity utility). Re-run `scripts/install_all.sql` (or the smaller `scripts/install_local_embeddings.sql`), verify `PYTHON3_QDRANT` is registered in `SCRIPT_LANGUAGES`, and confirm `/buckets/bfsdefault/default/models/nomic-embed-text-v1.5` exists in BucketFS (run `./scripts/build_and_upload_slc.sh` if not).

---

## Limitations

See [docs/lua-port/limitations.md](docs/lua-port/limitations.md) for full details. Key points:

- **Read-only virtual schema** — INSERT via the virtual schema is not supported; use `EMBED_AND_PUSH_LOCAL` (see [docs/udf-ingestion.md](docs/udf-ingestion.md)) or the direct HTTP approach above
- **HTTP or public CA TLS only** — the Lua adapter cannot load custom CA certificates; self-signed TLS on Qdrant is not supported
- **One embedding call per query** — `SEARCH_QDRANT_LOCAL` embeds the query text synchronously at query time
- **No UPDATE or DELETE** — re-insert with the same ID to overwrite (upsert behaviour)
- **Single embedding model per cluster** — the SLC ships exactly one model (`nomic-embed-text-v1.5`); changing models requires rebuilding and re-uploading the SLC

---

## License

This project is licensed under the [MIT License](LICENSE).
