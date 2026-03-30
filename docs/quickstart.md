# Quickstart: Semantic Search in Exasol

Get from zero to your first semantic search query in about 15 minutes. No Java, no Maven, no BucketFS — just Docker and a SQL client.

---

## Before You Begin

**The only thing you need installed is Docker.**

- [Download Docker Desktop](https://www.docker.com/products/docker-desktop/) (Windows / Mac / Linux)

Once Docker Desktop is running, open a terminal (Command Prompt, PowerShell, or Terminal on Mac/Linux) and follow the steps below.

---

## Step 1 — Start the Services

Run each command in your terminal. Wait for each one to finish before running the next.

**1. Start Qdrant (the vector database)**

```bash
docker run -d --name qdrant -p 6333:6333 qdrant/qdrant
```

**2. Start Ollama (the embedding model server)**

```bash
docker run -d --name ollama -p 11434:11434 ollama/ollama
```

**3. Download the embedding model into Ollama** (takes a minute or two)

```bash
docker exec ollama ollama pull nomic-embed-text
```

**4. Start Exasol**

```bash
docker run -d --name exasoldb \
  -p 8563:8563 \
  -p 2580:2580 \
  --privileged \
  exasol/docker-db:latest
```

> Exasol can take 1–2 minutes to fully start up. You can check it is ready by running:
> `docker logs exasoldb 2>&1 | grep "ready to accept connections"`

---

## Step 2 — Find Your Network IPs

> **Why this matters:** When Exasol runs inside a Docker container, the word `localhost` refers to the container itself — not your computer. You need to use special IP addresses so the services can talk to each other.

### Your Docker Bridge IP (used for Qdrant)

Run this command to find it:

```bash
docker exec exasoldb ip route show default
# Example output: default via 172.17.0.1 dev eth0
```

The IP after `via` (e.g., `172.17.0.1`) is your **Docker bridge IP**. Write it down — you'll use it in Steps 3 and 4.

### Your Ollama Container IP (used for the ingestion UDFs)

```bash
docker inspect ollama --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}'
# Example output: 172.17.0.4
```

Write this down too — you'll use it in Step 5.

---

## Step 3 — Install the Adapter in Exasol

Open your SQL client (DBeaver, DbVisualizer, or any Exasol-compatible tool) and connect to:

- **Host:** `localhost`
- **Port:** `8563`
- **User:** `sys`
- **Password:** `exasol`

Then run the following SQL statements **one block at a time**.

### 3a. Create the adapter schema

```sql
CREATE SCHEMA IF NOT EXISTS ADAPTER;
```

### 3b. Create a connection to Qdrant

Replace `<DOCKER_BRIDGE_IP>` with the IP you found in Step 2.

```sql
CREATE OR REPLACE CONNECTION qdrant_conn
  TO 'http://<DOCKER_BRIDGE_IP>:6333'
  USER ''
  IDENTIFIED BY '';
```

### 3c. Install the adapter script

Open the file `dist/adapter.lua` from this project in a text editor. Copy **all** of its contents.

Then run the statement below, replacing `-- PASTE HERE` with the contents you just copied:

```sql
CREATE OR REPLACE LUA ADAPTER SCRIPT ADAPTER.VECTOR_SCHEMA_ADAPTER AS
  -- PASTE HERE
/
```

> **Tip:** In DBeaver, use "Execute as Script" (not "Execute Statement") for this block, because the script body contains semicolons.

### 3d. Create the virtual schema

Replace `<DOCKER_BRIDGE_IP>` with the same IP as in step 3b.

```sql
CREATE VIRTUAL SCHEMA vector_schema
  USING ADAPTER.VECTOR_SCHEMA_ADAPTER
  WITH CONNECTION_NAME = 'qdrant_conn'
       QDRANT_MODEL    = 'nomic-embed-text'
       OLLAMA_URL      = 'http://<DOCKER_BRIDGE_IP>:11434';
```

---

## Step 4 — Set Up the Ingestion UDFs

The virtual schema is read-only — to load data into Qdrant, you use a small helper UDF.

In your SQL client, open the file `scripts/create_udfs_ollama.sql` from this project and execute it. This creates two helper functions (`CREATE_QDRANT_COLLECTION` and `EMBED_AND_PUSH`) in the `ADAPTER` schema.

You only need to do this once.

---

## Step 5 — Create a Collection and Load Sample Data

Replace `<DOCKER_BRIDGE_IP>` and `<OLLAMA_IP>` with the IPs you found in Step 2.

### 5a. Create a Qdrant collection

```sql
SELECT ADAPTER.CREATE_QDRANT_COLLECTION(
    '<DOCKER_BRIDGE_IP>', 6333, '', 'quickstart', 768, 'Cosine', ''
);
```

### 5b. Load sample documents

This embeds 5 sample sentences using Ollama and stores them in Qdrant:

```sql
SELECT ADAPTER.EMBED_AND_PUSH(
    id_col, text_col,
    '<DOCKER_BRIDGE_IP>', 6333, '',
    'quickstart',
    'ollama',
    'http://<OLLAMA_IP>:11434',
    'nomic-embed-text'
)
FROM (
    VALUES
    ('doc-1', 'Artificial intelligence is transforming the way we work and live.'),
    ('doc-2', 'The Eiffel Tower stands 330 meters tall in Paris, France.'),
    ('doc-3', 'Machine learning models learn patterns from large datasets.'),
    ('doc-4', 'The Mediterranean Sea borders southern Europe and northern Africa.'),
    ('doc-5', 'Neural networks are loosely inspired by the structure of the human brain.')
) AS t(id_col, text_col)
GROUP BY IPROC();
```

### 5c. Refresh the virtual schema

This makes the new `quickstart` collection visible as a table:

```sql
ALTER VIRTUAL SCHEMA vector_schema REFRESH;
```

---

## Step 6 — Run Your First Search

Search for documents related to a topic using plain SQL:

```sql
SELECT "ID", "TEXT", "SCORE"
FROM vector_schema.quickstart
WHERE "QUERY" = 'machine learning and AI'
LIMIT 5;
```

You should see results like:

| ID    | TEXT                                                                | SCORE  |
|-------|---------------------------------------------------------------------|--------|
| doc-3 | Machine learning models learn patterns from large datasets.        | 0.9412 |
| doc-1 | Artificial intelligence is transforming the way we work and live.  | 0.8931 |
| doc-5 | Neural networks are loosely inspired by the structure of the brain.| 0.8754 |

The `SCORE` column is cosine similarity — higher means more semantically similar to your query. Results are automatically ranked best-first.

Try changing the query string to see different results:

```sql
-- Search for geographic topics
SELECT "ID", "TEXT", "SCORE"
FROM vector_schema.quickstart
WHERE "QUERY" = 'European landmarks and geography'
LIMIT 5;
```

---

## What's Next

Now that you have a working setup, explore the rest of the documentation:

- [Usage Guide](usage-guide.md) — SQL patterns for searching, joining results with other tables, and managing collections
- [UDF Ingestion Guide](udf-ingestion.md) — Load data from existing Exasol tables, use the OpenAI provider, and handle large batches
- [Limitations](limitations.md) — Known constraints (TLS, read-only virtual schema, model consistency)
