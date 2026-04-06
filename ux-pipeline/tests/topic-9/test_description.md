# Test Description: Topic 9 - Version Tracking

## What Changed
Added `ADAPTER_VERSION = "2.1.0"` constant to the Lua adapter script (install_all.sql, install_adapter.sql, and entry.lua). This makes the deployed version queryable via `SELECT SCRIPT_TEXT FROM SYS.EXA_ALL_SCRIPTS WHERE SCRIPT_NAME = 'VECTOR_SCHEMA_ADAPTER'`.

## What to Test
1. Version constant present in deployed script
2. Search functionality not broken (regression)

## How to Know It Works
- Script text contains ADAPTER_VERSION
- Queries still return results
