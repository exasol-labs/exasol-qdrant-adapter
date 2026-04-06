# Iteration 09: Error Messages and Debuggability UX Study

**Date:** 2026-04-05
**Methodology:** Simulated troubleshooter inheriting a broken setup. Deliberately introduced misconfigurations (wrong IP, wrong port, wrong model name) across both the Lua adapter and Python UDFs. Evaluated error messages for clarity, actionability, and debuggability.

**Baseline:** Working deployment with Qdrant on 172.17.0.1:6333, Ollama on 172.17.0.1:11434, model nomic-embed-text, KNOWLEDGE_BASE collection with 20+ documents.

---

## UX Score: 7.2 / 10

### Score Breakdown

| Dimension                        | Weight | Score | Weighted |
|----------------------------------|--------|-------|----------|
| Lua adapter error clarity        | 25%    | 9.5   | 2.38     |
| Python UDF error clarity         | 20%    | 4.5   | 0.90     |
| Validation error quality         | 15%    | 9.0   | 1.35     |
| Error recoverability             | 15%    | 7.0   | 1.05     |
| Ghost schema handling            | 10%    | 2.0   | 0.20     |
| Graceful degradation             | 10%    | 9.0   | 0.90     |
| Error consistency across layers  | 5%     | 4.0   | 0.20     |
| **Total**                        |**100%**|       | **6.98** |

Rounded to **7.2** (with a +0.2 bonus for the NO_QUERY instructional pattern, which is genuinely best-in-class).

---

## Error Scenario Table

| # | Scenario | Component | Error Message (key part) | Helpful? | Score |
|---|----------|-----------|--------------------------|----------|-------|
| 1 | Wrong Qdrant port (6334) | Lua adapter (CREATE VIRTUAL SCHEMA) | `GET http://172.17.0.1:6334/collections => connection refused:` | **Yes** -- shows full URL with wrong port, HTTP method, and OS error | 9/10 |
| 1b | Wrong Qdrant port (6334) | Python UDF (CREATE_QDRANT_COLLECTION) | 30-line Python stack trace ending in `ConnectionRefusedError: [Errno 111] Connection refused` | **Partially** -- the root cause is there but buried; no URL shown | 4/10 |
| 2 | Wrong Ollama port (11435) | Lua adapter (pushdown query) | `ID=ERROR, TEXT="POST http://172.17.0.1:11435/api/embeddings => connection refused: "` | **Yes** -- returned as a result row (no crash), full URL visible | 10/10 |
| 3 | Wrong model name (TOTALLY_FAKE_MODEL) | Lua adapter (pushdown query) | `ID=ERROR, TEXT="POST http://...11434/api/embeddings => 404: {"error":"model \"TOTALLY_FAKE_MODEL_12345\" not found, try pulling it first"}"` | **Yes** -- shows model name, HTTP status, Ollama's own helpful message | 9/10 |
| 4 | Wrong Qdrant IP (172.17.0.99) | Lua adapter (CREATE VIRTUAL SCHEMA) | `GET http://172.17.0.99:6333/collections => No route to host:` | **Yes** -- full URL, clear OS error | 9/10 |
| 5 | Missing CONNECTION_NAME | Lua adapter (CREATE VIRTUAL SCHEMA) | `Missing CONNECTION_NAME` | **Yes** -- exact property name | 8/10 |
| 6 | Missing QDRANT_MODEL | Lua adapter (CREATE VIRTUAL SCHEMA) | `Missing QDRANT_MODEL` | **Yes** -- exact property name | 8/10 |
| 7 | Query without WHERE QUERY = | Lua adapter (pushdown query) | `ID=NO_QUERY, TEXT="Semantic search requires: WHERE "QUERY" = 'your search text'. Example: SELECT..."` | **Excellent** -- returns example SQL with actual collection name | 10/10 |
| 8 | Wrong Ollama URL | Python UDF (EMBED_AND_PUSH) | 30-line Python stack trace ending in `ConnectionRefusedError: [Errno 111] Connection refused` | **Partially** -- URL not shown in error, must cross-reference source | 3/10 |
| 9 | Wrong model name | Python UDF (EMBED_AND_PUSH) | 40-line Python stack trace ending in `RuntimeError: Ollama error 404: {"error":"model \"...\" not found, try pulling it first"}` | **Partially** -- useful info exists but at the very end of massive output | 5/10 |
| 10 | Ghost virtual schema | Exasol platform | `schema VECTOR_SCHEMA already exists` (but SYS.EXA_ALL_VIRTUAL_SCHEMAS shows nothing) | **No** -- contradictory information, only DROP FORCE resolves it | 2/10 |
| 11 | Invalid distance metric | Python UDF (CREATE_QDRANT_COLLECTION) | `Invalid distance 'InvalidDistance'. Valid: Cosine, Dot, Euclid, Manhattan` | **Yes** -- shows bad value AND all valid options | 10/10 |
| 12 | Unknown model + NULL vector_size | Python UDF (CREATE_QDRANT_COLLECTION) | `Unknown model 'unknown-model-xyz'. Provide explicit vector_size.` | **Yes** -- names bad model, suggests workaround | 9/10 |

---

## Detailed Analysis

### What works exceptionally well

**1. Lua adapter error-as-row pattern (Scenarios 2, 3, 7)**

The adapter's `pcall` wrapper around `rewrite()` catches errors and returns them as a result row with `ID=ERROR` and the error message in the `TEXT` column. This is a UX innovation:

- The query does not crash -- it returns a result set
- The error is visible in any SQL client (DBeaver, DbVisualizer, etc.)
- The full context (URL, port, HTTP status, response body) is in a single line
- A troubleshooter can compare the URL in the error to the expected URL immediately

The NO_QUERY pattern (Scenario 7) goes even further by returning a working example query with the actual collection name populated. This turns an error into a tutorial.

**2. Lua adapter HTTP error format**

The format `{METHOD} {URL} => {status/error}: {body}` used in `http_get_json` and `http_post_json` is consistently excellent:

```
GET http://172.17.0.1:6334/collections => connection refused:
POST http://172.17.0.1:11435/api/embeddings => connection refused:
POST http://172.17.0.1:11434/api/embeddings => 404: {"error":"model..."}
GET http://172.17.0.99:6333/collections => No route to host:
```

Every error includes the full URL (so wrong host/port is immediately visible), the HTTP method, and either the OS error or HTTP status + body. This is textbook error message design.

**3. Validation errors (Scenarios 5, 6, 11, 12)**

Property validation (`Missing CONNECTION_NAME`, `Missing QDRANT_MODEL`) and UDF input validation (`Invalid distance`, `Unknown model`) are concise and actionable. The distance metric error even lists all valid options.

### What needs improvement

**1. Python UDF error messages are terrible (Scenarios 1b, 8, 9)**

Python UDFs produce 30-40 line stack traces from `urllib.request` internals that are mostly noise. The useful information (the actual error) is at the very end. Critically, **connection errors do not show the URL that failed**. A troubleshooter seeing `ConnectionRefusedError: [Errno 111] Connection refused` has no idea which host/port was wrong without reading the UDF source code.

**Fix recommendation:** Wrap all `urllib` calls in try/except blocks that include the URL in the error message:
```python
except urllib.error.URLError as e:
    raise RuntimeError(f"Connection to {url} failed: {e}") from e
```

**2. Ghost virtual schema (Scenario 10)**

This is an Exasol platform issue, not an adapter issue, but it dramatically impacts the troubleshooting experience:

- `DROP VIRTUAL SCHEMA IF EXISTS` silently succeeds
- `CREATE VIRTUAL SCHEMA` fails with "already exists"
- Metadata queries show no such schema
- Only `DROP FORCE VIRTUAL SCHEMA` works

This was encountered 4 separate times during this testing session. The install_all.sql script partially mitigates this by using `DROP VIRTUAL SCHEMA IF EXISTS` before CREATE, but the ghost state can still appear if the adapter script fails during createVirtualSchema (e.g., wrong Qdrant port). Exasol creates the schema metadata before the adapter callback, and a callback failure leaves orphaned metadata.

**Workaround already exists:** The install_all.sql uses `DROP VIRTUAL SCHEMA IF EXISTS ... CASCADE` which handles most cases. But after a failed CREATE, the user must use `DROP FORCE VIRTUAL SCHEMA`.

**3. Error message inconsistency between Lua and Python layers**

The Lua adapter produces single-line, URL-rich error messages. The Python UDFs produce multi-page stack traces. A troubleshooter switching between querying (Lua) and ingesting (Python) faces two completely different error experiences. This cognitive switching cost adds friction.

**4. Ollama model name edge case**

During testing, the model name `nomic-embed-wrong` (a near-miss of the real model name `nomic-embed-text`) produced valid embeddings when called from inside Exasol's container, despite being rejected from localhost. This means a subtle model name typo might produce silently wrong results instead of an error. The adapter cannot detect this -- it depends on Ollama returning an error for unknown models.

---

## Comparison to Iteration 08

| Dimension | Iter 08 | Iter 09 | Change |
|-----------|---------|---------|--------|
| Overall UX Score | 8.5 | 7.2 | -1.3 (different focus) |
| Error clarity | Not tested | 7.2 | New dimension |

Note: Iteration 08 focused on general UX (installation, querying, docs). This iteration specifically stress-tested error paths, which reveals weaknesses that normal-path testing misses. The -1.3 difference is expected -- error paths are always rougher than happy paths.

---

## Recommendations (Priority Order)

### P0: Improve Python UDF error messages

Add URL context to all `urllib` exceptions in `embed_and_push.py` and `create_collection.py`. The Lua adapter already does this well -- apply the same pattern to Python.

Before:
```python
urllib.error.URLError: <urlopen error [Errno 111] Connection refused>
```

After:
```python
RuntimeError: Failed to connect to Ollama at http://172.17.0.4:11435/api/embed - Connection refused. Check that Ollama is running on this host and port.
```

### P1: Add PREFLIGHT_CHECK UDF

Create a diagnostic UDF that validates all infrastructure connections before the user tries to create a virtual schema:

```sql
SELECT ADAPTER.PREFLIGHT_CHECK(
    '172.17.0.1', 6333,    -- Qdrant host, port
    '172.17.0.1', 11434,   -- Ollama host, port
    'nomic-embed-text'      -- model name
);
```

Returns a table of check results:
```
| CHECK              | STATUS | DETAIL                           |
|--------------------|--------|----------------------------------|
| Qdrant connection  | OK     | 15 collections found             |
| Ollama connection  | OK     | nomic-embed-text available       |
| Model embedding    | OK     | 768 dimensions                   |
```

### P2: Document ghost virtual schema workaround

Add a "Troubleshooting" section to install_all.sql and README explaining:
- When ghost schemas happen (failed CREATE VIRTUAL SCHEMA)
- How to fix: `DROP FORCE VIRTUAL SCHEMA <name> CASCADE`
- Why: Exasol creates schema metadata before adapter callback

### P3: Add model validation at virtual schema creation time

Currently, a wrong model name is only detected at query time (pushdown). The adapter could validate the model during `createVirtualSchema` by making a test embedding call to Ollama.

---

## Raw Error Artifacts

All errors were captured live via the Exasol MCP server on 2026-04-05. The Exasol instance is Docker-based (exasoldb container), Qdrant and Ollama run in separate containers on the same Docker bridge network (172.17.0.0/16).

### Environment
- Exasol: Docker container `exasoldb`, port 9563 (mapped from 8563)
- Qdrant: Docker container `qdrant`, port 6333
- Ollama: Docker container `ollama`, port 11434, model nomic-embed-text
- Docker bridge gateway: 172.17.0.1
- Ollama container IP: 172.17.0.4
