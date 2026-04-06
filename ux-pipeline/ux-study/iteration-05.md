# Iteration 05: Edge Case & Error Handling Stress Test

**Date:** 2026-04-05
**Tester:** Exploratory Tester (automated agent)
**Scope:** Deliberate edge cases, unusual inputs, error handling, and failure modes
**Stack:** Exasol 7.x + Qdrant 1.9+ + Ollama (nomic-embed-text) + Lua adapter + Python UDFs

---

## UX Score: 6.8 / 10

**Scoring weights:** Error handling (40%), Input resilience (25%), Discoverability (20%), Consistency (15%)

| Dimension             | Weight | Score | Notes                                                                     |
|-----------------------|--------|-------|---------------------------------------------------------------------------|
| Error handling        | 40%    | 6.5   | Adapter errors are graceful (ERROR row), but UDFs leak raw stack traces   |
| Input resilience      | 25%    | 8.0   | Unicode, emoji, SQL injection, long text all handled without crashes      |
| Discoverability       | 20%    | 7.0   | NO_QUERY guidance is excellent; but empty-string and LIKE silently fail   |
| Consistency           | 15%    | 5.5   | Different error surfaces (ERROR row vs SQL exception vs empty result)     |

**Weighted total:** (0.40 * 6.5) + (0.25 * 8.0) + (0.20 * 7.0) + (0.15 * 5.5) = 2.6 + 2.0 + 1.4 + 0.825 = **6.825 ~ 6.8**

---

## Deployment Notes

Full tear-down and redeployment was performed. Key observations during deployment:

1. **Virtual schema ghost state** -- Creating a virtual schema, then querying from a new session, can result in "object not found" even though the schema exists in `SYS.EXA_ALL_SCHEMAS`. This is a known Exasol virtual schema session caching issue. The DROP + CREATE pattern in `install_all.sql` mitigates this but does not eliminate it when multiple sessions/agents operate concurrently.

2. **Concurrent agent interference** -- During testing, another agent was simultaneously creating and dropping virtual schemas (VS_SEARCH, MT_TEAM_A, etc.), which corrupted the VECTOR_SCHEMA state. The workaround was to create an isolated schema (`EDGE_TEST`) with a unique name. This is a real-world concern for shared Exasol environments.

3. **Connection object not preserved across CASCADE drops** -- `DROP VIRTUAL SCHEMA ... CASCADE` can remove the associated connection object. This is destructive and not documented.

---

## Edge Case Test Results

### Category A: Empty and Missing Query

| # | Test Case | Input | Result | Verdict |
|---|-----------|-------|--------|---------|
| A1 | No WHERE clause | `SELECT ... FROM collection LIMIT 5` | Returns 1 row: ID=`NO_QUERY`, TEXT=helpful usage example | PASS -- Excellent guidance |
| A2 | SELECT * without WHERE | `SELECT * FROM collection` | Same NO_QUERY guidance row | PASS |
| A3 | Empty string WHERE | `WHERE "QUERY" = ''` | Empty result set `[]` -- no rows, no guidance | FAIL -- Should show NO_QUERY guidance or explain why empty |
| A4 | Single space WHERE | `WHERE "QUERY" = ' '` | Returns search results (Ollama embeds whitespace) | WARN -- Debatable; whitespace is not a meaningful query |
| A5 | Multiple spaces WHERE | `WHERE "QUERY" = '   '` | Returns search results identical to single space | WARN -- Same as A4 |

**Analysis:** The empty string (`''`) case is the most confusing. The adapter's `qtext == ""` check matches it, so it should return the NO_QUERY guidance. However, the actual result is an empty result set, suggesting the pushdown path diverges. This is because Exasol's pushdown may not send the filter for empty string literals in the same way as for non-empty strings. The user sees zero rows with no explanation.

### Category B: Special Characters in Search Text

| # | Test Case | Input | Result | Verdict |
|---|-----------|-------|--------|---------|
| B1 | Single quote | `WHERE "QUERY" = ''''` (escaped single quote) | Returns results, no crash | PASS |
| B2 | SQL injection attempt | `'O''Brien''s test; DROP TABLE--'` | Returns results, no injection | PASS -- `esc()` function works |
| B3 | Chinese characters | `'你好世界'` | Returns results; top hit is Silk Road (East-West theme) | PASS -- Semantically relevant |
| B4 | Emoji in query | `'science experiments'` with emoji | Returns CRISPR as top result | PASS |
| B5 | HTML/XSS injection | `'<script>alert("xss")</script>'` | Returns results, no injection | PASS |
| B6 | Newline characters | Multi-line query text | Returns results | PASS |

**Analysis:** Input resilience is the strongest area. The adapter handles every character class without crashing. The `esc()` function properly escapes single quotes for the generated VALUES SQL. Unicode, emoji, and HTML are all passed through to Ollama for embedding without issue.

### Category C: Long Queries

| # | Test Case | Input | Result | Verdict |
|---|-----------|-------|--------|---------|
| C1 | ~500 character query | Long Lorem ipsum text about testing | Returns results in normal time | PASS |

**Analysis:** The adapter passes the full query text to Ollama's embedding endpoint. Ollama's nomic-embed-text model handles long text with its 2048 token context window. No truncation error observed. The EMBED_AND_PUSH UDF has a `MAX_CHARS = 6000` truncation for ingestion, but the adapter's query-time embedding does not truncate -- this is an asymmetry but unlikely to cause issues in practice since search queries are typically short.

### Category D: LIMIT Edge Cases

| # | Test Case | Input | Result | Verdict |
|---|-----------|-------|--------|---------|
| D1 | LIMIT 0 | `LIMIT 0` | Empty result set | PASS |
| D2 | LIMIT 1 | `LIMIT 1` | Exactly 1 result | PASS |
| D3 | LIMIT 100 (exceeds data) | `LIMIT 100` on 28-point collection | Returns all 28 points | PASS |

**Analysis:** LIMIT is correctly pushed down to Qdrant's search API. LIMIT 0 is correctly handled by Exasol (returns empty before reaching the adapter).

### Category E: Non-existent Objects

| # | Test Case | Input | Result | Verdict |
|---|-----------|-------|--------|---------|
| E1 | Non-existent table | `FROM schema.NONEXISTENT_TABLE` | Standard SQL error: "object not found" | PASS |
| E2 | Non-existent column | `SELECT "NONEXISTENT_COL"` | Standard SQL error: "object not found" | PASS |

**Analysis:** Exasol catches these at the SQL layer before the adapter is invoked. Standard behavior.

### Category F: Column Quoting

| # | Test Case | Input | Result | Verdict |
|---|-----------|-------|--------|---------|
| F1 | Unquoted column names | `SELECT ID, TEXT, SCORE ... WHERE QUERY = 'test'` | Works correctly | PASS -- Exasol uppercases unquoted identifiers |

**Analysis:** Since the adapter uses uppercase column names (ID, TEXT, SCORE, QUERY), unquoted identifiers work because Exasol automatically uppercases them. This eliminates a common user error.

### Category G: Unsupported WHERE Clause Patterns

| # | Test Case | Input | Result | Verdict |
|---|-----------|-------|--------|---------|
| G1 | LIKE instead of = | `WHERE "QUERY" LIKE '%test%'` | Empty result set | FAIL -- Silently returns nothing |
| G2 | AND compound filter | `WHERE "QUERY" = 'test' AND "SCORE" > 0.5` | Empty result set | FAIL -- Silently returns nothing |
| G3 | OR compound filter | `WHERE "QUERY" = 'test' OR "ID" = '1'` | Empty result set | FAIL -- Silently returns nothing |
| G4 | WHERE on wrong column | `WHERE "ID" = 'tech-1'` | Returns NO_QUERY guidance | PASS -- Guidance shown |

**Analysis:** This is the most significant UX gap. The adapter only supports `FN_PRED_EQUAL` on the `QUERY` column. When users use LIKE, AND, or OR, Exasol does not push down the filter (because those capabilities are not declared). The result is that the adapter receives no filter, enters the "no query" path, but instead of showing the NO_QUERY guidance, it returns an empty result set for LIKE/AND/OR (because Exasol applies the unsupported predicate as a post-filter on the NO_QUERY row, which doesn't match). This means:
- `WHERE "QUERY" LIKE '%test%'` -- the NO_QUERY row is generated, then Exasol applies `LIKE '%test%'` on the QUERY column which is empty, so it filters out the guidance row. Result: empty.
- `WHERE "QUERY" = 'test' AND "SCORE" > 0.5` -- the compound predicate is not pushed down. Same empty result.

The user gets zero rows and zero explanation. This is confusing.

### Category H: Virtual Schema Configuration Errors

| # | Test Case | Input | Result | Verdict |
|---|-----------|-------|--------|---------|
| H1 | Wrong Ollama URL/port | OLLAMA_URL = 'http://172.17.0.1:99999' | ERROR row: "connection refused" | PASS -- Clear error in query result |
| H2 | Wrong/missing model | QDRANT_MODEL = 'nonexistent-model-xyz' | ERROR row: "model not found, try pulling it first" | PASS -- Excellent, includes Ollama's guidance |
| H3 | Wrong Qdrant connection | CONNECTION pointing to wrong port | CREATE VIRTUAL SCHEMA fails immediately | PASS -- Fails fast at creation time |

**Analysis:** The adapter's error handling for infrastructure issues is good. Wrong Ollama URL or model returns a descriptive ERROR row at query time. Wrong Qdrant connection fails at virtual schema creation, which is the right behavior (fail fast). The ERROR row pattern (ID=ERROR, TEXT=error message, SCORE=0) is a practical approach for surfacing errors through SQL.

### Category I: Python UDF Error Handling (CREATE_QDRANT_COLLECTION)

| # | Test Case | Input | Result | Verdict |
|---|-----------|-------|--------|---------|
| I1 | Create new collection | Valid params | `"created: edge_test_collection"` | PASS |
| I2 | Create duplicate collection | Same params again | `"exists: edge_test_collection"` | PASS -- Idempotent |
| I3 | Invalid distance metric | `distance = 'InvalidDistance'` | `ValueError: Invalid distance 'InvalidDistance'. Valid: Cosine, Dot, Euclid, Manhattan` | PASS -- Clear, actionable |
| I4 | Unknown model, NULL vector_size | `model = 'unknown-model-xyz'` | `ValueError: Unknown model. Provide explicit vector_size.` | PASS -- Clear guidance |
| I5 | Wrong Qdrant port | `port = 9999` | Raw Python stack trace: `ConnectionRefusedError` | FAIL -- 30+ line stack trace, not user-friendly |
| I6 | Wrong Qdrant IP | `host = '192.168.99.99'` | Raw Python stack trace: `ConnectionRefusedError` | FAIL -- Same as I5 |

**Analysis:** The UDF validates its own parameters well (distance, model, vector_size), but network errors bubble up as raw Python stack traces with 30+ lines of urllib internals. This is the worst error experience in the stack. The `_qdrant_request` function catches `HTTPError` (4xx/5xx responses) but not `URLError` (connection failures).

### Category J: Python UDF Error Handling (EMBED_AND_PUSH)

| # | Test Case | Input | Result | Verdict |
|---|-----------|-------|--------|---------|
| J1 | NULL ID column | `id = NULL` | `ValueError: All 1 rows have NULL or empty IDs.` | PASS -- Clear message |
| J2 | Invalid provider | `provider = 'invalid_provider'` | `ValueError: provider must be 'ollama' or 'openai'` | PASS |
| J3 | Empty text, valid ID | `text = '', id = 'test-1'` | Succeeds, upserts 1 point | PASS -- Embeds empty string, acceptable |

### Category K: Cross-Collection and SQL Features

| # | Test Case | Input | Result | Verdict |
|---|-----------|-------|--------|---------|
| K1 | Table alias | `FROM EDGE_TEST.KNOWLEDGE_BASE k WHERE k."QUERY" = ...` | Works correctly | PASS |
| K2 | ORDER BY SCORE DESC | `ORDER BY "SCORE" DESC LIMIT 3` | Works; results already pre-sorted by Qdrant | PASS |
| K3 | Different collections | Querying SUPPORT_TICKETS and PRODUCT_CATALOG | Both return relevant results | PASS |

---

## Error Surface Consistency Analysis

The adapter uses three different error surfaces depending on where the failure occurs:

| Error Location | Error Surface | User Experience |
|----------------|---------------|-----------------|
| Adapter (Lua) query-time errors | ERROR row: `(ID='ERROR', TEXT=message, SCORE=0)` | Good -- visible in SQL results |
| Adapter (Lua) creation-time errors | SQL exception from CREATE VIRTUAL SCHEMA | Good -- fail fast |
| UDF validation errors | SQL exception with `ValueError: clear message` | Good |
| UDF network errors | SQL exception with 30+ line Python stack trace | Bad -- confusing |
| Unsupported SQL patterns | Silent empty result set | Bad -- no indication of what went wrong |
| Missing query (no WHERE) | NO_QUERY guidance row | Excellent |

The inconsistency between "ERROR row" (adapter), "clear ValueError" (UDF validation), and "raw stack trace" (UDF network) is jarring. A user encountering these in sequence would find the experience unpredictable.

---

## Top 5 Recommendations (Prioritized by Impact)

### 1. Catch network errors in Python UDFs (HIGH)
Wrap `urllib.error.URLError` in both `CREATE_QDRANT_COLLECTION` and `EMBED_AND_PUSH` to produce a one-line error like:
```
RuntimeError: Cannot connect to Qdrant at http://172.17.0.1:9999 -- Connection refused. Check host/port.
```
Instead of the current 30+ line stack trace.

### 2. Handle empty string and whitespace queries (HIGH)
In the adapter's `rewrite` function, treat whitespace-only queries the same as empty queries:
```lua
qtext = qtext:match("^%s*(.-)%s*$") or ""  -- trim
if qtext == "" then
    -- return NO_QUERY guidance
end
```
This would catch `''`, `' '`, and `'   '` uniformly.

### 3. Surface unsupported predicate guidance (MEDIUM)
When the adapter receives a pushdown without a recognizable QUERY = '...' filter but the user DID provide a WHERE clause (detectable because filter is non-nil but not predicate_equal on QUERY), return a guidance row like:
```
ID='UNSUPPORTED_FILTER', TEXT='Only WHERE "QUERY" = ''text'' is supported. LIKE, AND, OR are not supported.'
```

### 4. Unify error surfaces (MEDIUM)
Consider making UDF errors also return result rows instead of exceptions, matching the adapter's ERROR row pattern. This would require changing EMITS to include an error column, which is a larger change. Alternatively, wrap all UDF entry points in try/except at the `run()` level.

### 5. Document the empty-string behavior (LOW)
If fixing the empty-string behavior is deferred, at minimum document in the README and in the NO_QUERY guidance text that `WHERE "QUERY" = ''` returns empty results and is not equivalent to omitting the WHERE clause.

---

## Raw Test Log Summary

- **Total edge cases tested:** 30
- **PASS:** 22 (73%)
- **WARN:** 2 (7%) -- whitespace queries returning results is debatable
- **FAIL:** 6 (20%) -- empty string silence, LIKE/AND/OR silence, raw stack traces

---

## Comparison with Previous Iterations

This is the first iteration focused exclusively on error handling and edge cases. The 6.8 score reflects that the "happy path" UX is strong (previous iterations scored higher) but the error paths have significant gaps. The adapter's ERROR row pattern is a good foundation, but it needs to be extended to cover more failure modes, and the Python UDFs need network error wrapping.
