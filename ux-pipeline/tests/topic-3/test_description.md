# Test Description: Topic 3 - CASCADE Destroys ADAPTER Schema

## What Changed
Removed `CASCADE` from the `DROP VIRTUAL SCHEMA` statement in `docs/deployment.md` (the only remaining file with actionable CASCADE). Replaced with `DROP FORCE VIRTUAL SCHEMA IF EXISTS` and added a warning comment. The main `install_all.sql` and README were already fixed in Topic 1.

## What to Test
1. Verify no .sql script files contain `DROP VIRTUAL SCHEMA ... CASCADE` in executable SQL.
2. Verify `docs/deployment.md` uses `DROP FORCE` instead of `CASCADE`.
3. Verify the README contains a warning about why CASCADE should not be used.
4. Verify semantic search still works (no regression from any changes).

## How to Know It Works
- No actionable SQL in the project contains `DROP VIRTUAL SCHEMA ... CASCADE`.
- Documentation warns users about the CASCADE danger.
- The adapter continues to function normally.

## Common Failure Modes
- A file might still contain CASCADE in an executable SQL context (not just a comment/warning).
- The deployment.md edit might have broken the markdown formatting.
