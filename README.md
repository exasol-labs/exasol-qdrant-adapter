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
Virtual Schema Adapter (Java, runs in Exasol)
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

---

## Prerequisites

| Component | Version | Notes |
|-----------|---------|-------|
| Exasol | 7.x+ | Docker or on-premise |
| Qdrant | 1.9+ | Docker recommended |
| Ollama | latest | Must have `nomic-embed-text` pulled |
| Java | 21 | For building only |
| Maven | 3.8+ | For building only |

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

### 3. Build the adapter JAR

```bash
mvn clean package -DskipTests
# Output: target/qdrant-virtual-schema-0.1.0-all.jar
```

### 4. Deploy the JAR to Exasol BucketFS

If Exasol is running in Docker, copy the JAR directly into the BucketFS destination directory:

```bash
docker exec exasoldb mkdir -p /exa/data/bucketfs/bfsdefault/.dest/default/adapter
docker cp target/qdrant-virtual-schema-0.1.0-all.jar \
  exasoldb:/exa/data/bucketfs/bfsdefault/.dest/default/adapter/qdrant-virtual-schema-0.1.0-all.jar
```

If you have BucketFS HTTPS access (port 2581), you can also upload via HTTP:

```bash
curl -k -X PUT -T target/qdrant-virtual-schema-0.1.0-all.jar \
  https://w:<write-password>@<exasol-host>:2581/default/adapter/qdrant-virtual-schema-0.1.0-all.jar
```

### 5. Create SQL objects in Exasol

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

-- Adapter script (note: JAVA ADAPTER SCRIPT, not SET SCRIPT)
CREATE OR REPLACE JAVA ADAPTER SCRIPT ADAPTER.VECTOR_SCHEMA_ADAPTER AS
  %scriptclass com.exasol.adapter.RequestDispatcher;
  %jar /buckets/bfsdefault/default/adapter/qdrant-virtual-schema-0.1.0-all.jar;
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

> **Docker networking note:** `host.docker.internal` does not resolve inside Exasol's UDF sandbox on Linux. Use the Docker bridge gateway IP instead. Find it with:
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

```sql
-- 1. Run scripts/create_udfs_ollama.sql in your SQL client to create the UDFs
--    (only needed once)

-- 2. Create the Qdrant collection (nomic-embed-text = 768 dimensions)
SELECT ADAPTER.CREATE_QDRANT_COLLECTION(
    '172.17.0.1', 6333, '', 'my_collection', 768, 'Cosine', ''
);

-- 3. Embed and push rows from an Exasol table
SELECT ADAPTER.EMBED_AND_PUSH(
    id_col, text_col,
    '172.17.0.1', 6333, '',
    'my_collection',
    'ollama',
    'http://172.17.0.4:11434',  -- Ollama container IP (not localhost)
    'nomic-embed-text'
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

| Column | Type | Description |
|--------|------|-------------|
| `ID` | VARCHAR | Original document ID as inserted |
| `TEXT` | VARCHAR | Original document text |
| `SCORE` | DOUBLE | Cosine similarity (0–1, higher = more similar) |
| `QUERY` | VARCHAR | The query string echoed back |

> Always quote column names with double quotes (`"QUERY"`) to avoid conflicts with Exasol reserved keywords.

---

## Virtual Schema Properties

| Property | Required | Default | Description |
|----------|----------|---------|-------------|
| `CONNECTION_NAME` | Yes | — | Exasol CONNECTION object with Qdrant URL |
| `QDRANT_MODEL` | Yes | — | Ollama model name for embeddings |
| `OLLAMA_URL` | No | `http://localhost:11434` | Ollama base URL reachable from Exasol |
| `QDRANT_URL` | No | — | Override Qdrant URL (ignores CONNECTION address) |

Change properties without dropping the schema:

```sql
ALTER VIRTUAL SCHEMA vector_schema SET OLLAMA_URL = 'http://172.17.0.4:11434';
ALTER VIRTUAL SCHEMA vector_schema REFRESH;
```

---

## Project Structure

```
src/
├── main/java/com/exasol/adapter/qdrant/
│   ├── VectorSchemaAdapter.java        # Main adapter (push-down routing)
│   ├── VectorSchemaAdapterFactory.java # Service loader entry point
│   ├── AdapterProperties.java          # Property constants and validation
│   ├── CredentialResolver.java         # Reads URL + API key from CONNECTION object
│   ├── client/
│   │   ├── QdrantClient.java           # Qdrant REST API client
│   │   ├── OllamaEmbeddingClient.java  # Ollama embeddings client
│   │   ├── QdrantException.java        # Qdrant error wrapper
│   │   └── model/
│   │       ├── Point.java              # Qdrant point (id, originalId, text)
│   │       └── SearchResult.java       # Search result (id, text, score)
│   ├── handler/
│   │   ├── SelectHandler.java          # Handles SELECT similarity search
│   │   ├── InsertHandler.java          # Handles INSERT (embedding + upsert)
│   │   └── CreateCollectionHandler.java # Handles collection creation
│   └── util/
│       └── IdMapper.java               # VARCHAR → UUID v5 mapping
docs/
├── deployment.md   # Detailed deployment steps
├── usage-guide.md  # SQL usage examples
└── limitations.md  # Known limitations
```

---

## Building

```bash
# Build fat JAR (includes all dependencies)
mvn clean package -DskipTests

# Run unit tests
mvn test

# Run integration tests (requires Qdrant on localhost:6333)
mvn verify -Pit
```

---

## Limitations

See [docs/limitations.md](docs/limitations.md) for full details. Key points:

- **Read-only virtual schema** — INSERT via the virtual schema is not supported; use the `EMBED_AND_PUSH` UDF (see [docs/udf-ingestion.md](docs/udf-ingestion.md)) or the direct HTTP approach below
- **One embedding call per query** — Ollama is called synchronously at query time
- **No UPDATE or DELETE** — re-insert with the same ID to overwrite (upsert behaviour)
- **Model consistency** — changing `QDRANT_MODEL` does not re-embed existing data; recreate the collection

---

## License

Apache 2.0
