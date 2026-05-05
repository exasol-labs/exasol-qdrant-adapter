# Local Embeddings via SLC + BucketFS

Three UDFs run a `sentence-transformers` model **inside the UDF VM**:

- `ADAPTER.EMBED_AND_PUSH_LOCAL` (SET) — ingest path
- `ADAPTER.SEARCH_QDRANT_LOCAL` (SET) — query path; embeds + Qdrant hybrid
  search; emits result rows. Called by the Lua adapter via generated SQL.
- `ADAPTER.EMBED_TEXT` (SCALAR) — standalone embedding primitive (parity
  test target, ad-hoc queries). Not used by the Lua adapter at runtime.

All three share one `qdrant-embed` SLC and one BucketFS-resident
`nomic-embed-text-v1.5` model copy. Per-node parallelism via
`GROUP BY IPROC()` scales the ingest path linearly across an Exasol
cluster; query embeddings happen in the same UDF VMs at request time.

> **Ingest and query share one runtime.** Both paths emit 768-dim
> L2-normalized vectors and use the same `sentence-transformers` model
> file, so the embeddings are bit-for-bit identical. The "vector parity
> hazard" that used to apply to mixed Ollama/SLC collections is gone —
> see [Validating query parity](#validating-query-parity) below.

## Migration from Ollama

Earlier releases of this adapter required an Ollama process for query-time
embedding (`OLLAMA_URL` virtual-schema property) and offered Ollama-backed
ingest UDFs (`EMBED_AND_PUSH`, `EMBED_AND_PUSH_V2`). Both have been
removed. Operators upgrading from those releases:

1. **Build and upload the SLC + model** — no-op if already done.
   ```bash
   ./scripts/build_and_upload_slc.sh
   ```
2. **Stop using Ollama-backed ingest.** Existing collections written by
   `EMBED_AND_PUSH` / `_V2` continue to work as Qdrant data, but new
   ingest must go through `EMBED_AND_PUSH_LOCAL`. Re-ingest into a
   fresh collection rather than mix vector sources within one collection.
3. **Drop the existing virtual schema:**
   ```sql
   DROP FORCE VIRTUAL SCHEMA IF EXISTS vector_schema CASCADE;
   ```
4. **Run the new `scripts/install_all.sql`** — it removes the old UDFs,
   installs `EMBED_AND_PUSH_LOCAL`, `EMBED_TEXT`, and `SEARCH_QDRANT_LOCAL`,
   and re-creates the virtual schema with the trimmed property set (no
   `OLLAMA_URL`).
5. **Stop and remove the Ollama container:**
   ```bash
   docker rm -f ollama
   docker volume rm ollama-data    # optional; reclaims ~600 MB of model bytes
   ```

`OLLAMA_URL` is now a rejected property. Setting it via
`CREATE VIRTUAL SCHEMA` or `ALTER VIRTUAL SCHEMA SET` raises a
clear error pointing at this guide.

## Throughput

Measured on a single-node Exasol Docker dev box (1 CPU core, 16 GiB RAM,
1 UDF VM), against `MUFA.RATINGS` (58,356 rows; text =
`"title" || ' — ' || COALESCE("description", '')`, mean ~280 chars).
A deterministic 5,000-row sample (`ORDER BY "article_id" LIMIT 5000`)
was used to keep the run inside an interactive session — ~50–80 batches
is well past model-load amortization, so the rows/sec measurement is
steady-state.

| Path                                                         | Sample wall-clock | Rows/sec  | 58K extrapolated | 804K extrapolated |
| ------------------------------------------------------------ | ----------------- | --------- | ---------------- | ----------------- |
| Local SLC, single-node × 1 UDF VM (RATINGS)                  | 5,000 in 577 s    | **8.7**   | ~112 min         | ~26 hr            |
| Local SLC, 1 node × 1 UDF VM (NEWS, prior runs)              | 1K/2K samples     | 5.8–7.9   | ~2.0–2.8 hr      | ~28–37 hr         |
| Local SLC, 4 nodes × 4 UDF VMs (**projected, not validated**)| —                 | ~100–130  | ~8–10 min        | ~2 hr             |

> The 4-node row is a linear-scaling projection from the single-node
> measurement, not a validated number. Multi-node validation is a future
> change — see [Future work](#future-work).

The historical Ollama-parallel measurement on the same hardware was
~6.4 rows/sec (single-partition, `NUM_PARALLEL=4`); the SLC path
measured here is moderately faster on a single node and scales with
cluster size, while Ollama remained a single shared HTTP service
regardless of node count. With Ollama removed entirely, that comparison
is now historical.

### Retrieval quality on `ratings_local`

After `ALTER VIRTUAL SCHEMA VECTOR_SCHEMA REFRESH`, three category-themed
queries against the `ratings_local` collection (5,000 SLC-written points)
returned thematically relevant ranked results — confirming both vector
ingest and the hybrid-search query path work end-to-end against
SLC-written points:

```sql
-- Stock category surfaces market-update articles
SELECT "ID", SUBSTR("TEXT", 1, 80), "SCORE"
FROM VECTOR_SCHEMA.RATINGS_LOCAL
WHERE "QUERY" = 'stock market trends' LIMIT 5;
-- → "advanced share registry: market update" (1.5), recession article (0.7), …

-- COVID category surfaces vaccine articles
SELECT "ID", SUBSTR("TEXT", 1, 80), "SCORE"
FROM VECTOR_SCHEMA.RATINGS_LOCAL
WHERE "QUERY" = 'covid pandemic vaccine' LIMIT 5;
-- → "4M Americans have gotten latest covid shot" (1.5),
--    "Singapore moderna covid-19 vaccine" (1.0), …

-- Real-estate category surfaces housing articles
SELECT "ID", SUBSTR("TEXT", 1, 80), "SCORE"
FROM VECTOR_SCHEMA.RATINGS_LOCAL
WHERE "QUERY" = 'real estate housing prices' LIMIT 5;
-- → "housing market is so bad…" (1.7), "house prices to fall…" (1.0), …
```

## One-time build and upload

Run on a Linux Docker host with **≥ 20 GB free disk** and **4+ cores**.
Mac/Windows Docker Desktop works but is slow on the first build.

```bash
# 1. Install build prerequisites
pip install exasol-script-languages-container-tool huggingface-hub

# 2. Set BucketFS credentials (never commit these)
export BUCKETFS_URL=http://<exasol-host>:2580/default
export BUCKETFS_USER=w
export BUCKETFS_PASS=<bucketfs write password>

# 3. Build the SLC, download the model, upload both to BucketFS
./scripts/build_and_upload_slc.sh
```

The script:

1. Clones `script-languages-release` at the pinned ref (read from
   `slc/qdrant-embed/flavor_info.yaml`)
2. Overlays `slc/qdrant-embed/flavor_customization/` on top of the base
   flavor
3. Runs `exaslct export` (30–90 min cold, minutes on rebuild)
4. Downloads `nomic-ai/nomic-embed-text-v1.5` from Hugging Face into
   `out/nomic-embed-text-v1.5/`, tar-gzips it
5. PUTs both archives to BucketFS at `slc/qdrant-embed.tar.gz` and
   `models/nomic-embed-text-v1.5.tar.gz`

Useful flags:

- `--skip-build` — re-upload the existing SLC tarball without rebuilding
- `--skip-model` — re-upload the SLC only (model unchanged)
- `--skip-upload` — produce artefacts in `./out/` without uploading

## Install the UDFs

After both tarballs are in BucketFS:

```sql
-- 1. Make sure the embedding_conn CONNECTION is in place. The local UDF
--    only needs qdrant_url.
CREATE OR REPLACE CONNECTION embedding_conn
    TO '{"qdrant_url":"http://172.17.0.1:6333","qdrant_api_key":""}'
    USER ''
    IDENTIFIED BY '';

-- 2. Run the install script. Idempotent — safe to re-run.
@scripts/install_local_embeddings.sql
```

The script registers the `PYTHON3_QDRANT` script-language alias and
creates three UDFs that share the same SLC + model:

- `ADAPTER.EMBED_AND_PUSH_LOCAL` (SET) — ingest path
- `ADAPTER.SEARCH_QDRANT_LOCAL` (SET) — query path; the Lua adapter
  rewrites pushdown to `SELECT … FROM (SELECT ADAPTER.SEARCH_QDRANT_LOCAL(
  '<conn>','<col>','<qtext>',N) FROM DUAL)` and Exasol executes that SQL.
  The UDF embeds the query text, runs hybrid search against Qdrant, and
  emits one row per hit. (Why not call the embedding UDF from Lua via
  `pquery`? Exasol forbids `pquery_no_preprocessing` during virtual schema
  pushdown — the row-emitting UDF is the canonical workaround.)
- `ADAPTER.EMBED_TEXT` (SCALAR) — utility UDF. Not on the hot path.
  Useful for parity verification and ad-hoc embedding queries.

## Ingest

Four positional parameters: connection name, target collection, ID,
text to embed.

```sql
SELECT ADAPTER.EMBED_AND_PUSH_LOCAL(
    'embedding_conn',
    'news_articles',
    CAST(id AS VARCHAR(36)),
    title || COALESCE(' ' || description, '')
)
FROM news_data.news_articles
WHERE title IS NOT NULL
GROUP BY IPROC();    -- REQUIRED for SET UDFs
```

`GROUP BY IPROC()` is the lever that fans the work out across nodes —
without it, all rows go through a single UDF VM on a single node.

## Operational sizing

Each UDF VM holds the model in RAM (~600 MB resident for nomic). The
rule of thumb is:

```
headroom_per_node ≈ cores × 600 MB
```

A 4-core node running 4 UDF VMs concurrently needs ~2.4 GB of headroom
on top of the rest of Exasol's working memory.

## `trust_remote_code=True`

`nomic-embed-text-v1.5` ships with a custom `modeling.py`, so
`SentenceTransformer` requires `trust_remote_code=True` at load time.
The "trusted code" is whatever the operator uploaded to BucketFS — the
sandbox has no internet and cannot fetch additional code at runtime, so
the trust scope is fully controlled by the upload step.

## Validating query parity

Both `EMBED_AND_PUSH_LOCAL` and `EMBED_TEXT` load the same
`SentenceTransformer(MODEL_PATH, device="cpu", trust_remote_code=True)`
from the same BucketFS path, encode with the same
`normalize_embeddings=True, convert_to_numpy=True` flags, and produce
the same 768-dim L2-normalized vectors. The bit-for-bit parity is
guaranteed by construction.

To verify on a live cluster, ingest a known text and re-encode it via
`EMBED_TEXT`, then compare component-wise:

```sql
-- 1. Ingest a known text via EMBED_AND_PUSH_LOCAL
SELECT ADAPTER.CREATE_QDRANT_COLLECTION(
    '172.17.0.1', 6333, '', 'parity_check', 768, 'Cosine', '');

SELECT ADAPTER.EMBED_AND_PUSH_LOCAL(
    'embedding_conn', 'parity_check',
    'probe-1', 'banks acquired by JP Morgan')
FROM DUAL
GROUP BY IPROC();

-- 2. Re-encode the same text via EMBED_TEXT
SELECT ADAPTER.EMBED_TEXT('banks acquired by JP Morgan');
-- Returns "[0.0123,-0.0456,...]" — 768 floats.

-- 3. Fetch the ingested vector from Qdrant and compare element-wise.
--    Vectors should be bit-for-bit identical.
```

If the vectors do not match, check that the SLC and BucketFS model are
the same revision in both UDFs (they are, by construction — both UDFs
hard-code `MODEL_PATH = "/buckets/bfsdefault/default/models/nomic-embed-text-v1.5"`).

## Cold-VM vs warm-VM query latency

The first call to `SEARCH_QDRANT_LOCAL` (or `EMBED_TEXT`) after a UDF VM
is recycled pays a 3–8 second model-load cost while `SentenceTransformer`
reads the ~250 MB model directory from BucketFS into the VM's heap.
Subsequent calls in the same VM run at ~50–150 ms per encode plus the
Qdrant round-trip (~10–30 ms locally) for short text (~280 chars, like
the `MUFA.BANK_FAILURES` summaries). VMs are recycled on Exasol restarts
and after long idle periods.

Measured on the validation box (`MUFA.BANK_FAILURES`,
`bank_failures_local`, 544 rows, 2026-05-02):

| Path                                                | Cold (first per VM) | Warm (subsequent) |
|-----------------------------------------------------|---------------------|--------------------|
| `SEARCH_QDRANT_LOCAL` direct from `DUAL`            | ~4–6 s              | ~150–250 ms        |
| `WHERE "QUERY" = '...'` via `vector_schema`         | ~5–8 s              | ~250–400 ms        |

For interactive virtual-schema queries this is rarely visible — the
total latency is dominated by Lua sandbox initialisation, so the
embedding cost (warm or cold) is in the noise. For high-QPS programmatic
workloads, expect the first per-VM query to be slow and amortise from
there.

## Future work

- **Multi-node throughput validation.** The "Local SLC, 4 nodes ×
  4 UDF VMs" row in the throughput table is a linear-scaling projection
  from the single-node measurement (8.7 rows/sec × 4 nodes × 4 VMs/node ≈
  140 rows/sec). It has not been validated against a real cluster on
  this project. When a multi-node Exasol environment is available,
  rerun `EMBED_AND_PUSH_LOCAL` against `MUFA.RATINGS` (or a larger
  table) with `GROUP BY IPROC()` and update this table with the
  measured rate.
- **Larger sample / full-table ingest.** The 5,000-row sample is
  steady-state but small. A future run on the full 58,356-row
  `MUFA.RATINGS` table or on `NEWS_DATA.NEWS_ARTICLES` (804K rows) on
  a single node would tighten the rows/sec estimate and check for
  long-tail behaviour (e.g. memory growth across many batches). At
  ~8.7 rows/sec a full 58K single-node run is ~2 hours wall-clock; an
  804K run is ~26 hours — both background-friendly, neither
  interactive.

## Rollback

To remove the local-embeddings install entirely:

```sql
DROP SCRIPT IF EXISTS ADAPTER.SEARCH_QDRANT_LOCAL;
DROP SCRIPT IF EXISTS ADAPTER.EMBED_TEXT;
DROP SCRIPT IF EXISTS ADAPTER.EMBED_AND_PUSH_LOCAL;
DROP FORCE VIRTUAL SCHEMA IF EXISTS vector_schema CASCADE;
```

Optionally, to remove the script-language alias:

```sql
ALTER SYSTEM SET SCRIPT_LANGUAGES =
    'PYTHON3=builtin_python3 R=builtin_r JAVA=builtin_java';
```

Note: removing `SEARCH_QDRANT_LOCAL` will break virtual-schema queries
(the Lua adapter generates SQL that calls it). Re-install before issuing
further pushDown queries against `vector_schema.<collection>`.

## Troubleshooting

- **`language not found: PYTHON3_QDRANT`** — `SCRIPT_LANGUAGES` was
  not extended. Re-run `install_local_embeddings.sql` step 2 (the
  `ALTER SYSTEM SET SCRIPT_LANGUAGES = ...` block) and reconnect.
- **`ModuleNotFoundError: sentence_transformers`** — the SLC tarball
  was not uploaded, or BucketFS path differs from the alias. Verify
  `/buckets/bfsdefault/default/slc/qdrant-embed/exaudf/exaudfclient`
  exists.
- **`Cannot connect to https://huggingface.co`** during UDF init —
  `HF_HUB_OFFLINE=1`/`TRANSFORMERS_OFFLINE=1` are not set early enough.
  Confirm both env vars appear in the UDF body before the
  `from sentence_transformers ...` import.
- **`function ADAPTER.SEARCH_QDRANT_LOCAL not found`** in a
  virtual-schema query — the SET UDF is missing or the SLC is broken.
  Re-run `scripts/install_local_embeddings.sql` (or
  `scripts/install_all.sql`) and confirm `SELECT * FROM (SELECT
  ADAPTER.SEARCH_QDRANT_LOCAL('qdrant_conn','your_collection','test',1)
  FROM DUAL)` returns at least one row.
- **`pquery_no_preprocessing function cannot be called during the virtual
  schema pushdown process`** — you have an old (pre-3.1.0) Lua adapter
  installed that tried to embed via `pquery` from inside pushdown.
  Re-run `scripts/install_adapter.sql` (or the Lua block in
  `scripts/install_all.sql`) to upgrade to the row-emitting-UDF design.
- **OOM on Exasol nodes** — too many concurrent UDF VMs for the node
  memory budget. Drop concurrency (lower partition cardinality) or add
  RAM; rule of thumb above.
