# Deployment Guide

## Prerequisites

- Exasol 7.x or later (Docker or on-premise)
- Qdrant 1.9+ running and reachable from Exasol
- Ollama running with `nomic-embed-text` pulled

No Maven, no Java, no BucketFS required.

---

## Option A — One-File Installer (Recommended)

The simplest way to deploy the entire stack. A single SQL file creates the schema, connection, Lua adapter, Python UDFs, and virtual schema.

### 1. Open `scripts/install_all.sql` in your SQL client

Use DBeaver, DbVisualizer, or any Exasol-compatible tool.

### 2. Update the configuration values

Find-and-replace these defaults throughout the file:

| Default            | What it is                     | How to find yours                            |
| ------------------ | ------------------------------ | -------------------------------------------- |
| `172.17.0.1`       | Docker bridge gateway IP       | `docker exec exasoldb ip route show default` |
| `6333`             | Qdrant port                    | Default unless you changed it                |
| `11434`            | Ollama port                    | Default unless you changed it                |
| `nomic-embed-text` | Ollama embedding model         | Must be pulled: `ollama pull nomic-embed-text` |
| `ADAPTER`          | Schema name for scripts/UDFs   | Change if you prefer a different schema      |

### 3. Run the entire file

Execute the file as a script (not statement-by-statement). It deploys:

- `ADAPTER` schema
- `qdrant_conn` connection to Qdrant
- `ADAPTER.VECTOR_SCHEMA_ADAPTER` — Lua adapter script
- `ADAPTER.CREATE_QDRANT_COLLECTION` — Python UDF for collection creation
- `ADAPTER.EMBED_AND_PUSH` — Python UDF for data ingestion
- `vector_schema` virtual schema (auto-refreshed)

### 4. Verify

```sql
-- List tables (one per Qdrant collection)
SELECT * FROM EXA_ALL_TABLES WHERE TABLE_SCHEMA = 'VECTOR_SCHEMA';
```

> **No BucketFS, no JAR, no Maven, no pasting.** One file, one run, everything deployed.

---

## Option B — Deploy Components Individually

If you prefer to deploy the adapter and UDFs separately (e.g., you only need the adapter, or you want to customize the setup):

### Adapter only

Run `scripts/install_adapter.sql` in your SQL client. This deploys only the Lua adapter script — no UDFs, no virtual schema.

You will need to create the connection and virtual schema manually:

```sql
CREATE SCHEMA IF NOT EXISTS ADAPTER;

CREATE OR REPLACE CONNECTION qdrant_conn
  TO 'http://172.17.0.1:6333'
  USER ''
  IDENTIFIED BY '';

-- Run scripts/install_adapter.sql here

CREATE VIRTUAL SCHEMA vector_schema
  USING ADAPTER.VECTOR_SCHEMA_ADAPTER
  WITH CONNECTION_NAME = 'qdrant_conn'
       QDRANT_MODEL    = 'nomic-embed-text'
       OLLAMA_URL      = 'http://172.17.0.1:11434';
```

### UDFs only

Run `scripts/create_udfs_ollama.sql` to deploy just the Python UDFs (`CREATE_QDRANT_COLLECTION` and `EMBED_AND_PUSH`).

---

## Docker Networking

Inside Exasol's container, `localhost` refers to the container itself and `host.docker.internal` does not resolve in the UDF sandbox on Linux. Use the Docker bridge gateway IP instead:

```bash
docker exec exasoldb ip route show default
# → default via 172.17.0.1 dev eth0
```

Use `172.17.0.1` (or whatever is shown) for the Qdrant and Ollama URLs in the connection and virtual schema properties.

---

## Updating the Adapter

After modifying `src/lua/` source files:

```bash
# Rebuild the single-file bundle
lua build/amalg.lua
```

Then re-run `scripts/install_all.sql` (or just the adapter portion). The `CREATE OR REPLACE` statements overwrite the previous version.

No need to drop the virtual schema — just refresh it:

```sql
ALTER VIRTUAL SCHEMA vector_schema REFRESH;
```

---

## Rollback

Dropping the virtual schema does **not** delete Qdrant collections:

```sql
DROP VIRTUAL SCHEMA vector_schema CASCADE;
-- Qdrant collections remain intact and can be reattached later
```
