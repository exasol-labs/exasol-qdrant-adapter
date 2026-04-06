# Test Description: Topic 1 - Virtual Schema Ghost State

## What Changed
- Replaced `DROP VIRTUAL SCHEMA IF EXISTS vector_schema CASCADE` with `DROP FORCE VIRTUAL SCHEMA IF EXISTS vector_schema` in `scripts/install_all.sql`
- Removed the redundant `ALTER VIRTUAL SCHEMA vector_schema REFRESH` after CREATE (CREATE already does an implicit refresh; the explicit one can trigger ghost state on re-runs)
- Added detailed comments in install_all.sql explaining the ghost state bug and workaround
- Added a Troubleshooting section to README.md documenting the ghost state issue, the DROP FORCE fix, session reconnect workaround, and a warning about CASCADE

## What to Test
1. **Deployment works:** After a from-scratch deploy using install_all.sql, the virtual schema VS should exist and the ADAPTER schema scripts should be intact
2. **Source code correctness:** Verify that install_all.sql no longer contains CASCADE on any DROP VIRTUAL SCHEMA line, uses DROP FORCE instead, and has the REFRESH commented out
3. **Documentation:** Verify README.md has a Troubleshooting section mentioning ghost state and DROP FORCE
4. **Negative test:** Verify that DROP FORCE with IF EXISTS on a nonexistent schema does not throw an error

## How to Know It Works
- The virtual schema VS is queryable after deployment
- The ADAPTER schema still has all its scripts (not destroyed by CASCADE)
- The install_all.sql file uses `DROP FORCE VIRTUAL SCHEMA IF EXISTS` (not CASCADE)
- The README has a clear troubleshooting section for the ghost state issue

## Common Failure Modes
- If Exasol nano does not support `DROP FORCE` syntax, the deployment will fail at that step
- If the virtual schema name in install_all.sql was changed but the test still looks for 'VS', the test will incorrectly fail
- If the deploy-wrapper does not re-read the updated install_all.sql, old code (with CASCADE) may still be deployed
