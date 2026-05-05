# Deployment Guide

## Prerequisites

- Exasol 7.x or later (Docker or on-premise)
- Qdrant 1.9+ running and reachable from Exasol
- `qdrant-embed` SLC + `nomic-embed-text-v1.5` model uploaded to BucketFS
  (one-time: run `./scripts/build_and_upload_slc.sh` from a Linux Docker host;
  see [docs/local-embeddings.md](local-embeddings.md))

No Maven, no Java, no external embedding service.

---

## Option A — One-File Installer (Recommended)

The simplest way to deploy the entire stack. A single SQL file creates the
schema, two CONNECTION objects, the script-language alias, the Lua adapter,
the Python UDFs, and the virtual schema.

### 1. Open `scripts/install_all.sql` in your SQL client

Use DBeaver, DbVisualizer, or any Exasol-compatible tool.

### 2. Update the configuration values

Find-and-replace these defaults throughout the file:

| Default                 | What it is                       | How to find yours                            |
| ----------------------- | -------------------------------- | -------------------------------------------- |
| `172.17.0.1`            | Docker bridge gateway IP         | `docker exec exasoldb ip route show default` |
| `6333`                  | Qdrant port                      | Default unless you changed it                |
| `nomic-embed-text-v1.5` | Embedding model name (informational) | Hard-coded inside `EMBED_TEXT`, `EMBED_AND_PUSH_LOCAL`, `SEARCH_QDRANT_LOCAL`, and `PREFLIGHT_CHECK` — change requires SLC rebuild |
| `ADAPTER`               | Schema name for scripts/UDFs     | Change if you prefer a different schema      |

### 3. Run the entire file

> **SQL client setup:** This file uses `/` (forward slash on its own line) as
> the statement separator — not `;`. In DBeaver, use *SQL Editor → Execute SQL
> Script* (Alt+X). In DbVisualizer, use "Execute as Script." With exaplus CLI:
> `exaplus -f install_all.sql`.

Execute the file as a script (not statement-by-statement). It deploys:

- `ADAPTER` schema
- `qdrant_conn` and `embedding_conn` connections
- `PYTHON3_QDRANT` script-language alias (points at the BucketFS SLC)
- `ADAPTER.VECTOR_SCHEMA_ADAPTER` — Lua adapter script
- `ADAPTER.CREATE_QDRANT_COLLECTION` — Python UDF for collection creation
- `ADAPTER.EMBED_AND_PUSH_LOCAL` — Python SET UDF for in-process ingestion
- `ADAPTER.SEARCH_QDRANT_LOCAL` — Python SET UDF that owns the query path (embed + Qdrant hybrid search)
- `ADAPTER.EMBED_TEXT` — Python SCALAR UDF (utility/parity scalar; not on the query hot path)
- `ADAPTER.PREFLIGHT_CHECK` — Python UDF for connectivity + embedding round-trip validation
- `vector_schema` virtual schema (auto-refreshed)

The script is idempotent — every DDL uses `CREATE OR REPLACE`,
`IF NOT EXISTS`, or `DROP FORCE IF EXISTS`. Safe to re-run after edits.

### 4. Verify

```sql
SELECT ADAPTER.PREFLIGHT_CHECK('http://172.17.0.1:6333');

-- List tables (one per Qdrant collection)
SELECT * FROM EXA_ALL_TABLES WHERE TABLE_SCHEMA = 'VECTOR_SCHEMA';
```

`PREFLIGHT_CHECK` reports Qdrant connectivity and runs an in-process
`SentenceTransformer.encode('preflight')` round-trip against the BucketFS
model — confirming both the network path to Qdrant and the SLC + model are
healthy.

> **One file, one run, everything deployed.** No JAR, no Maven, no separate
> embedding service.

---

## Option B — Deploy Components Individually

If you prefer to deploy the adapter and UDFs separately (e.g., you only need
the adapter, or you want to customize the setup):

### UDFs only

Run `scripts/install_local_embeddings.sql` to register the `PYTHON3_QDRANT`
alias and create `EMBED_AND_PUSH_LOCAL`, `EMBED_TEXT`, and
`SEARCH_QDRANT_LOCAL`. The SLC + model must already be in BucketFS.

### Adapter only

Run `scripts/install_adapter.sql` to deploy only the Lua adapter script — no
UDFs, no virtual schema. The adapter generates pushdown SQL that calls
`ADAPTER.SEARCH_QDRANT_LOCAL`, so that UDF must already exist (run
`scripts/install_local_embeddings.sql` first).

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
       QDRANT_MODEL    = 'nomic-embed-text-v1.5';
```

> **Removed property:** `OLLAMA_URL` is no longer accepted. Earlier versions
> required it; the adapter now rejects any virtual schema that sets it. See
> [docs/local-embeddings.md](local-embeddings.md#migration-from-ollama) for
> migration steps if you are upgrading from a release that used Ollama.

---

## Docker Networking

Inside Exasol's container, `localhost` refers to the container itself and
`host.docker.internal` does not resolve in the UDF sandbox on Linux. Use the
Docker bridge gateway IP instead:

```bash
docker exec exasoldb ip route show default
# → default via 172.17.0.1 dev eth0
```

Use `172.17.0.1` (or whatever is shown) for the Qdrant URL in the connection
and virtual schema properties.

---

## Updating the Adapter

After modifying `src/lua/` source files:

```bash
# Rebuild the single-file bundle
lua build/amalg.lua
```

Then re-run `scripts/install_all.sql` (or just the adapter portion via
`scripts/install_adapter.sql`). The `CREATE OR REPLACE` statements overwrite
the previous version.

After updates that change the property set or adapter behaviour, refresh
the virtual schema:

```sql
ALTER VIRTUAL SCHEMA vector_schema REFRESH;
```

---

## Rollback

Dropping the virtual schema does **not** delete Qdrant collections:

```sql
-- WARNING: Do NOT use CASCADE — it can destroy the ADAPTER schema
-- (scripts, connections, everything). Use DROP FORCE instead.
DROP FORCE VIRTUAL SCHEMA IF EXISTS vector_schema;
-- Qdrant collections remain intact and can be reattached later
```

To remove the local-embeddings UDFs entirely:

```sql
DROP SCRIPT IF EXISTS ADAPTER.SEARCH_QDRANT_LOCAL;
DROP SCRIPT IF EXISTS ADAPTER.EMBED_TEXT;
DROP SCRIPT IF EXISTS ADAPTER.EMBED_AND_PUSH_LOCAL;
```

Note: removing `SEARCH_QDRANT_LOCAL` will break virtual-schema queries (the
Lua adapter generates pushdown SQL that calls it). Removing `EMBED_TEXT`
alone is safe — it is a parity utility and not on the query hot path.
Re-install before issuing further pushDown queries against
`vector_schema.<collection>`.
