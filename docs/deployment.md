# Deployment Guide

## Prerequisites

- Exasol 7.x or later (Docker or on-premise)
- Qdrant 1.9+ running and reachable from Exasol
- Ollama running with `nomic-embed-text` pulled
- Maven 3.8+ and Java 21 for building

---

## Step 1 — Build the fat JAR

```bash
mvn clean package -DskipTests
# Output: target/qdrant-virtual-schema-0.1.0-all.jar  (~5.6 MB)
```

---

## Step 2 — Deploy JAR to BucketFS

### Option A: Exasol in Docker (copy directly)

```bash
docker exec exasoldb mkdir -p /exa/data/bucketfs/bfsdefault/.dest/default/adapter

docker cp target/qdrant-virtual-schema-0.1.0-all.jar \
  exasoldb:/exa/data/bucketfs/bfsdefault/.dest/default/adapter/qdrant-virtual-schema-0.1.0-all.jar
```

### Option B: BucketFS HTTPS upload (port 2581 must be exposed)

```bash
curl -k -X PUT -T target/qdrant-virtual-schema-0.1.0-all.jar \
  "https://w:<write-password>@<exasol-host>:2581/default/adapter/qdrant-virtual-schema-0.1.0-all.jar"
```

---

## Step 3 — Find the Docker host IP (Docker deployments only)

The UDF sandbox inside Exasol cannot resolve `host.docker.internal`. Use the bridge gateway IP instead:

```bash
docker exec exasoldb ip route show default
# → default via 172.17.0.1 dev eth0
```

Use `172.17.0.1` (or whatever is shown) in the connection and virtual schema properties below.

---

## Step 4 — Create SQL objects in Exasol

Run in order in your SQL client:

```sql
-- 1. Schema for the adapter script
CREATE SCHEMA IF NOT EXISTS ADAPTER;

-- 2. Connection to Qdrant
CREATE OR REPLACE CONNECTION qdrant_conn
  TO 'http://172.17.0.1:6333'   -- replace with your Qdrant host IP
  USER ''
  IDENTIFIED BY '';              -- Qdrant API key if auth is enabled

-- 3. Adapter script
CREATE OR REPLACE JAVA ADAPTER SCRIPT ADAPTER.VECTOR_SCHEMA_ADAPTER AS
  %scriptclass com.exasol.adapter.RequestDispatcher;
  %jar /buckets/bfsdefault/default/adapter/qdrant-virtual-schema-0.1.0-all.jar;
/

-- 4. Virtual schema
CREATE VIRTUAL SCHEMA vector_schema
  USING ADAPTER.VECTOR_SCHEMA_ADAPTER
  WITH CONNECTION_NAME = 'qdrant_conn'
       QDRANT_MODEL    = 'nomic-embed-text'
       OLLAMA_URL      = 'http://172.17.0.1:11434';  -- replace with your Ollama host IP
```

> **Important:** Step 3 must be executed as a single block using "Execute as Script" in your SQL client (not statement-by-statement), because the script body contains semicolons.

---

## Step 5 — Verify

```sql
-- Should return the count of Qdrant collections (0 if none exist yet)
ALTER VIRTUAL SCHEMA vector_schema REFRESH;

-- List tables (one per Qdrant collection)
SELECT * FROM EXA_ALL_TABLES WHERE TABLE_SCHEMA = 'VECTOR_SCHEMA';
```

---

## Updating the JAR

After rebuilding, redeploy the JAR (Step 2) and then force Exasol to reload it:

```sql
DROP VIRTUAL SCHEMA IF EXISTS vector_schema CASCADE;

-- Recreate (same as Step 4 above)
CREATE VIRTUAL SCHEMA vector_schema
  USING ADAPTER.VECTOR_SCHEMA_ADAPTER
  WITH CONNECTION_NAME = 'qdrant_conn'
       QDRANT_MODEL    = 'nomic-embed-text'
       OLLAMA_URL      = 'http://172.17.0.1:11434';
```

---

## Rollback

Dropping the virtual schema does **not** delete Qdrant collections:

```sql
DROP VIRTUAL SCHEMA vector_schema CASCADE;
-- Qdrant collections remain intact and can be reattached later
```
