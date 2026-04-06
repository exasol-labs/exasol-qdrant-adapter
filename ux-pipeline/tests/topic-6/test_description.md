# Test Description: Topic 6 - OLLAMA_URL Default Misleading

## What Changed
Removed the misleading `http://localhost:11434` default for `OLLAMA_URL`. The property is now required in the Lua adapter (both source and install_all.sql inline version). Python UDFs (EMBED_AND_PUSH_V2, PREFLIGHT_CHECK) also no longer fall back to localhost defaults. All error messages now guide users to use the Docker bridge gateway IP.

## What to Test
1. Verify the deployed adapter works correctly when OLLAMA_URL is explicitly set (which it is in the CREATE VIRTUAL SCHEMA statement).
2. Verify the adapter script no longer contains the old `localhost:11434` fallback pattern.
3. Verify the adapter script contains the new assertion error message.

## How to Know It Works
- Semantic search queries return results (proves OLLAMA_URL is correctly wired).
- The adapter script text contains the assertion message about OLLAMA_URL being required.
- The adapter script text does NOT contain the old fallback `or "http://localhost:11434"`.

## Common Failure Modes
- Deploy might fail if the adapter script has syntax errors from the edit.
- If OLLAMA_URL is somehow not passed in CREATE VIRTUAL SCHEMA, the creation itself would fail (which is the desired behavior).
