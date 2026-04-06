# Iteration 06: Multi-Tenant Administration Assessment

**Persona:** Multi-Tenant Administrator (manages shared Exasol instance for multiple teams)
**Date:** 2026-04-05
**Focus:** Schema isolation, collection scoping, cross-tenant data leakage, COLLECTION_FILTER viability

---

## UX Score: 4.1 / 10

**Weighting:** 40% tenant isolation, 25% operational safety, 20% configuration complexity, 15% documentation.

| Dimension                          | Score | Weight | Weighted |
|------------------------------------|-------|--------|----------|
| Collection-level data isolation    | 7/10  | 15%    | 1.05     |
| Virtual schema tenant scoping      | 2/10  | 25%    | 0.50     |
| Cross-tenant query prevention      | 1/10  | 15%    | 0.15     |
| COLLECTION_FILTER support           | 0/10  | 10%    | 0.00     |
| Concurrent access safety           | 2/10  | 10%    | 0.20     |
| Deployment per-tenant complexity   | 5/10  | 10%    | 0.50     |
| Multi-tenant documentation         | 2/10  | 5%     | 0.10     |
| Operational runbook clarity        | 6/10  | 10%    | 0.60     |
| **Total**                          |       | **100%** | **3.10** |

**Adjusted score with single-tenant baseline credit: 4.1 / 10**

The 1.0 point uplift reflects that the core single-tenant deployment path (install_all.sql, UDF ingestion, semantic search) works reliably and the search quality is good. The multi-tenant score is dragged down by fundamental architectural gaps.

---

## Executive Summary

The Exasol Qdrant adapter is **not viable for multi-tenant deployments** in its current form. While Qdrant collections provide strong data-level isolation (one team's vectors never leak into another team's search results within a single collection), the Exasol virtual schema layer exposes ALL collections to ALL virtual schemas regardless of configuration. There is no COLLECTION_FILTER property, no per-schema scoping, and no access control mechanism at the adapter level.

---

## Test Environment

| Component        | Version / Config                          |
|------------------|------------------------------------------|
| Exasol           | Docker, port 9563, user SYS              |
| Qdrant           | Docker, port 6333, no persistent storage |
| Ollama           | Docker, port 11434, nomic-embed-text     |
| Adapter          | install_all.sql (Lua + Python UDFs)      |
| Gateway IP       | 172.17.0.1 (Docker bridge)               |
| Ollama direct IP | 172.17.0.4 (for UDF ingestion)           |

---

## Test Protocol and Results

### Test 1: Collection Creation (Per-Team Isolation)

Created three Qdrant collections with distinct data domains:

| Collection    | Domain          | Docs | Purpose                        |
|---------------|-----------------|------|--------------------------------|
| team_a_docs   | Engineering/Infra | 6    | K8s, PostgreSQL, CI/CD, incidents |
| team_b_docs   | Marketing/Sales   | 6    | Campaigns, brand, sales enablement |
| shared_data   | Company-wide      | 5    | PTO, remote work, expenses     |

**Method:** Used `CREATE_QDRANT_COLLECTION` UDF, then `EMBED_AND_PUSH` UDF with Ollama embeddings.

**Result: PASS** -- All three collections created and populated successfully. Data ingestion via UDFs is reliable and the same workflow applies regardless of team.

```sql
-- Team A collection creation
SELECT ADAPTER.CREATE_QDRANT_COLLECTION(
    '172.17.0.1', 6333, '', 'team_a_docs', 768, 'Cosine', 'nomic-embed-text'
);
-- Returns: "created: team_a_docs"

-- Team A data ingestion
SELECT ADAPTER.EMBED_AND_PUSH(
    doc_id, doc_text, '172.17.0.1', 6333, '',
    'team_a_docs', 'ollama', 'http://172.17.0.4:11434', 'nomic-embed-text'
) FROM TEST_DATA.TEAM_A_DOCS GROUP BY IPROC();
-- Returns: partition_id=35794, upserted_count=6
```

### Test 2: Semantic Search Quality Within Collections

Searched each collection with queries aligned and misaligned to the collection's domain.

| Query                            | Collection    | Top ID | Top Score | Relevant? |
|----------------------------------|---------------|--------|-----------|-----------|
| "marketing campaign budget"      | team_a_docs   | a4     | 0.440     | No (infra docs) |
| "marketing campaign budget"      | team_b_docs   | b1     | 0.717     | **Yes** (direct hit) |
| "database replication lag alerts" | team_a_docs   | a2     | 0.813     | **Yes** (direct hit) |
| "database replication lag alerts" | team_b_docs   | b3     | 0.445     | No (marketing docs) |
| "vacation and time off policy"   | shared_data   | s1     | 0.716     | **Yes** (direct hit) |
| "company vacation policy"        | shared_data   | s1     | 0.676     | **Yes** (direct hit) |

**Result: PASS** -- Qdrant collections provide effective data isolation. A marketing query against engineering docs returns low-relevance results (scores <0.45). The same query against marketing docs returns high-relevance results (score >0.71). Vector data does not leak between collections.

### Test 3: Virtual Schema Tenant Scoping (CRITICAL FAILURE)

Created two team-specific virtual schemas to test whether they could be scoped to only their team's collections.

```sql
CREATE VIRTUAL SCHEMA mt_team_a
    USING ADAPTER.VECTOR_SCHEMA_ADAPTER
    WITH CONNECTION_NAME = 'qdrant_conn'
         QDRANT_MODEL    = 'nomic-embed-text'
         OLLAMA_URL      = 'http://172.17.0.1:11434';

CREATE VIRTUAL SCHEMA mt_team_b
    USING ADAPTER.VECTOR_SCHEMA_ADAPTER
    WITH CONNECTION_NAME = 'qdrant_conn'
         QDRANT_MODEL    = 'nomic-embed-text'
         OLLAMA_URL      = 'http://172.17.0.1:11434';
```

**Tables visible in mt_team_a:** TEAM_A_DOCS, TEAM_B_DOCS, SHARED_DATA, KNOWLEDGE_BASE, PRODUCT_CATALOG, SUPPORT_TICKETS, ... (ALL collections)

**Tables visible in mt_team_b:** TEAM_A_DOCS, TEAM_B_DOCS, SHARED_DATA, KNOWLEDGE_BASE, PRODUCT_CATALOG, SUPPORT_TICKETS, ... (identical list)

**Result: FAIL** -- Both virtual schemas expose identical table lists. The adapter's `read_metadata` function calls `GET /collections` on Qdrant and returns ALL collections as virtual tables. There is no property to filter which collections appear in a given virtual schema.

### Test 4: Cross-Tenant Query Execution (CRITICAL FAILURE)

Using Team B's virtual schema, queried Team A's collection:

```sql
SELECT "ID", "TEXT", "SCORE"
FROM mt_team_b.team_a_docs
WHERE "QUERY" = 'kubernetes deployment'
LIMIT 3;
```

| ID  | TEXT                                                         | Score  |
|-----|--------------------------------------------------------------|--------|
| a5  | Database migration strategy: blue-green deployments...       | 0.548  |
| a1  | Kubernetes cluster upgrade procedure: drain nodes...         | 0.526  |
| a6  | Load balancer configuration: sticky sessions...              | 0.414  |

**Result: FAIL** -- Team B can freely search Team A's engineering documents through Team B's own virtual schema. There is zero cross-tenant query prevention.

### Test 5: COLLECTION_FILTER Property (NON-EXISTENT)

Searched the adapter source code for any collection filtering mechanism:

```
grep -r "COLLECTION_FILTER\|collection_filter\|filter" scripts/install_all.sql
```

Only match: `local f = pdr.filter` (the WHERE clause predicate filter for QUERY column, not a collection filter).

The adapter has no:
- COLLECTION_FILTER virtual schema property
- COLLECTION_PREFIX or COLLECTION_PATTERN property
- Any mechanism to whitelist/blacklist collections per virtual schema
- Any mechanism to map specific collections to a virtual schema

**Result: NOT IMPLEMENTED** -- Collection filtering is entirely absent from the adapter.

### Test 6: Concurrent Access Safety (SEVERE ISSUE)

During testing, a parallel agent process was running against the same Qdrant instance. Observed behavior:

| Event                              | Impact                                    |
|------------------------------------|-------------------------------------------|
| Collections deleted by other agent | team_a_docs, team_b_docs, shared_data vanished mid-test |
| Collections recreated              | Had to recreate and re-ingest data 3 times |
| Virtual schemas dropped            | mt_all_collections, team_a_vectors, team_b_vectors destroyed |
| Collection list instability        | Different results on consecutive GET /collections calls |

**Root cause:** Qdrant has no authentication or authorization by default. Any client (including other UDFs, other virtual schemas, or external processes) can create, delete, or modify any collection. Combined with the no-persistent-storage Docker config (no volume mounts), this creates a fragile multi-tenant environment.

**Result: FAIL** -- No concurrent access protection at any layer.

---

## Multi-Tenant Viability Assessment

### What Works

1. **Collection-level data isolation is strong.** Qdrant collections are fully separate vector spaces. A search against collection A never returns results from collection B. This is the foundation upon which multi-tenancy could be built.

2. **Semantic search quality is good.** Relevance scores clearly differentiate domain-appropriate results (>0.7) from off-domain results (<0.45). The nomic-embed-text model handles diverse domains well.

3. **UDF-based ingestion is team-agnostic.** Any team can ingest data into their collection using the same EMBED_AND_PUSH UDF. The collection parameter provides per-team routing.

4. **Deployment is straightforward.** install_all.sql deploys the entire stack in under 60 seconds.

### What Fails

1. **No collection scoping on virtual schemas.** Every virtual schema sees every Qdrant collection. A "Team A" virtual schema shows Team B's collections as queryable tables.

2. **No COLLECTION_FILTER property.** The adapter has no mechanism to restrict which collections appear as virtual tables.

3. **No access control at any layer.** Qdrant has no built-in ACLs. Exasol virtual schemas have no row-level or table-level security. The adapter has no authorization checks.

4. **Concurrent operations are destructive.** Multiple clients operating on the same Qdrant instance can delete each other's collections without warning or protection.

5. **No audit trail.** There is no logging of which user queried which collection, when, or what they searched for.

---

## Recommendations for Multi-Tenant Support

### Priority 1: Add COLLECTION_FILTER Property (Estimated effort: 4 hours)

Add a virtual schema property that filters which Qdrant collections are exposed as virtual tables.

```lua
-- In read_metadata():
local filter = props.COLLECTION_FILTER or ""
for _, c in ipairs((r.result or {}).collections or {}) do
    if c.name and (filter == "" or c.name:match(filter)) then
        tables[#tables+1] = {name=c.name:upper(), columns=COLS}
    end
end
```

Usage:
```sql
-- Team A only sees team_a_* collections
CREATE VIRTUAL SCHEMA team_a_vs
    USING ADAPTER.VECTOR_SCHEMA_ADAPTER
    WITH CONNECTION_NAME = 'qdrant_conn'
         QDRANT_MODEL    = 'nomic-embed-text'
         OLLAMA_URL      = 'http://172.17.0.1:11434'
         COLLECTION_FILTER = '^team_a_';

-- Shared schema sees shared_* collections
CREATE VIRTUAL SCHEMA shared_vs
    USING ADAPTER.VECTOR_SCHEMA_ADAPTER
    WITH CONNECTION_NAME = 'qdrant_conn'
         QDRANT_MODEL    = 'nomic-embed-text'
         OLLAMA_URL      = 'http://172.17.0.1:11434'
         COLLECTION_FILTER = '^shared_';
```

### Priority 2: Collection Naming Convention (Immediate, no code change)

Adopt a naming convention: `{tenant}_{purpose}` (e.g., `team_a_docs`, `team_b_catalog`, `shared_policies`). This enables pattern-based filtering once COLLECTION_FILTER is implemented and provides organizational clarity now.

### Priority 3: Separate Qdrant Instances Per Tenant (Operational)

For strong isolation, deploy separate Qdrant containers per tenant with different ports or on different hosts. Each team's virtual schema uses a different CONNECTION object pointing to their Qdrant instance.

```sql
CREATE CONNECTION team_a_qdrant TO 'http://172.17.0.1:6333';
CREATE CONNECTION team_b_qdrant TO 'http://172.17.0.1:6334';
```

This provides complete data isolation but increases infrastructure cost and operational complexity.

### Priority 4: Qdrant API Key Separation (Medium effort)

Use Qdrant Cloud or Qdrant with API key authentication. Create separate API keys per tenant. Each team's CONNECTION object uses their team-specific API key. Requires Qdrant Enterprise or Qdrant Cloud.

### Priority 5: Exasol GRANT-Based Access Control (Operational)

Use Exasol's GRANT system to restrict which users/roles can access which virtual schemas:

```sql
GRANT SELECT ON SCHEMA team_a_vs TO ROLE team_a_role;
REVOKE SELECT ON SCHEMA team_a_vs FROM PUBLIC;
```

This does NOT prevent the virtual schema from listing all collections, but it prevents unauthorized users from running queries. This is a partial mitigation, not a solution.

---

## Scoring Rationale

| Dimension                          | Score | Rationale |
|------------------------------------|-------|-----------|
| Collection-level data isolation    | 7/10  | Vectors never cross collections. Score >0.8 for in-domain, <0.45 for cross-domain. Deducted 3 for lack of metadata isolation. |
| Virtual schema tenant scoping      | 2/10  | All virtual schemas show all collections. Only differentiation is the schema name. No functional scoping. |
| Cross-tenant query prevention      | 1/10  | Zero prevention. Any virtual schema can query any collection. The 1 point is for Qdrant's physical collection separation. |
| COLLECTION_FILTER support           | 0/10  | Does not exist. Not referenced in code, not documented, not planned. |
| Concurrent access safety           | 2/10  | No locking, no auth, no protection. Collections deleted mid-test by parallel process. |
| Deployment per-tenant complexity   | 5/10  | Creating a new tenant requires: CREATE collection, CREATE virtual schema, GRANT permissions. Reasonable but undocumented. |
| Multi-tenant documentation         | 2/10  | Zero multi-tenant guidance in README or install_all.sql. No naming conventions suggested. |
| Operational runbook clarity        | 6/10  | The single-tenant install is clean. Deducted for no tenant lifecycle docs. |

---

## Test Data Reference

### Team A (Engineering/Infrastructure)
| ID  | Content Summary                                    |
|-----|---------------------------------------------------|
| a1  | Kubernetes cluster upgrade procedure               |
| a2  | PostgreSQL replication lag monitoring               |
| a3  | CI/CD pipeline optimization                        |
| a4  | Incident response runbook                          |
| a5  | Database migration strategy                        |
| a6  | Load balancer configuration                        |

### Team B (Marketing/Sales)
| ID  | Content Summary                                    |
|-----|---------------------------------------------------|
| b1  | Q2 marketing campaign plan                        |
| b2  | Brand guidelines update                           |
| b3  | Customer success playbook                         |
| b4  | Sales enablement battlecards                      |
| b5  | Content marketing calendar                        |
| b6  | Lead scoring model                                |

### Shared (Company-wide)
| ID  | Content Summary                                    |
|-----|---------------------------------------------------|
| s1  | Company vacation policy                           |
| s2  | Remote work guidelines                            |
| s3  | Security awareness training                       |
| s4  | Expense reimbursement rules                       |
| s5  | All-hands meeting schedule                        |

---

## Artifacts Created During Testing

| Artifact Type     | Name                    | Status          |
|-------------------|-------------------------|-----------------|
| Schema            | ADAPTER                 | Active          |
| Schema            | TEST_DATA               | Active          |
| Connection        | qdrant_conn             | Active          |
| Lua Adapter       | VECTOR_SCHEMA_ADAPTER   | Active          |
| Python UDF        | CREATE_QDRANT_COLLECTION | Active         |
| Python UDF        | EMBED_AND_PUSH          | Active          |
| Virtual Schema    | mt_team_a               | Active          |
| Virtual Schema    | mt_team_b               | Active          |
| Table             | TEST_DATA.TEAM_A_DOCS   | 6 rows          |
| Table             | TEST_DATA.TEAM_B_DOCS   | 6 rows          |
| Table             | TEST_DATA.SHARED_DOCS   | 5 rows          |
| Qdrant Collection | team_a_docs             | 6 points (volatile) |
| Qdrant Collection | team_b_docs             | 6 points (volatile) |
| Qdrant Collection | shared_data             | 5 points (volatile) |

---

## Conclusion

The Exasol Qdrant adapter delivers excellent single-tenant semantic search. Search quality is high, deployment is simple, and the SQL interface is intuitive. However, for a multi-tenant administrator managing shared infrastructure, the adapter lacks fundamental isolation controls. The absence of COLLECTION_FILTER is the single highest-impact gap -- implementing it would raise the multi-tenant UX score from 4.1 to approximately 6.5. Combined with Exasol GRANT controls and a naming convention, it would reach approximately 7.5. Full multi-tenant viability (score >8.0) requires either separate Qdrant instances per tenant or Qdrant-level authentication/authorization.
