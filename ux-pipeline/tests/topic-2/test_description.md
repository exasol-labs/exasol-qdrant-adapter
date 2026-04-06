# Test Description: Topic 2 - API Keys Exposed in Audit Logs

## What Changed
Added prominent security deprecation warnings to EMBED_AND_PUSH (V1) in install_all.sql, the README, and the Python source file. The warnings explain that V1 exposes API keys in Exasol audit logs (EXA_DBA_AUDIT_SQL) and that EMBED_AND_PUSH_V2 should be used instead. Updated usage examples in install_all.sql to promote V2 as the primary ingestion method.

## What to Test
1. Verify that the deployed EMBED_AND_PUSH_V2 script exists and uses CONNECTION-based config (exa.get_connection).
2. Verify that the embedding_conn CONNECTION exists for V2 usage.
3. Verify that semantic search still works end-to-end (no regression from the documentation/warning changes).
4. Verify that the install_all.sql file contains the security warning for V1.

## How to Know It Works
- EMBED_AND_PUSH_V2 script exists in ADAPTER schema and reads config from a CONNECTION object.
- The `embedding_conn` CONNECTION is deployed.
- Semantic search queries return results normally (no regression).
- The install_all.sql file contains clear security warnings about V1 audit log exposure.

## Common Failure Modes
- The install_all.sql was not redeployed after changes -- V2 or embedding_conn might not exist.
- The CONNECTION might have wrong config JSON -- V2 ingestion would fail.
- The security warning might break SQL syntax in install_all.sql if quotes are mismatched.
