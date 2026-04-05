# UX Fix Phases

Identified from a 10-agent UX testing study (2026-04-04). Average UX score before fixes: **5.6/10**.

---

## Phase 1 — Unblock Core Workflows (Critical + H1)

Fixes that prevent the installer and adapter from working at all.

| ID | Fix | File(s) | Details |
|----|-----|---------|---------|
| C1 | Fix ADAPTER_ERROR to return 4 columns | `scripts/install_all.sql`, `scripts/install_adapter.sql` | Error handler returns `SELECT '...' AS ADAPTER_ERROR FROM DUAL` (1 col) but VS expects 4. Change to 4-column VALUES row so errors surface as readable result rows instead of crashing. |
| C2 | Replace `--` with `#` in Python code | `scripts/install_all.sql` | Line 351: `MAX_CHARS = 6000  -- ~1500 tokens...` — `--` is SQL comment, not Python. Causes silent UDF failure or runtime error. |
| C3 | Replace `CREATE VIRTUAL SCHEMA IF NOT EXISTS` with `DROP + CREATE` | `scripts/install_all.sql` | `IF NOT EXISTS` silently skips on re-run, leaving VS in ghost state. `DROP IF EXISTS CASCADE` + `CREATE` is safe (Qdrant data is external). |
| C4 | Add null guard for duplicate NULL IDs | `scripts/install_all.sql`, `exasol_udfs/embed_and_push.py`, `scripts/create_udfs_ollama.sql` | Multiple rows with NULL id hash to same UUID, causing silent data loss. Add warning or skip rows with NULL id. |
| H1 | Add `OPEN SCHEMA ADAPTER` after CREATE SCHEMA | `scripts/install_all.sql` | Python UDFs silently fail to create when ADAPTER isn't the current schema. |

**Expected UX lift:** 5.6 -> ~7.5

---

## Phase 2 — Improve Error Handling

Fixes that make errors understandable when things go wrong.

| ID | Fix | File(s) | Details |
|----|-----|---------|---------|
| H3 | Detect missing QUERY predicate | `scripts/install_all.sql`, `scripts/install_adapter.sql` | When no `WHERE "QUERY" = '...'` is present, return a helpful 4-column empty result with error message in TEXT column instead of crashing. |
| H4 | Fix VARCHAR(36) in empty-result fallback | `scripts/install_all.sql`, `scripts/install_adapter.sql` | Empty collection fallback uses `VARCHAR(36)` for ID but VS declares `VARCHAR(2000000)`. Change to match. |
| H5 | Fix test_connectivity.sql port | `scripts/test_connectivity.sql` | Uses Ollama port `11435` instead of `11434`. Also hardcodes collection name "modapte". |

**Expected UX lift:** ~7.5 -> ~8.0

---

## Phase 3 — Documentation and Polish

Fixes that improve docs consistency, remove stale content, and polish the experience.

| ID | Fix | File(s) | Details |
|----|-----|---------|---------|
| H2 | Standardize Ollama IP guidance | `scripts/install_all.sql`, `README.md` | install_all.sql usage examples use `172.17.0.1` for Ollama in UDF, but UDF docs say use container IP. Align with clear explanation. |
| H6 | Fix "only cosine" in limitations.md | `docs/limitations.md` | Code supports 4 distance metrics. Update limitations to reflect reality. |
| M1 | Fix Exasol readiness check | `docs/quickstart.md` | `grep "ready to accept connections"` doesn't match actual Exasol logs. |
| M2 | Soften expected scores in quickstart | `docs/quickstart.md` | Exact scores shown don't match real results. Add disclaimer about score variance. |
| M8 | Add scripts/ to README project structure | `README.md` | The primary deployment directory isn't listed. |
| M9 | Add install_all.sql note in README Loading Data | `README.md` | References create_udfs_ollama.sql without mentioning install_all.sql already deploys UDFs. |
| L2 | Clean up legacy scripts | `scripts/create_collection.sql`, `scripts/ingest_text.sql` | Legacy Lua EXECUTE SCRIPT files that don't match current architecture. Remove or mark deprecated. |

**Expected UX lift:** ~8.0 -> ~8.5+

---

## Final Validation

After all three phases: run 3 qdrant-semantic-search-setup agents to verify functionality and measure UX improvement.
