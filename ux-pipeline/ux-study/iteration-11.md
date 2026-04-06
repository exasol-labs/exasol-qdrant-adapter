# Iteration 11: Elasticsearch Migration Evaluation

**Date:** 2026-04-05
**Persona:** Migration user moving from Elasticsearch to Qdrant+Exasol
**Focus:** Feature completeness vs Elasticsearch, bulk ingestion, query flexibility
**Overall UX Score: 5.8 / 10** (weighted toward ES feature parity)

---

## Scoring Methodology

The score is weighted 60% toward Elasticsearch feature parity, 20% toward deployment/operational UX, and 20% toward data ingestion UX. This reflects the priorities of a migration user who needs to know "can this replace our current search?"

| Dimension                        | Weight | Score | Weighted |
|----------------------------------|--------|-------|----------|
| ES Query Feature Parity         | 25%    | 3/10  | 0.75     |
| Semantic Search Quality          | 15%    | 8/10  | 1.20     |
| Bulk Ingestion                   | 10%    | 6/10  | 0.60     |
| Index/Collection Management      | 10%    | 7/10  | 0.70     |
| Deployment & Setup               | 10%    | 7/10  | 0.70     |
| Query Syntax & Ergonomics        | 10%    | 5/10  | 0.50     |
| Filtering & Faceting             | 10%    | 3/10  | 0.30     |
| Monitoring & Observability       | 5%     | 2/10  | 0.10     |
| Documentation for Migrators      | 5%     | 3/10  | 0.15     |
| **TOTAL**                        | 100%   | --    | **5.00** |

Adjusted UX Score (with 0.8 bonus for working end-to-end out of box): **5.8 / 10**

---

## Deployment Summary

### What Was Deployed
- **Schema:** ADAPTER (scripts + UDFs)
- **Virtual Schema:** VS_SEARCH (pointing to Qdrant via ADAPTER.VECTOR_SCHEMA_ADAPTER)
- **Connection:** QDRANT_CONN at http://172.17.0.1:6333
- **Collections created:** product_catalog (12 docs), support_tickets (10 docs), knowledge_base (8 docs), bulk_test (50 docs)
- **Total documents ingested:** 80

### Deployment Steps Executed
1. Created ADAPTER schema
2. Created QDRANT_CONN connection
3. Deployed Lua adapter script (VECTOR_SCHEMA_ADAPTER)
4. Deployed Python UDFs (CREATE_QDRANT_COLLECTION, EMBED_AND_PUSH)
5. Created 4 Qdrant collections via UDF
6. Ingested data from 4 Exasol source tables
7. Created virtual schema, refreshed to discover collections

### Deployment Issues Encountered
- **Virtual schema ghost state:** After DROP VIRTUAL SCHEMA IF EXISTS, CREATE VIRTUAL SCHEMA can fail with "schema already exists" even though it is not found in EXA_ALL_VIRTUAL_SCHEMAS or EXA_ALL_SCHEMAS. Required using a different schema name (vs_search instead of vector_schema). This is a known Exasol issue, not adapter-specific, but severely impacts automation and CI/CD.
- **Concurrent collection pollution:** Other agents/processes creating Qdrant collections caused the virtual schema to discover unrelated tables. No way to filter which collections are exposed.
- **Ollama networking split:** The Docker bridge gateway IP (172.17.0.1) works for the Lua adapter but not for Python UDFs. UDFs must use the direct Ollama container IP (172.17.0.4). This is not documented and is extremely confusing for new users.

---

## Elasticsearch vs. Qdrant+Exasol Comparison Table

| Feature                          | Elasticsearch                    | Qdrant+Exasol Adapter         | Gap Severity |
|----------------------------------|----------------------------------|-------------------------------|--------------|
| **Full-text search (BM25)**      | Native, highly tuned             | Not supported                 | CRITICAL     |
| **Semantic/vector search**       | kNN search (8.0+)               | Native via Qdrant+Ollama      | PARITY       |
| **Hybrid search (BM25+vector)** | RRF fusion in 8.x               | Not supported                 | CRITICAL     |
| **Bool queries (must/should/must_not)** | Full DSL                  | Not supported                 | CRITICAL     |
| **Filtered queries**             | Native filter context            | Post-filter only on Exasol    | HIGH         |
| **Range queries**                | Native                           | Not supported on vector data  | HIGH         |
| **Aggregations (terms, date_histogram)** | Comprehensive           | Not supported                 | CRITICAL     |
| **Faceted search**               | Native                           | Not supported                 | CRITICAL     |
| **Fuzzy matching**               | Native (edit distance)           | Embedding similarity only     | MEDIUM       |
| **Autocomplete/suggest**         | Completion suggester             | Not supported                 | HIGH         |
| **Highlighting**                 | Native                           | Not supported                 | MEDIUM       |
| **Scroll/pagination**            | search_after, scroll API         | LIMIT only (no OFFSET pushdown) | HIGH       |
| **Bulk ingestion API**           | _bulk endpoint, streaming        | EMBED_AND_PUSH UDF (batch 100)| MEDIUM       |
| **Index aliases**                | Native                           | Virtual schema = single alias | MEDIUM       |
| **Index lifecycle management**   | ILM policies                     | Manual only                   | MEDIUM       |
| **Multi-index search**           | Cross-index in single query      | One collection per query      | HIGH         |
| **Field-level boosting**         | Native                           | Not supported                 | HIGH         |
| **Custom scoring (function_score)** | Full scripting               | Not supported                 | CRITICAL     |
| **Synonyms/analyzers**           | Custom analyzers                 | Embedding model handles this  | LOW          |
| **Relevance tuning**             | Extensive (boost, decay, etc.)   | Model choice only             | HIGH         |
| **min_score**                    | Native parameter                 | Post-filter WHERE "SCORE" > X | LOW          |
| **Geo queries**                  | geo_point, geo_shape             | Not supported                 | MEDIUM       |
| **Nested/parent-child docs**     | Native                           | Not supported                 | MEDIUM       |
| **Update by query**              | Native                           | Re-ingest entire document     | MEDIUM       |
| **Delete by query**              | Native                           | Not supported from SQL        | HIGH         |
| **Cluster management**           | Native (nodes, shards)           | Qdrant has own clustering     | N/A          |
| **REST API**                     | Native                           | SQL interface only            | NEUTRAL      |
| **Kibana/visualization**         | Native                           | Any SQL client                | NEUTRAL      |
| **EMBED_AND_PUSH_V2**            | N/A                              | Does not exist in codebase    | N/A          |

---

## Detailed Test Results

### Test 1: Basic Semantic Search (ES match query equivalent)
```sql
SELECT "ID", "TEXT", "SCORE"
FROM vs_search."PRODUCT_CATALOG"
WHERE "QUERY" = 'wireless audio device for working from home'
LIMIT 5;
```
**Result:** P001 (Wireless Headphones) ranked #1 with score 0.596. Semantically correct.
**ES comparison:** An ES match query for "wireless audio device working home" would use BM25 term matching. The semantic approach here is arguably better for intent-based queries but lacks the precision of term-level matching for exact keyword searches.

### Test 2: Cross-Collection Support Ticket Search
```sql
SELECT "ID", "TEXT", "SCORE"
FROM vs_search."SUPPORT_TICKETS"
WHERE "QUERY" = 'product quality defect warranty claim'
LIMIT 5;
```
**Result:** T003 (battery warranty) and T009 (yoga mat warranty) ranked top. Correct semantic grouping.
**ES comparison:** ES would allow combining structured filters (priority=HIGH, status=OPEN) with text search. Here, structured filtering is not possible within the vector search.

### Test 3: KB Article Retrieval (ES more_like_this equivalent)
```sql
SELECT "ID", "TEXT", "SCORE"
FROM vs_search."KNOWLEDGE_BASE"
WHERE "QUERY" = 'my thermostat lost wifi connection how to fix'
LIMIT 3;
```
**Result:** KB001 (thermostat reset guide) ranked #1 with score 0.568. Exactly the right article.
**ES comparison:** ES more_like_this would need a source document. The semantic approach is more natural here.

### Test 4: LIMIT Behavior (ES size parameter)
```sql
SELECT "ID", "SCORE"
FROM vs_search."PRODUCT_CATALOG"
WHERE "QUERY" = 'healthy drink'
LIMIT 2;
```
**Result:** P012 (Water Bottle) and P007 (Espresso Maker) returned. LIMIT correctly passed to Qdrant.

### Test 5: Post-Filtering with SCORE (ES min_score)
```sql
SELECT "ID", "SCORE"
FROM vs_search."PRODUCT_CATALOG"
WHERE "QUERY" = 'electronics'
AND "SCORE" > 0.5
LIMIT 5;
```
**Result:** 5 results returned (out of 12 total), all with score > 0.5. Works as post-filter.
**Caveat:** All 12 results are fetched from Qdrant, then filtered by Exasol. Not pushed down.

### Test 6: Post-Filtering with LIKE (ES filtered query)
```sql
SELECT "ID", "TEXT", "SCORE"
FROM vs_search."PRODUCT_CATALOG"
WHERE "QUERY" = 'outdoor adventure gear'
AND "TEXT" LIKE '%hiking%'
LIMIT 5;
```
**Result:** 1 result (P010 Hiking Boots). Text LIKE filter applied after semantic search.
**ES comparison:** ES would push the filter to the query level for efficiency. Here it is a post-filter.

### Test 7: Special Characters in Query
```sql
SELECT "ID", "SCORE"
FROM vs_search."PRODUCT_CATALOG"
WHERE "QUERY" = 'what''s the best laptop for $1000?'
LIMIT 3;
```
**Result:** P005 (Laptop) ranked #1. Special chars handled correctly by the embedding model.

### Test 8: No Query (ES match_all equivalent)
```sql
SELECT "ID", "TEXT"
FROM vs_search."PRODUCT_CATALOG"
LIMIT 5;
```
**Result:** Returns helpful error message: "Semantic search requires: WHERE QUERY = 'your search text'."
**ES comparison:** ES match_all returns all docs. This adapter requires a semantic query -- no browsing mode.

### Test 9: Bulk Ingestion (50 documents)
```sql
SELECT ADAPTER.EMBED_AND_PUSH(doc_id, doc_text, ...)
FROM TEST_DATA.BULK_TEST GROUP BY IPROC();
```
**Result:** 50 documents ingested in a single call. BATCH_SIZE=100 means single Qdrant upsert.
**ES comparison:** ES _bulk API supports thousands of docs per request with streaming. The EMBED_AND_PUSH UDF works but is limited by:
- Embedding latency (each batch requires an Ollama API call)
- No progress reporting during ingestion
- No partial failure handling (all-or-nothing per batch)
- EMBED_AND_PUSH_V2 does not exist in the codebase

### Test 10: Bulk Search on 50-doc Collection
```sql
SELECT "ID", "TEXT", "SCORE"
FROM vs_search."BULK_TEST"
WHERE "QUERY" = 'container orchestration'
LIMIT 3;
```
**Result:** All Kubernetes/Docker variations ranked at top (scores 0.597, 0.587, 0.585). Correct deduplication would be needed in production.

---

## Gap Analysis for Elasticsearch Migration

### CRITICAL Gaps (Blockers for Migration)

1. **No full-text search (BM25):** The adapter only supports semantic/vector search. ES users who rely on exact keyword matching, phrase queries, or term-level queries cannot migrate without significant query redesign. There is no way to search for an exact phrase like "Gore-Tex waterproof membrane" -- the embedding model may or may not surface it.

2. **No hybrid search:** ES 8.x supports combining BM25 with kNN via RRF. This adapter has no equivalent. For production search applications, hybrid search is increasingly table-stakes.

3. **No aggregations or faceting:** ES aggregations (terms, histograms, cardinality, etc.) are core to dashboard and analytics use cases. The adapter returns flat result rows with no aggregation capability. An ES migration user building search-powered dashboards cannot replicate this.

4. **No boolean query logic:** ES bool queries with must/should/must_not/filter clauses are the backbone of search applications. The adapter supports only a single WHERE "QUERY" = predicate. No way to express "must contain X AND should be related to Y."

5. **No custom scoring:** ES function_score with decay functions, field-value boosting, and script scoring are used extensively in e-commerce and content ranking. Not available here.

### HIGH Gaps (Significant Friction)

6. **No pushed-down filtering:** Structured metadata filters (category, price range, status) must be applied as post-filters on the Exasol side. ES pushes filters into the search query for efficiency. With large result sets, post-filtering is wasteful.

7. **No multi-index search:** ES can search across multiple indices in a single query. The adapter requires one query per collection. A migration user with cross-type search needs (e.g., search products AND knowledge base) must issue separate queries and merge results manually.

8. **No pagination beyond LIMIT:** ES provides search_after and scroll for deep pagination. The adapter supports LIMIT but OFFSET is not pushed down to Qdrant, meaning pagination for large result sets is not possible.

9. **No delete by query:** ES supports deleting documents matching a query. No equivalent exists -- users must interact with the Qdrant API directly.

10. **No field-level boosting or relevance tuning:** ES allows boosting specific fields (title^3, body^1). The adapter embeds concatenated text with no field awareness.

### MEDIUM Gaps (Workarounds Exist)

11. **No EMBED_AND_PUSH_V2:** The task requested testing this, but it does not exist in the codebase. The current EMBED_AND_PUSH works but lacks progress reporting, partial failure handling, and configurable batch sizes.

12. **No document update by query:** Must re-ingest the entire document via EMBED_AND_PUSH to update.

13. **No highlighting:** ES highlights matched terms in results. Not available here.

14. **No index lifecycle management:** ES ILM policies for rollover, retention, etc. must be managed manually in Qdrant.

### LOW Gaps (Acceptable Differences)

15. **Synonyms handled by embeddings:** ES requires explicit synonym configuration. Semantic embeddings handle synonyms naturally -- "laptop" and "notebook computer" are close in vector space. This is actually better than ES for many cases.

16. **min_score via post-filter:** WHERE "SCORE" > 0.5 works as a post-filter. Not as efficient as ES min_score but functionally equivalent for small result sets.

---

## What the Adapter Does Better Than Elasticsearch

1. **Zero-config semantic understanding:** No analyzer configuration, no synonym lists, no custom tokenizers. The embedding model handles semantic similarity out of the box. An ES user would need to set up kNN fields, mapping, and potentially fine-tune BM25 weights.

2. **SQL interface:** ES requires learning a JSON DSL or using client libraries. This adapter exposes search through standard SQL, which is immediately usable by any data analyst, BI tool, or reporting system that connects to Exasol.

3. **Data gravity:** If your data already lives in Exasol, ingesting into Qdrant from SQL is simpler than setting up Logstash/Beats pipelines to ES. The EMBED_AND_PUSH UDF lets you select from any Exasol table and vectorize it directly.

4. **Cost for simple use cases:** For a straightforward "search my documents" use case, Qdrant + Ollama (free, local) is significantly cheaper than an ES cluster.

5. **Deployment simplicity:** A single SQL file (install_all.sql) deploys everything. ES requires cluster setup, index templates, mappings, ingest pipelines, etc.

---

## Recommendations for the Project

### For Feature Parity with ES

1. **Add payload filtering pushdown:** The adapter should push Qdrant payload filters (not just the query vector) to enable structured + semantic hybrid queries. This would close the "filtered query" gap. Qdrant natively supports payload filters in search requests.

2. **Implement multi-collection search:** Allow a single query to search across multiple collections and merge results by score. This could be a special virtual table or a UNION-friendly syntax.

3. **Create EMBED_AND_PUSH_V2:** Add progress reporting (emit after each batch), configurable batch size, partial failure tolerance, and dry-run mode. This was expected by the migration user but does not exist.

4. **Support WHERE predicates on payload fields:** Map Qdrant payload fields beyond just "text" to Exasol columns. This would enable WHERE category = 'Electronics' AND "QUERY" = 'laptop' to be pushed down as a Qdrant filtered search.

5. **Add match_all equivalent:** Support queries without WHERE "QUERY" to return all documents (with optional random sampling or recency ordering).

### For Migration UX

6. **Write an ES migration guide:** Document the mapping from ES concepts to Qdrant+Exasol concepts (index -> collection, mapping -> virtual schema, _bulk -> EMBED_AND_PUSH, etc.).

7. **Add collection filtering to virtual schema:** Allow VIRTUAL SCHEMA properties to specify which collections to expose (e.g., COLLECTION_FILTER = 'product_*') to avoid pollution from unrelated collections.

8. **Fix the virtual schema ghost state:** The DROP+CREATE cycle for virtual schemas is fragile. The installer should detect and recover from ghost state automatically.

### For Production Readiness

9. **Add query latency logging:** No way to see how long the Ollama embedding + Qdrant search took. ES provides took_in_millis. Add this to the SCORE or as a separate metadata row.

10. **Add collection statistics UDF:** A UDF that returns document count, vector dimensions, and index status for a collection -- equivalent to ES _cat/indices.

---

## Raw Test Data

| Test | Query | Collection | Top Result | Score | Correct? |
|------|-------|-----------|------------|-------|----------|
| 1 | wireless audio for WFH | product_catalog | P001 Headphones | 0.596 | Yes |
| 2 | quality defect warranty | support_tickets | T003 Battery | 0.533 | Yes |
| 3 | thermostat wifi fix | knowledge_base | KB001 Reset Guide | 0.568 | Yes |
| 4 | healthy drink | product_catalog | P012 Water Bottle | 0.592 | Yes |
| 5 | electronics (score>0.5) | product_catalog | P008 Keyboard | 0.584 | Yes |
| 6 | outdoor gear + LIKE hiking | product_catalog | P010 Hiking Boots | 0.632 | Yes |
| 7 | best laptop $1000? | product_catalog | P005 Laptop | 0.567 | Yes |
| 8 | (no query) | product_catalog | Error message | 0.0 | Expected |
| 9 | container orchestration | bulk_test | BULK00001 K8s/Docker | 0.597 | Yes |

**Semantic accuracy: 9/9 (100%)** -- All queries returned semantically correct top results.

---

## Conclusion

The Exasol Qdrant adapter is a well-built semantic search tool that excels at its core mission: exposing vector similarity search through SQL. For a migration user coming from Elasticsearch, however, the feature gap is substantial. ES is a full-featured search engine with BM25, aggregations, filters, facets, and extensive query DSL. This adapter provides only one dimension of search (semantic similarity) with limited query flexibility.

**Recommendation for ES migration users:** This adapter can complement an ES deployment for semantic search use cases but cannot replace it as a general-purpose search engine. It is best suited for:
- Semantic search over existing Exasol data (data gravity advantage)
- Simple "find similar documents" use cases
- Prototyping vector search without infrastructure complexity

It is not suited for:
- Production search applications requiring faceted navigation
- Use cases requiring hybrid BM25 + vector search
- Dashboard/analytics built on ES aggregations
- Applications requiring complex boolean query logic

**Final UX Score: 5.8 / 10** -- Strong semantic search core, but significant gaps vs. Elasticsearch feature set for a migration scenario.
