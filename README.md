# Exasol Qdrant Vector Search Adapter

A Virtual Schema adapter that brings semantic similarity search into Exasol SQL using [Qdrant](https://qdrant.tech/) as the vector store and [Ollama](https://ollama.com/) for local text embeddings.

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
Virtual Schema Adapter (Lua, runs inside Exasol — no BucketFS, no JAR)
      ↓
Ollama (local embeddings — text → float vector)
      ↓
Qdrant (vector similarity search)
      ↓
Ranked results back to Exasol
```

- No pre-computed embeddings needed — the adapter calls Ollama automatically at query time
- Results are ranked by cosine similarity score (0–1, higher = more similar)
- Works with any Ollama embedding model (default: `nomic-embed-text`)
- Deployed as a single SQL statement — no Maven build, no BucketFS upload

---

## Prerequisites

| Component | Version | Notes                               |
| --------- | ------- | ----------------------------------- |
| Exasol    | 7.x+    | Docker or on-premise                |
| Qdrant    | 1.9+    | Docker recommended                  |
| Ollama    | latest  | Must have `nomic-embed-text` pulled |

**Dev-only** (only needed to rebuild `dist/adapter.lua` after source changes):

| Tool       | Install                       |
| ---------- | ----------------------------- |
| Lua 5.4    | `brew install lua` / apt      |
| lua-amalg  | `luarocks install amalg`      |
| virtual-schema-common-lua | `luarocks install virtual-schema-common-lua` |

---

## Quick Start (Docker)

### 1. Start Qdrant

```bash
docker run -d --name qdrant -p 6333:6333 qdrant/qdrant
```

### 2. Start Ollama and pull the embedding model

```bash
docker run -d --name ollama -p 11434:11434 ollama/ollama
docker exec ollama ollama pull nomic-embed-text
```

### 3. Install the adapter in Exasol (one SQL statement)

Run these statements in your SQL client (DBeaver, DBvisualizer, etc.):

```sql
-- Schema for the adapter script
CREATE SCHEMA IF NOT EXISTS ADAPTER;

-- Connection object pointing to Qdrant
-- Replace the IP with your Qdrant host
-- If Exasol runs in Docker, use the Docker bridge gateway IP (typically 172.17.0.1)
CREATE OR REPLACE CONNECTION qdrant_conn
  TO 'http://172.17.0.1:6333'
  USER ''
  IDENTIFIED BY '';

-- Adapter script — paste the contents of dist/adapter.lua between AS and /
CREATE OR REPLACE LUA ADAPTER SCRIPT ADAPTER.VECTOR_SCHEMA_ADAPTER AS
  -- <paste contents of dist/adapter.lua here>
/

-- Virtual schema
-- OLLAMA_URL: where Ollama is reachable from inside the Exasol container
-- QDRANT_MODEL: the Ollama model name used for embeddings
CREATE VIRTUAL SCHEMA vector_schema
  USING ADAPTER.VECTOR_SCHEMA_ADAPTER
  WITH CONNECTION_NAME = 'qdrant_conn'
       QDRANT_MODEL    = 'nomic-embed-text'
       OLLAMA_URL      = 'http://172.17.0.1:11434';
```

> **No BucketFS, no JAR, no Maven.** The entire adapter is the single file `dist/adapter.lua`.

> **Docker networking note:** `host.docker.internal` does not resolve inside Exasol's UDF sandbox on Linux. Use the Docker bridge gateway IP instead. Find it with:
>
> ```bash
> docker exec exasoldb ip route show default
> # → default via 172.17.0.1 dev eth0
> ```

---

## Loading Data

There are two ways to get data into Qdrant so you can query it via the virtual schema:

### Option A — Ingestion via Exasol UDFs (recommended for Exasol-native data)

If your source data already lives in Exasol tables, use the **`EMBED_AND_PUSH`** SET UDF
to embed rows with Ollama and push them to Qdrant without leaving SQL.

**No SLC or extra packages required** — the UDFs use Python's standard library only.

The UDF takes two columns from your table:

- **`id_col`** — A unique identifier for each row (e.g. a primary key or row number). This is stored as `_original_id` in Qdrant and returned as the `"ID"` column in search results, so you can join back to your source table.
- **`text_col`** — The text to embed and search against. This is the content that gets converted into a vector by Ollama. For best results, concatenate multiple columns into a descriptive sentence rather than using a single field. For example, if your table has `name`, `city`, and `date` columns, combine them: `"name" || ' in ' || "city" || '. Date: ' || CAST("date" AS VARCHAR(10))`.

Both must be `VARCHAR` — cast numeric or date columns with `CAST(... AS VARCHAR(...))`.

```sql
-- 1. Run scripts/create_udfs_ollama.sql in your SQL client to create the UDFs
--    (only needed once)

-- 2. Create the Qdrant collection (nomic-embed-text = 768 dimensions)
SELECT ADAPTER.CREATE_QDRANT_COLLECTION(
    '172.17.0.1', 6333, '', 'my_collection', 768, 'Cosine', ''
);

-- 3. Embed and push rows from an Exasol table
--    Replace id_col and text_col with columns from YOUR table
SELECT ADAPTER.EMBED_AND_PUSH(
    CAST(id_col AS VARCHAR(36)),
    text_col,                       -- or a concatenation of columns (see above)
    '172.17.0.1', 6333, '',        -- Qdrant host, port, API key
    'my_collection',                -- Qdrant collection name
    'ollama',                       -- embedding provider
    'http://172.17.0.4:11434',      -- Ollama container IP (not localhost)
    'nomic-embed-text'              -- Ollama model name
)
FROM MY_SCHEMA.MY_TABLE
GROUP BY IPROC();

-- 4. Search
ALTER VIRTUAL SCHEMA vector_schema REFRESH;
SELECT "ID", "TEXT", "SCORE"
FROM vector_schema.my_collection
WHERE "QUERY" = 'your search query here'
LIMIT 10;
```

> **Docker networking:** the UDFs run inside the Exasol container. Use the Ollama
> container IP (find it with `docker inspect ollama`) — not `localhost` or `172.17.0.1`.

See [docs/udf-ingestion.md](docs/udf-ingestion.md) for the full guide including
parameter reference, troubleshooting, and OpenAI provider usage.

### Option B — Direct HTTP / PowerShell ingestion

Since Exasol virtual schemas are read-only, data can also be inserted directly into Qdrant via its REST API. The adapter handles query-time embedding automatically via Ollama.

Use the PowerShell helper below, or any HTTP client:

```powershell
function Add-Document($collection, $id, $text) {
    # Get embedding from Ollama
    $body = @{ model = "nomic-embed-text"; prompt = $text } | ConvertTo-Json
    $resp = Invoke-RestMethod -Method POST -Uri 'http://localhost:11434/api/embeddings' `
        -ContentType 'application/json' -Body $body

    # Upsert into Qdrant
    $point = @{
        points = @(@{
            id      = [guid]::NewGuid().ToString()
            payload = @{ _original_id = $id; text = $text }
            vectors = @{ text = $resp.embedding }
        })
    } | ConvertTo-Json -Depth 10

    Invoke-RestMethod -Method PUT `
        -Uri "http://localhost:6333/collections/$collection/points" `
        -ContentType 'application/json' -Body $point
}

# Create collection (768 dimensions for nomic-embed-text)
Invoke-RestMethod -Method PUT -Uri 'http://localhost:6333/collections/articles' `
  -ContentType 'application/json' `
  -Body '{"vectors":{"text":{"size":768,"distance":"Cosine"}}}'

# Insert documents
Add-Document "articles" "doc-1" "Machine learning is a subset of artificial intelligence"
Add-Document "articles" "doc-2" "The Eiffel Tower is located in Paris, France"
Add-Document "articles" "doc-3" "Neural networks are inspired by the human brain"

# Refresh virtual schema to see the new collection as a table
# Run in Exasol: ALTER VIRTUAL SCHEMA vector_schema REFRESH;
```

---

## Refresh Virtual Schema

```sql
ALTER VIRTUAL SCHEMA vector_schema REFRESH;
```

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
| `SCORE` | DOUBLE  | Cosine similarity (0–1, higher = more similar) |
| `QUERY` | VARCHAR | The query string echoed back                   |

> Always quote column names with double quotes (`"QUERY"`) to avoid conflicts with Exasol reserved keywords.
>
> **Default limit:** When no `LIMIT` clause is specified, results are capped at **10 rows**. Always include an explicit `LIMIT` to control how many results you get back.

---

## Virtual Schema Properties

| Property          | Required | Default                  | Description                                      |
| ----------------- | -------- | ------------------------ | ------------------------------------------------ |
| `CONNECTION_NAME` | Yes      | —                        | Exasol CONNECTION object with Qdrant URL         |
| `QDRANT_MODEL`    | Yes      | —                        | Ollama model name for embeddings                 |
| `OLLAMA_URL`      | No       | `http://localhost:11434` | Ollama base URL reachable from Exasol            |
| `QDRANT_URL`      | No       | —                        | Override Qdrant URL (ignores CONNECTION address) |

Change properties without dropping the schema:

```sql
ALTER VIRTUAL SCHEMA vector_schema SET OLLAMA_URL = 'http://172.17.0.4:11434';
ALTER VIRTUAL SCHEMA vector_schema REFRESH;
```

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
│   └── QueryRewriter.lua        # Ollama embed + Qdrant search + VALUES SQL builder
└── util/
    └── http.lua                 # LuaSocket JSON GET/POST wrapper
dist/
└── adapter.lua                  # Single-file bundle (output of lua-amalg — deploy this)
build/
└── amalg.lua                    # Build script: lua build/amalg.lua → regenerates dist/
exasol_udfs/                     # Python UDFs (EMBED_AND_PUSH, CREATE_QDRANT_COLLECTION)
docs/
├── lua-port/
│   └── limitations.md           # Known Lua adapter limitations (TLS caveat etc.)
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

## Limitations

See [docs/lua-port/limitations.md](docs/lua-port/limitations.md) for full details. Key points:

- **Read-only virtual schema** — INSERT via the virtual schema is not supported; use the `EMBED_AND_PUSH` UDF (see [docs/udf-ingestion.md](docs/udf-ingestion.md)) or the direct HTTP approach below
- **HTTP or public CA TLS only** — the Lua adapter cannot load custom CA certificates; self-signed TLS on Qdrant/Ollama is not supported
- **One embedding call per query** — Ollama is called synchronously at query time
- **No UPDATE or DELETE** — re-insert with the same ID to overwrite (upsert behaviour)
- **Model consistency** — changing `QDRANT_MODEL` does not re-embed existing data; recreate the collection

---

## License

Apache 2.0
