# Iteration 03: Security-Focused UX Assessment

**Date:** 2026-04-05
**Persona:** Security-Conscious DBA
**Focus:** Credential exposure, audit log hygiene, privilege escalation surface, network exposure
**Stack:** Exasol 7.x (Docker) + Qdrant 1.9 + Ollama (nomic-embed-text) + MCP Server

---

## Overall UX Score: 6.2 / 10

Weighted toward security (60% security, 20% usability, 20% operational safety).

---

## Scoring Table

| Dimension                          | Weight | Raw Score | Weighted |
|------------------------------------|--------|-----------|----------|
| Credential handling (audit logs)   | 20%    | 3/10      | 0.60     |
| Credential handling (connections)  | 15%    | 8/10      | 1.20     |
| Network exposure surface           | 10%    | 4/10      | 0.40     |
| RBAC / privilege model             | 15%    | 5/10      | 0.75     |
| PREFLIGHT_CHECK UDF                | 5%     | 8/10      | 0.40     |
| EMBED_AND_PUSH_V2 (conn-based)    | 10%    | 8/10      | 0.80     |
| Graceful error handling            | 5%     | 7/10      | 0.35     |
| Deployment idempotency             | 5%     | 6/10      | 0.30     |
| install_all.sql usability          | 10%    | 7/10      | 0.70     |
| Documentation of security posture  | 5%     | 4/10      | 0.20     |
| **Total**                          | 100%   |           | **6.20** |

---

## Test Methodology

1. Deployed full stack from `scripts/install_all.sql` via Exasol MCP server
2. Created both old (9-param EMBED_AND_PUSH) and new (V2 connection-based) UDFs
3. Created PREFLIGHT_CHECK UDF for pre-deployment validation
4. Ingested identical data through both approaches with a simulated API key
5. Queried `"$EXA_AUDIT_SQL"` to compare what each approach exposes
6. Checked `SYS.EXA_ALL_CONNECTIONS` for credential leakage
7. Tested empty-query graceful handling
8. Tested semantic search end-to-end

---

## Security Finding S1: API Keys Appear in Plain Text in Audit Logs (CRITICAL)

**Severity:** CRITICAL
**Component:** EMBED_AND_PUSH (original 9-parameter version)
**Evidence:**

When using the original EMBED_AND_PUSH with inline parameters, the full SQL text -- including API keys -- is logged verbatim in `"$EXA_AUDIT_SQL"`:

```sql
-- This appears VERBATIM in the audit log:
SELECT ADAPTER.EMBED_AND_PUSH(
    id, text_col,
    '172.17.0.1', 6333, 'sk-FAKE-SECRET-API-KEY-12345',  -- <-- EXPOSED
    'security_test_v1',
    'ollama',
    'http://172.17.0.4:11434',                            -- <-- internal IP exposed
    'nomic-embed-text'
)
FROM SECURITY_TEST.SEED_DATA
GROUP BY IPROC()
```

Anyone with SELECT on `"$EXA_AUDIT_SQL"` can harvest:
- Qdrant API keys (param 5: `qdrant_api_key`)
- OpenAI API keys (param 8: `embedding_key` when provider='openai')
- Internal Docker container IPs and ports
- Collection names (information leakage)

**Risk:** In a production Exasol deployment where multiple teams share the cluster, DBAs and auditors routinely query `"$EXA_AUDIT_SQL"` for compliance. Every EMBED_AND_PUSH invocation becomes a credential exposure event.

---

## Security Finding S2: CONNECTION Objects Properly Redact Secrets (POSITIVE)

**Severity:** Informational (positive finding)
**Component:** Exasol CONNECTION objects + EMBED_AND_PUSH_V2

Exasol's audit log properly redacts connection passwords:

```sql
-- Audit log shows:
CREATE OR REPLACE CONNECTION ollama_conn
    TO 'http://172.17.0.4:11434'
    USER 'ollama'
    IDENTIFIED BY '<SECRET>'    -- <-- REDACTED by Exasol
```

The V2 UDF call in the audit log shows only connection names:

```sql
-- Audit log shows:
SELECT ADAPTER.EMBED_AND_PUSH_V2(
    id, text_col,
    'security_test_v2',
    'QDRANT_CONN',     -- <-- just a name, no URL
    'OLLAMA_CONN',     -- <-- just a name, no secret
    'nomic-embed-text'
)
FROM SECURITY_TEST.SEED_DATA
GROUP BY IPROC()
```

`SYS.EXA_ALL_CONNECTIONS` exposes only `CONNECTION_NAME` and `CREATED` -- no address, user, or password columns.

---

## Security Finding S3: Virtual Schema Properties Expose Service URLs (MEDIUM)

**Severity:** MEDIUM
**Component:** Virtual schema CREATE/ALTER statements

```sql
-- Audit log shows:
CREATE VIRTUAL SCHEMA VECTOR_SCHEMA
    USING ADAPTER.VECTOR_SCHEMA_ADAPTER
    WITH CONNECTION_NAME = 'qdrant_conn'
         QDRANT_MODEL    = 'nomic-embed-text'
         OLLAMA_URL      = 'http://172.17.0.1:11434'  -- <-- internal URL exposed
```

The Ollama URL (an internal Docker bridge IP) is stored as a virtual schema property, visible in:
- `"$EXA_AUDIT_SQL"` (full SQL text)
- Virtual schema properties (queryable by adapter scripts)

**Mitigation:** Move OLLAMA_URL into the CONNECTION object's address field. The Lua adapter already reads `conn.address` for Qdrant via `exa.get_connection()` -- the same pattern should be applied to Ollama.

---

## Security Finding S4: No Authentication on Qdrant or Ollama (HIGH)

**Severity:** HIGH
**Component:** Infrastructure configuration

Both Qdrant and Ollama are running without authentication:
- Qdrant: `IDENTIFIED BY ''` (empty password on qdrant_conn)
- Ollama: No auth at all (HTTP endpoint, no API key)

Any process on the Docker bridge network can:
- Read all Qdrant collections and vector data
- Write/delete Qdrant collections
- Use Ollama for arbitrary embedding/inference requests

**Mitigation:** Enable Qdrant API key authentication and restrict Ollama to localhost or use an API gateway.

---

## Security Finding S5: Docker Bridge IP as Attack Surface (MEDIUM)

**Severity:** MEDIUM
**Component:** Network architecture

The adapter requires `172.17.0.1` (Docker bridge gateway) for Exasol-to-host communication. This:
- Exposes all host-bound services to the Exasol UDF sandbox
- Means any Python UDF can reach any host port via `172.17.0.1`
- The Ollama container IP (`172.17.0.4`) is also reachable from UDFs

There is no network segmentation between the Exasol UDF sandbox and other Docker containers. A malicious or compromised UDF could scan the entire bridge network.

**Mitigation:** Use Docker network policies or a dedicated network for Exasol with restricted egress rules.

---

## Security Finding S6: CREATE_QDRANT_COLLECTION API Key in Plain Text (HIGH)

**Severity:** HIGH
**Component:** CREATE_QDRANT_COLLECTION UDF

```sql
-- This also logs the API key in plain text:
SELECT ADAPTER.CREATE_QDRANT_COLLECTION(
    '172.17.0.1', 6333, 'my-secret-qdrant-key',  -- <-- EXPOSED
    'my_collection', 768, 'Cosine', 'nomic-embed-text'
);
```

Same audit log exposure as EMBED_AND_PUSH. This UDF also needs a connection-based variant.

---

## Security Finding S7: Virtual Schema Ghost State (OPERATIONAL)

**Severity:** MEDIUM (operational, not directly security)
**Component:** Virtual schema lifecycle

Across MCP sessions, the virtual schema enters a "ghost state" where it exists in `EXA_ALL_SCHEMAS` but tables are not queryable. This was observed multiple times during this test:
- `CREATE VIRTUAL SCHEMA` succeeds
- `ALTER VIRTUAL SCHEMA ... REFRESH` succeeds
- `SELECT FROM virtual_schema.table` fails with "object not found"
- Requires DROP CASCADE + re-CREATE to recover

In a security context, this means the adapter's availability is fragile -- a failed deployment could leave the schema in an inconsistent state where it appears healthy but silently fails all queries.

---

## EMBED_AND_PUSH V1 vs V2 Comparison

| Aspect                        | V1 (9-param)                    | V2 (connection-based)         |
|-------------------------------|----------------------------------|-------------------------------|
| Parameters                    | 9 positional                    | 6 (2 data + 2 conn + 2 cfg)  |
| API key in SQL text           | YES (plain text)                | NO (in CONNECTION object)     |
| API key in audit log          | YES (plain text)                | NO (redacted as `<SECRET>`)   |
| Qdrant URL in SQL text        | YES                             | NO (in CONNECTION)            |
| Ollama URL in SQL text        | YES                             | NO (in CONNECTION)            |
| Internal IPs exposed          | YES (host + container IPs)      | NO                            |
| Ease of use                   | Error-prone (position matters)  | Clear (named connections)     |
| Functional equivalence        | Full Ollama + OpenAI support    | Full Ollama + OpenAI support  |
| Audit log safety              | FAIL                            | PASS                          |

**Verdict:** V2 is strictly superior for any environment where audit logs are reviewed by more than one person, or where compliance requirements exist.

---

## PREFLIGHT_CHECK Results

The PREFLIGHT_CHECK UDF was created and tested successfully:

```
=== PREFLIGHT CHECK ===

Qdrant /collections: PASS (HTTP 200)
Ollama /api/tags: PASS (HTTP 200)
Model 'nomic-embed-text': PASS (available)
Embedding round-trip: PASS (dim=768)

Result: 4/4 checks passed
Status: READY
```

**Security note:** PREFLIGHT_CHECK takes URLs as inline parameters, which means internal service URLs appear in the audit log. For production, this should also accept a CONNECTION name.

---

## Graceful Empty-Query Handling

Confirmed working. Querying without a WHERE clause returns a helpful message instead of crashing:

```sql
SELECT * FROM SEC_TEST.PRODUCT_CATALOG LIMIT 3;
-- Returns: ID='NO_QUERY', TEXT='Semantic search requires: WHERE "QUERY" = ...'
```

This is a significant improvement over the crash behavior reported in prior iterations.

---

## Recommendations (Priority Order)

### P0 - Must Fix Before Production

1. **Ship EMBED_AND_PUSH_V2 as the default.** Deprecate the 9-param version. API keys in audit logs is a compliance blocker.
2. **Create CREATE_QDRANT_COLLECTION_V2** with connection-based config (same pattern as EMBED_AND_PUSH_V2).
3. **Move OLLAMA_URL into a CONNECTION object** for the virtual schema adapter. The Lua adapter already uses `exa.get_connection()` for Qdrant -- extend this to Ollama.

### P1 - Should Fix

4. **Add PREFLIGHT_CHECK to install_all.sql** as a post-deployment validation step. Currently it must be deployed separately.
5. **Document the security model** -- which CONNECTION objects hold what, what appears in audit logs, and the principle of least privilege for granting CONNECTION access.
6. **Enable Qdrant API key auth** in default configuration and document it.

### P2 - Nice to Have

7. **Add a `--secure` flag** to install_all.sql that omits the old 9-param UDFs entirely.
8. **PREFLIGHT_CHECK should accept CONNECTION names** instead of raw URLs.
9. **Add network egress documentation** for production Docker deployments.

---

## Artifacts Created During This Iteration

| Artifact                          | Type             | Schema  |
|-----------------------------------|------------------|---------|
| VECTOR_SCHEMA_ADAPTER             | Lua ADAPTER      | ADAPTER |
| EMBED_AND_PUSH                    | Python3 SET UDF  | ADAPTER |
| EMBED_AND_PUSH_V2                 | Python3 SET UDF  | ADAPTER |
| CREATE_QDRANT_COLLECTION          | Python3 SCALAR   | ADAPTER |
| PREFLIGHT_CHECK                   | Python3 SCALAR   | ADAPTER |
| TEST_QDRANT                       | Lua SCALAR       | ADAPTER |
| qdrant_conn                       | CONNECTION        | --      |
| ollama_conn                       | CONNECTION        | --      |
| SEC_TEST                          | VIRTUAL SCHEMA   | --      |
| SECURITY_TEST.SEED_DATA           | TABLE            | SECURITY_TEST |
| security_test_v1                  | Qdrant collection | --     |
| security_test_v2                  | Qdrant collection | --     |

---

## Audit Log Evidence Summary

| SQL Pattern                           | Secrets Visible? | Internal IPs? |
|---------------------------------------|------------------|---------------|
| EMBED_AND_PUSH (old, 9-param)        | YES              | YES           |
| EMBED_AND_PUSH_V2 (conn-based)       | NO               | NO            |
| CREATE_QDRANT_COLLECTION             | YES              | YES           |
| CREATE CONNECTION ... IDENTIFIED BY  | NO (`<SECRET>`)  | YES (address) |
| CREATE VIRTUAL SCHEMA ... WITH       | NO (uses conn)   | YES (OLLAMA_URL) |
| PREFLIGHT_CHECK(url, url, model)     | NO (no secrets)  | YES (URLs)    |

---

## Conclusion

The Exasol Qdrant adapter has a **solid architectural security foundation** -- Exasol's CONNECTION objects provide proper secret redaction in audit logs, and the Lua adapter already uses `exa.get_connection()` for Qdrant credentials. The fundamental flaw is that the **Python UDFs bypass this mechanism** by accepting credentials as inline SQL parameters.

The newly created EMBED_AND_PUSH_V2 demonstrates that the fix is straightforward: read credentials from CONNECTION objects inside the UDF via `exa.get_connection()`. This eliminates all audit log exposure with no loss of functionality.

**Bottom line:** The adapter is 80% of the way to being production-secure. The remaining 20% is shipping V2 as the default, extending the CONNECTION pattern to all UDFs (including CREATE_QDRANT_COLLECTION), and moving OLLAMA_URL out of virtual schema properties into a CONNECTION.

**Score: 6.2/10** -- Solid infrastructure, but the credential-in-audit-log issue is a hard blocker for regulated environments.
