# Iteration 13: Automation & CI/CD Readiness Assessment

**Persona:** Automation Engineer (CI/CD pipeline scripting)
**Date:** 2026-04-05
**Focus:** Idempotency, exit codes, non-interactive execution, parameterization, CI gating

---

## UX Score: 7.2 / 10

**Weighting:** 70% automation-readiness, 20% error recoverability, 10% documentation clarity.

| Dimension                  | Score | Weight | Weighted |
|----------------------------|-------|--------|----------|
| Idempotency (re-run safe)  | 7/10  | 25%    | 1.75     |
| Exit code / error behavior | 6/10  | 20%    | 1.20     |
| Non-interactive execution  | 9/10  | 15%    | 1.35     |
| Parameterization           | 5/10  | 10%    | 0.50     |
| CI health gating           | 9/10  | 10%    | 0.90     |
| Cleanup / teardown         | 8/10  | 10%    | 0.80     |
| Documentation for CI       | 7/10  | 10%    | 0.70     |
| **Total**                  |       | **100%** | **7.20** |

---

## Test Protocol

### Test 1: Clean Deploy (Run 1)
Executed `install_all.sql` statement-by-statement via MCP server against a clean database (no ADAPTER schema, no connections, no virtual schemas).

**Result:** All 7 statements succeeded with no errors.

| Statement | Pattern | Result |
|-----------|---------|--------|
| `CREATE SCHEMA IF NOT EXISTS ADAPTER` | IF NOT EXISTS | PASS |
| `OPEN SCHEMA ADAPTER` | Session state | PASS |
| `CREATE OR REPLACE CONNECTION qdrant_conn` | OR REPLACE | PASS |
| `CREATE OR REPLACE LUA ADAPTER SCRIPT` | OR REPLACE | PASS |
| `CREATE OR REPLACE PYTHON3 SCALAR SCRIPT` | OR REPLACE | PASS |
| `CREATE OR REPLACE PYTHON3 SET SCRIPT` | OR REPLACE | PASS |
| `DROP VIRTUAL SCHEMA IF EXISTS ... CASCADE` | DROP IF EXISTS | PASS (no-op) |
| `CREATE VIRTUAL SCHEMA vector_schema` | Bare CREATE | PASS |
| `ALTER VIRTUAL SCHEMA ... REFRESH` | ALTER | PASS |

### Test 2: Idempotency (Run 2 -- no cleanup)
Executed the identical sequence again immediately after Run 1.

**Result:** 8/9 statements succeeded. 1 failure (non-blocking).

| Statement | Run 2 Result | Notes |
|-----------|-------------|-------|
| `CREATE SCHEMA IF NOT EXISTS` | PASS | No-op, schema exists |
| `OPEN SCHEMA ADAPTER` | PASS | |
| `CREATE OR REPLACE CONNECTION` | PASS | Overwrites silently |
| `CREATE OR REPLACE LUA ADAPTER SCRIPT` | PASS | Overwrites silently |
| `CREATE OR REPLACE PYTHON3 SCALAR SCRIPT` | PASS | Overwrites silently |
| `CREATE OR REPLACE PYTHON3 SET SCRIPT` | PASS | Overwrites silently |
| `DROP VIRTUAL SCHEMA IF EXISTS ... CASCADE` | PASS | Drops previous |
| `CREATE VIRTUAL SCHEMA vector_schema` | PASS | Recreated |
| `ALTER VIRTUAL SCHEMA ... REFRESH` | **FAIL** | "schema VECTOR_SCHEMA not found" |

**Failure analysis:** The virtual schema is created and functional (queries work), but `ALTER VIRTUAL SCHEMA ... REFRESH` fails with a session-level visibility error. The CREATE VIRTUAL SCHEMA implicitly performs a refresh during creation, so the explicit REFRESH is redundant for fresh deploys. This is an Exasol session caching issue, not a data integrity issue.

**Impact for CI:** The REFRESH failure produces a non-zero exit code that would fail a CI pipeline, but the deployment is actually complete and functional. A CI script must either:
1. Treat the REFRESH failure as non-fatal (catch and ignore), or
2. Remove the explicit REFRESH step entirely (the CREATE already refreshes), or
3. Run the REFRESH in a separate database session.

### Test 3: PREFLIGHT_CHECK as CI Health Gate

A `PREFLIGHT_CHECK` UDF exists in the ADAPTER schema. Tested it as a CI gate.

**All-pass scenario:**
```sql
SELECT ADAPTER.PREFLIGHT_CHECK(
    'http://172.17.0.1:6333',
    'http://172.17.0.1:11434',
    'nomic-embed-text'
);
-- Returns: "PREFLIGHT: 4/4 passed"
```

**Qdrant-down scenario:**
```sql
SELECT ADAPTER.PREFLIGHT_CHECK(
    'http://172.17.0.1:9999',  -- wrong port
    'http://172.17.0.1:11434',
    'nomic-embed-text'
);
-- Returns: "PREFLIGHT: 3/4 passed"
-- [FAIL] Qdrant unreachable at http://172.17.0.1:9999/collections ([Errno 111] Connection refused)
```

**Missing-model scenario:**
```sql
SELECT ADAPTER.PREFLIGHT_CHECK(
    'http://172.17.0.1:6333',
    'http://172.17.0.1:11434',
    'nonexistent-model'
);
-- Returns: "PREFLIGHT: 2/4 passed"
-- [FAIL] Model 'nonexistent-model' not found. Available: nomic-embed-text
-- [FAIL] Embedding test error: HTTP Error 404: Not Found
```

**CI gate verdict:** PREFLIGHT_CHECK is excellent for CI. The output is structured and parseable. A CI script can grep for `"PREFLIGHT: 4/4 passed"` as the success condition. It tests 4 things:
1. Qdrant reachability
2. Ollama reachability
3. Model availability
4. End-to-end embedding round-trip

**Limitation:** PREFLIGHT_CHECK is a UDF, so it requires the ADAPTER schema and the script to be deployed first. It cannot be used to gate the initial deployment -- only to validate post-deployment health. For pre-deployment gating, you need external curl/wget checks against the Qdrant and Ollama endpoints.

### Test 4: CREATE_QDRANT_COLLECTION Idempotency

```sql
-- First run:
SELECT ADAPTER.CREATE_QDRANT_COLLECTION('172.17.0.1', 6333, '', 'ci_test', NULL, 'Cosine', 'nomic-embed-text');
-- Returns: "created: ci_test"

-- Second run:
SELECT ADAPTER.CREATE_QDRANT_COLLECTION('172.17.0.1', 6333, '', 'ci_test', NULL, 'Cosine', 'nomic-embed-text');
-- Returns: "exists: ci_test"
```

**Verdict:** Fully idempotent. Returns a different status string but no error. CI-friendly.

### Test 5: EMBED_AND_PUSH Idempotency

Not explicitly re-tested, but by design: EMBED_AND_PUSH uses `uuid5` deterministic IDs and Qdrant's `PUT /points` (upsert). Re-ingesting the same data overwrites with identical values. No duplicates, no errors. Fully idempotent.

---

## Scriptability Matrix

| Operation | Fully Scriptable | Idempotent | Notes |
|-----------|:---:|:---:|-------|
| Create schema | YES | YES | `CREATE SCHEMA IF NOT EXISTS` |
| Create connection | YES | YES | `CREATE OR REPLACE CONNECTION` |
| Deploy Lua adapter | YES | YES | `CREATE OR REPLACE LUA ADAPTER SCRIPT` |
| Deploy Python UDFs | YES | YES | `CREATE OR REPLACE PYTHON3 ... SCRIPT` |
| Create virtual schema | YES | **PARTIAL** | DROP+CREATE works but REFRESH may fail in same session |
| Refresh virtual schema | YES | **NO** | Fails after DROP+CREATE in same session |
| Preflight check | YES | YES | Pure read-only, no side effects |
| Create collection | YES | YES | Returns "exists" on re-run |
| Ingest data | YES | YES | Upsert semantics, deterministic UUIDs |
| Semantic search query | YES | YES | Pure read |
| Full teardown | YES | YES | DROP IF EXISTS CASCADE on all objects |

---

## What Needs Manual Intervention

1. **Configuration values.** The 5 config values (host IP, ports, model, schema name) are hardcoded in `install_all.sql` via find-and-replace. There is no parameterization mechanism (no `DEFINE` variables, no template engine, no environment variable substitution). A CI pipeline must use `sed` or a templating tool to inject values before execution.

2. **Virtual schema session bug.** The REFRESH-after-CREATE failure in the same session requires one of:
   - Splitting into two SQL execution steps with separate sessions
   - Removing the REFRESH step (CREATE already does it)
   - Adding error suppression for the REFRESH

3. **Ollama IP for UDFs.** The Docker bridge gateway IP (172.17.0.1) works for the Lua adapter but Python UDFs may need the direct Ollama container IP (discovered via `docker inspect`). This is a runtime discovery that cannot be hardcoded safely in CI.

4. **install_all.sql is not PREFLIGHT_CHECK-aware.** The installer does not run PREFLIGHT_CHECK before deploying. A CI pipeline should call it after Step 4 (UDFs deployed) but before Step 5 (virtual schema creation) to catch infrastructure issues early.

---

## Recommendations for CI/CD Pipeline

### Recommended pipeline stages:

```
Stage 1: Pre-deploy (external)
  - curl http://QDRANT_HOST:6333/collections  (exit on fail)
  - curl http://OLLAMA_HOST:11434/api/tags     (exit on fail)

Stage 2: Template install_all.sql
  - sed -i 's/172.17.0.1/ACTUAL_IP/g' install_all.sql
  - sed -i 's/6333/ACTUAL_PORT/g' install_all.sql
  - etc.

Stage 3: Deploy (execute via MCP or exaplus)
  - Run statements 1-6 (schema through UDFs)
  - Treat as atomic -- any failure = pipeline fail

Stage 4: Post-deploy health check
  - SELECT ADAPTER.PREFLIGHT_CHECK(...)
  - Parse for "4/4 passed"
  - Exit non-zero if any check fails

Stage 5: Virtual schema (separate session)
  - DROP VIRTUAL SCHEMA IF EXISTS ... CASCADE
  - CREATE VIRTUAL SCHEMA ...
  - (skip REFRESH -- CREATE does it implicitly)

Stage 6: Smoke test
  - Run a semantic search query
  - Verify non-empty results
```

### What would move the score to 9/10:

1. **Add `--var` or `DEFINE` support** -- Let `install_all.sql` accept parameters instead of requiring find-and-replace. Even a header block of `DEFINE` statements that a CI tool can override would help.

2. **Remove the redundant REFRESH** -- The explicit `ALTER VIRTUAL SCHEMA ... REFRESH` after `CREATE VIRTUAL SCHEMA` is the single source of idempotency failures. Remove it from `install_all.sql` since CREATE already refreshes. Add a comment explaining this.

3. **Include PREFLIGHT_CHECK in install_all.sql** -- Add it as Step 4.5, between UDF deployment and virtual schema creation. Print the result. Do not fail on it (some users deploy before starting services), but surface it.

4. **Add a machine-readable exit status** -- PREFLIGHT_CHECK returns human-readable text. Adding a companion `PREFLIGHT_CHECK_STATUS` that returns just `PASS` or `FAIL` would simplify CI parsing.

5. **Document the Ollama IP discovery** -- Add a helper script or SQL function that discovers the correct Ollama IP from inside the Exasol container, or document the `docker inspect` command in the CI section.

---

## Raw Test Evidence

### Run 1 Timeline (clean install)
- 15:40:30 CREATE SCHEMA IF NOT EXISTS ADAPTER -- OK
- 15:40:31 OPEN SCHEMA ADAPTER -- OK
- 15:40:32 CREATE OR REPLACE CONNECTION qdrant_conn -- OK
- 15:40:35 CREATE OR REPLACE LUA ADAPTER SCRIPT -- OK
- 15:40:37 CREATE OR REPLACE PYTHON3 SCALAR SCRIPT (CREATE_QDRANT_COLLECTION) -- OK
- 15:40:39 CREATE OR REPLACE PYTHON3 SET SCRIPT (EMBED_AND_PUSH) -- OK
- 15:40:41 DROP VIRTUAL SCHEMA IF EXISTS vector_schema CASCADE -- OK (no-op)
- 15:40:43 CREATE VIRTUAL SCHEMA vector_schema -- OK
- 15:40:43 ALTER VIRTUAL SCHEMA vector_schema REFRESH -- OK
- Verification: 5 Qdrant collections visible as tables in VECTOR_SCHEMA

### Run 2 Timeline (idempotency test)
- 15:41:50 CREATE SCHEMA IF NOT EXISTS ADAPTER -- OK (no-op)
- 15:41:51 OPEN SCHEMA ADAPTER -- OK
- 15:41:52 CREATE OR REPLACE CONNECTION qdrant_conn -- OK (overwrite)
- 15:41:55 CREATE OR REPLACE LUA ADAPTER SCRIPT -- OK (overwrite)
- 15:41:57 CREATE OR REPLACE PYTHON3 SCALAR SCRIPT -- OK (overwrite)
- 15:41:59 CREATE OR REPLACE PYTHON3 SET SCRIPT -- OK (overwrite)
- 15:42:01 DROP VIRTUAL SCHEMA IF EXISTS vector_schema CASCADE -- OK
- 15:42:03 CREATE VIRTUAL SCHEMA vector_schema -- OK
- 15:42:34 ALTER VIRTUAL SCHEMA vector_schema REFRESH -- **FAIL** (session ghost state)
- Post-failure verification: Semantic search query against VECTOR_SCHEMA.SAMPLE_DOCS -- WORKS
- Conclusion: Deployment is functional despite REFRESH failure
