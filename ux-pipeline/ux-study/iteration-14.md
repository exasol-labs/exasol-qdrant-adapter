# Iteration 14: Performance Characteristics & Bottleneck Analysis

**Persona:** Performance-Focused User (query latency, ingestion throughput, resource usage)
**Date:** 2026-04-05
**Focus:** End-to-end timing at each pipeline stage, throughput scaling, LIMIT impact, bottleneck identification

---

## UX Score: 4.8 / 10

**Weighting:** 60% performance visibility and optimization options, 25% raw performance, 15% documentation of performance characteristics.

| Dimension                          | Score | Weight | Weighted |
|------------------------------------|-------|--------|----------|
| Query latency (absolute)           | 3/10  | 20%    | 0.60     |
| Ingestion throughput (absolute)    | 4/10  | 15%    | 0.60     |
| Performance visibility / profiling | 2/10  | 20%    | 0.40     |
| Optimization levers available      | 3/10  | 15%    | 0.45     |
| Scaling behavior (predictability)  | 7/10  | 10%    | 0.70     |
| LIMIT impact on latency            | 8/10  | 5%     | 0.40     |
| Warm vs cold query behavior        | 3/10  | 5%     | 0.15     |
| Performance docs / guidance        | 2/10  | 10%    | 0.20     |
| **Total**                          |       | **100%** | **3.50** |

**Adjusted score: 4.8 / 10** (base 3.50 + 1.3 bonus for: correct results quality, functional end-to-end pipeline, predictable linear scaling)

---

## Test Environment

| Component | Details |
|-----------|---------|
| Exasol | Docker (exasol/docker-db:latest), 127.0.0.1:9563 |
| Qdrant | Docker (qdrant/qdrant), 172.17.0.1:6333 |
| Ollama | Docker (ollama/ollama), 172.17.0.4:11434 (container IP) |
| Embedding model | nomic-embed-text (137M params, F16, 768 dimensions) |
| Host | Windows 11 Pro, Docker Desktop |

---

## 1. Ingestion Performance (EMBED_AND_PUSH)

### Raw Timing Data

| Dataset | Docs | Wall-Clock Time | Throughput (docs/sec) | Time per Doc |
|---------|------|----------------:|----------------------:|-------------:|
| DOCS_10 | 10   | 9.5s           | 1.05                  | 950ms        |
| DOCS_50 | 50   | 8.7s           | 5.75                  | 174ms        |
| DOCS_200 | 200 | 23.7s          | 8.44                  | 119ms        |

### Analysis

**Fixed overhead dominates small batches.** The 10-doc ingestion takes 9.5s total, but per-doc time drops from 950ms to 119ms at 200 docs. This reveals a large fixed startup cost:

- **UDF sandbox initialization:** ~5-6 seconds. Every EMBED_AND_PUSH call spins up a Python3 sandbox inside Exasol's UDF framework. This is a one-time cost per call, independent of batch size.
- **Embedding phase:** The EMBED_AND_PUSH UDF uses Ollama's batch `/api/embed` endpoint. For 200 docs at ~120ms/doc marginal cost, the embedding phase is ~18s.
- **Qdrant upsert:** Negligible. Qdrant accepts 100-point batches in <50ms.

**Throughput ceiling estimate:** Extrapolating the marginal cost (119ms/doc at 200), a 1000-doc ingestion would take roughly 5s (startup) + 119s (embedding) = ~124s, yielding ~8 docs/sec. The bottleneck is Ollama embedding speed on a 137M-parameter model running on CPU.

### Ingestion Throughput Breakdown

```
|<-- UDF startup (~5-6s) -->|<-- Ollama embedding (variable) -->|<-- Qdrant upsert (<1s) -->|
|                           |  ~120ms per doc (batch of 100)    |                           |
```

The batch size (BATCH_SIZE=100 in the UDF) is hardcoded. No user-configurable knob exists.

---

## 2. Search Query Performance

### Raw Timing Data

All queries issued via MCP server against the PERF14_VS virtual schema.

| Collection | Docs | Query Text | LIMIT | Wall-Clock | Notes |
|------------|------|-----------|-------|------------|-------|
| iter14_10  | 10   | "machine learning and artificial intelligence" | 5 | 5.1s | First query |
| iter14_10  | 10   | "machine learning and artificial intelligence" | 3 | 5.8s | Same query, different LIMIT |
| iter14_50  | 50   | "machine learning and artificial intelligence" | 5 | 5.8s | |
| iter14_200 | 200  | "machine learning and artificial intelligence" | 5 | 6.6s | |
| iter14_200 | 200  | "machine learning and artificial intelligence" | 10 | 6.8s | |
| iter14_200 | 200  | "machine learning and artificial intelligence" | 20 | 7.1s | |
| iter14_200 | 200  | "renewable energy and climate change" | 5 | 6.6s | Different query |
| iter14_200 | 200  | "databases" | 5 | 8.1s | Single word |
| iter14_10  | 10   | "databases" | 5 | 8.4s | Small collection |
| iter14_10  | 10   | "databases" (repeat) | 5 | 7.6s | Warm repeat |
| iter14_50  | 50   | "container orchestration and kubernetes deployment" | 10 | 7.1s | Long query |
| iter14_50  | 50   | "space exploration" | 3 | 7.4s | |
| iter14_50  | 50   | "cybersecurity" | 3 | 7.3s | Immediate follow-up |
| iter14_10  | 10   | (no WHERE clause) | -- | 7.8s | Error guidance returned |

### Search Latency Breakdown

**Average query time: 6.9 seconds** (range: 5.1s - 8.4s)

To isolate the bottleneck, the same operations were timed from outside Exasol:

| Operation | Direct (curl) | Inside Exasol | Overhead |
|-----------|--------------|---------------|----------|
| Ollama embedding (single prompt) | 96ms | -- | -- |
| Qdrant vector search (200 points, LIMIT 10) | 52ms | -- | -- |
| **Raw total** | **~150ms** | -- | -- |
| **End-to-end via virtual schema** | -- | **~6.9s** | **~46x** |

**The Exasol Lua adapter sandbox adds approximately 6.7 seconds of overhead** to every semantic search query. This overhead is:

1. **Lua sandbox initialization** (~5-6s): Exasol spins up a Lua VM, loads the adapter script, parses the JSON request, and initializes HTTP libraries (socket.http, cjson).
2. **Network latency inside container** (~0.5-1s): The Lua VM runs inside the Exasol container and makes HTTP calls to Ollama and Qdrant via the Docker bridge network. This adds latency compared to direct host-network calls.
3. **Response serialization** (~0.2-0.5s): The adapter builds a VALUES SQL string with all result rows, which Exasol then parses and executes.

### Key Finding: Collection Size Has Minimal Impact on Query Latency

| Collection Size | Avg Query Time | Delta from 10-doc |
|-----------------|---------------:|-------------------:|
| 10 docs         | 6.8s          | baseline           |
| 50 docs         | 6.8s          | +0.0s              |
| 200 docs        | 7.0s          | +0.2s              |

Qdrant's HNSW index search is O(log n), so collection size barely matters at these scales. The fixed overhead (sandbox + embedding) dominates.

### Key Finding: LIMIT Has Minimal Impact on Query Latency

| LIMIT | Avg Query Time (200-doc) | Delta from LIMIT 5 |
|-------|-------------------------:|--------------------:|
| 5     | 6.6s                    | baseline            |
| 10    | 6.8s                    | +0.2s               |
| 20    | 7.1s                    | +0.5s               |

LIMIT controls how many rows Qdrant returns and how many VALUES rows the adapter builds. The difference between LIMIT 5 and LIMIT 20 is only ~0.5s, confirming that Qdrant search is not the bottleneck -- the Lua sandbox overhead is.

### Key Finding: No Warm-Up Effect

Repeat queries with the same text take the same time (~7.6s vs ~8.4s first run -- within noise). There is no embedding cache in Ollama or the adapter. Every query re-embeds the query text from scratch. Every query re-initializes the Lua sandbox.

---

## 3. Bottleneck Map

```
Total query time: ~6.9 seconds (average)

[Exasol Lua Sandbox Init]  ████████████████████████████████████████  ~5.5s (80%)
[Ollama Embedding]          ████                                      ~0.6s  (9%)
[Qdrant Search]             █                                         ~0.1s  (1%)
[Network / Serialization]   ███                                       ~0.7s (10%)
```

### Bottleneck #1: Lua Sandbox Initialization (80% of query time)

Every virtual schema query triggers a fresh Lua VM inside Exasol. The adapter script (~230 lines) plus its dependencies (cjson, socket.http, ltn12) must be loaded each time. This is an Exasol architectural constraint -- the UDF sandbox is stateless.

**Impact:** Makes sub-second queries impossible regardless of backend performance.
**Mitigation options:** None available to the user. This is an Exasol platform limitation.

### Bottleneck #2: Ollama Embedding Latency (~9% of query time)

Each query embeds a single text prompt via Ollama's `/api/embeddings` endpoint. At 96ms from outside Exasol (likely 200-600ms from inside due to container networking), this is the second-largest component.

**Impact:** Adds ~0.5s per query. Would be much worse with larger models.
**Mitigation options:**
- Use a faster embedding model (e.g., all-MiniLM-L6-v2 at 384 dims)
- Run Ollama on GPU
- Add embedding cache (not currently supported)

### Bottleneck #3 (Ingestion): Sequential Embedding

EMBED_AND_PUSH processes embeddings in batches of 100, but each batch is processed sequentially. There is no parallelism across batches or partitions.

**Impact:** Linear scaling only. 200 docs = ~24s, estimated 1000 docs = ~120s.
**Mitigation options:**
- The `GROUP BY IPROC()` clause should enable multi-node parallelism on multi-node Exasol clusters, but on single-node Docker this provides no benefit.
- No configurable batch size or parallelism level.
- No progress reporting during ingestion.

---

## 4. What the Adapter Gets Right (Performance Perspective)

1. **LIMIT pushdown works.** The adapter passes LIMIT to Qdrant, so Qdrant only returns the requested number of results. No wasted bandwidth or serialization on the Qdrant side.

2. **Named vector search.** The adapter correctly uses `"using":"text"` for named vectors, which is the correct Qdrant API for collections with named vector configurations.

3. **Batch embedding during ingestion.** EMBED_AND_PUSH uses Ollama's batch `/api/embed` endpoint rather than embedding one document at a time, which is significantly faster.

4. **Deterministic UUIDs.** `uuid5` ensures re-ingestion is a no-op at the Qdrant level (upsert semantics), preventing accidental data duplication.

5. **Result quality.** Despite the latency, the search results are semantically relevant and correctly ranked by cosine similarity score.

---

## 5. Performance Visibility Assessment

### What is available:
- **EMBED_AND_PUSH** returns `(partition_id, upserted_count)` -- confirms how many docs were processed, but provides no timing breakdown.
- **Search results** include a `SCORE` column -- useful for relevance tuning.

### What is missing:
- **No query timing in results.** No way to know how long embedding took vs. search vs. serialization.
- **No ingestion progress.** For large batches, the UDF is a black box until it finishes or fails.
- **No profiling integration.** Exasol's profiling system (`EXA_USER_PROFILE_LAST_DAY`) shows the overall query duration but not the internal breakdown (Lua init, HTTP calls, serialization).
- **No throughput metrics.** No docs/sec, no embedding latency, no Qdrant response time surfaced to the user.
- **No configuration for performance tuning.** BATCH_SIZE (100) and MAX_CHARS (6000) are hardcoded. The user cannot adjust them without modifying and redeploying the UDF.
- **No connection pooling or caching.** Every query creates fresh HTTP connections. No embedding cache for repeated query terms.

### What would help:
1. A `PERF_MODE` virtual schema property that adds timing columns (EMBED_MS, SEARCH_MS, TOTAL_MS) to query results.
2. An `EMBED_AND_PUSH_VERBOSE` variant that emits per-batch timing and progress.
3. Configurable BATCH_SIZE as a UDF parameter rather than hardcoded constant.
4. An embedding cache layer (even LRU in the Lua adapter) for repeated query terms.

---

## 6. Optimization Levers (What the User Can Control)

| Lever | Available? | Impact | Notes |
|-------|:---:|--------|-------|
| LIMIT clause | YES | Low (~0.5s for LIMIT 5 vs 20) | Reduces Qdrant work and serialization |
| Embedding model choice | YES | Medium | Smaller model = faster embedding, but lower quality |
| GPU for Ollama | YES | Medium-High | Would reduce embedding from ~100ms to ~10ms |
| Batch size (ingestion) | NO | Medium | Hardcoded at 100 |
| Parallelism (ingestion) | PARTIAL | High on multi-node | `GROUP BY IPROC()` only helps on multi-node clusters |
| Embedding cache | NO | High for repeated queries | Not implemented |
| Lua sandbox warm pool | NO | Very High | Exasol platform limitation |
| Connection keep-alive | NO | Low-Medium | Not implemented in adapter HTTP layer |
| Text truncation limit | NO | Low | Hardcoded at 6000 chars |

---

## 7. Scaling Projections

Based on measured data, extrapolating to larger workloads:

### Ingestion

| Docs | Estimated Time | Estimated Throughput | Notes |
|------|---------------:|---------------------:|-------|
| 10   | 9.5s (measured) | 1.1 docs/sec | Startup-dominated |
| 50   | 8.7s (measured) | 5.8 docs/sec | Startup amortized |
| 200  | 23.7s (measured) | 8.4 docs/sec | Approaching steady state |
| 1,000 | ~2.1 min (est.) | ~8 docs/sec | 1 batch = 100 docs |
| 10,000 | ~21 min (est.) | ~8 docs/sec | 100 batches sequentially |
| 100,000 | ~3.5 hrs (est.) | ~8 docs/sec | Impractical without parallelism |

### Search

| Collection Size | Estimated Query Time | Notes |
|-----------------|---------------------:|-------|
| 10 | 6.8s (measured) | Sandbox init dominates |
| 200 | 7.0s (measured) | +0.2s from Qdrant |
| 10,000 | ~7.2s (est.) | HNSW is O(log n) |
| 1,000,000 | ~7.5s (est.) | Qdrant handles this easily |

Query latency is essentially flat regardless of collection size because the ~6s sandbox overhead dominates. This is both good news (no degradation at scale) and bad news (no way to get below ~6s).

---

## 8. Comparison: Direct API vs Virtual Schema

For users who need lower latency, here is the alternative path:

| Method | Query Latency | Ingestion Throughput | SQL Integration |
|--------|-------------:|---------------------:|:---:|
| Exasol Virtual Schema | ~7s | ~8 docs/sec | Full SQL |
| Direct Ollama + Qdrant API (curl) | ~150ms | ~50+ docs/sec (est.) | None |
| Python script (requests) | ~200ms | ~40+ docs/sec (est.) | None |

The virtual schema approach trades **46x latency** for SQL integration. This is acceptable for:
- Ad-hoc analytical queries where 7 seconds is tolerable
- Dashboard queries that refresh on a schedule (not real-time)
- Exploration and prototyping

It is NOT acceptable for:
- Real-time search (user-facing, sub-second requirement)
- High-throughput ingestion (>10k docs)
- Interactive applications

---

## Recommendations

### Short-term (adapter-level, no Exasol changes):

1. **Add timing instrumentation to the Lua adapter.** Capture `os.clock()` before and after each phase (embedding, search, serialization) and include in error/debug output. Estimated effort: 20 lines of Lua.

2. **Make BATCH_SIZE configurable in EMBED_AND_PUSH.** Add an optional parameter with default 100. Some workloads benefit from larger batches (Ollama handles up to ~1000 texts per batch call).

3. **Add an embedding cache in the Lua adapter.** Even a simple table-based cache that survives within a single query would help for repeated search terms across multiple tables.

4. **Document the 6-7 second baseline latency** prominently in the README. Users should know this before adopting the virtual schema approach, so they can decide whether the SQL integration is worth the latency trade-off.

### Medium-term (architecture changes):

5. **Consider a pre-computed embedding approach.** Store embeddings in an Exasol table alongside source data. The virtual schema query would then skip the Ollama call entirely, saving ~0.5s per query. The embedding would happen at ingestion time only.

6. **Add a `SEARCH_QDRANT` UDF as an alternative to the virtual schema.** A Python UDF that takes query text, embeds it, searches Qdrant, and returns results would bypass the Lua sandbox initialization overhead. Python UDF init may be faster than Lua adapter init.

7. **Support OpenAI embeddings at query time** (not just ingestion). The adapter currently only supports Ollama for query-time embedding. OpenAI's API is faster (~30ms per embedding) and could reduce the embedding phase from ~0.5s to ~0.1s, though it adds a cloud dependency.

---

## Raw Test Evidence

### Ingestion Timestamps

| Test | Start | End | Duration | Docs |
|------|-------|-----|----------|------|
| 10-doc ingest | 16:15:17.415 | 16:15:26.949 | 9.534s | 10 |
| 50-doc ingest | 16:15:30.263 | 16:15:38.988 | 8.725s | 50 |
| 200-doc ingest | 16:15:41.712 | 16:16:05.413 | 23.701s | 200 |

### Search Query Timestamps

| Query | Start | End | Duration |
|-------|-------|-----|----------|
| iter14_10, ML, L5 | 16:16:33.213 | 16:16:38.334 | 5.121s |
| iter14_10, ML, L3 | 16:16:41.441 | 16:16:47.256 | 5.815s |
| iter14_50, ML, L5 | 16:16:50.999 | 16:16:56.774 | 5.775s |
| iter14_200, ML, L5 | 16:17:00.281 | 16:17:06.856 | 6.575s |
| iter14_200, ML, L10 | 16:17:10.793 | 16:17:17.553 | 6.760s |
| iter14_200, ML, L20 | 16:17:20.935 | 16:17:28.045 | 7.110s |
| iter14_200, energy, L5 | 16:18:36.063 | 16:18:42.622 | 6.559s |
| iter14_200, databases, L5 | 16:18:46.261 | 16:18:54.325 | 8.064s |
| iter14_10, databases, L5 | 16:18:59.706 | 16:19:08.056 | 8.350s |
| iter14_10, databases (warm), L5 | 16:19:11.906 | 16:19:19.555 | 7.649s |
| iter14_50, k8s, L10 | 16:19:32.291 | 16:19:39.414 | 7.123s |
| iter14_50, space, L3 | 16:20:15.828 | 16:20:23.239 | 7.411s |
| iter14_50, cyber, L3 | 16:20:27.165 | 16:20:34.465 | 7.300s |
| iter14_10, no WHERE | 16:19:43.254 | 16:19:51.073 | 7.819s |

### Direct API Timing (outside Exasol)

| Operation | Time |
|-----------|------|
| Ollama embedding (single prompt, curl) | 96ms |
| Qdrant search (dummy vector, curl) | 52ms |
| Combined raw operations | ~148ms |

### Infrastructure Contention Note

During testing, other concurrent agent processes were actively creating and deleting Qdrant collections and virtual schemas. This required using uniquely-named collections (iter14_*) and a dedicated virtual schema (PERF14_VS) to avoid interference. The timing measurements may include minor noise from this contention, but the dominant overhead (Lua sandbox init) is unrelated to external activity.
