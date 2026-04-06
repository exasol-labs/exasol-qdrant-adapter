# Test Description: Topic 4 - Python UDF Raw Tracebacks

## What Changed
Added `urllib.error.URLError` exception handling to all HTTP functions in both EMBED_AND_PUSH (V1) and EMBED_AND_PUSH_V2 in `install_all.sql`. Also added URLError handling to `CREATE_QDRANT_COLLECTION`. Error messages now include the URL that failed and a clean reason, instead of raw 30-40 line urllib tracebacks. Also updated `exasol_udfs/embed_and_push.py` source file.

## What to Test
1. Verify that `install_all.sql` contains URLError handling in all Python UDF HTTP functions.
2. Test that a connection failure to an unreachable host produces a clean one-line error.
3. Verify that normal operations (semantic search) still work without regression.

## How to Know It Works
- Connecting to an unreachable host produces "Connection to X failed: reason" (one line).
- No raw urllib.error.URLError tracebacks leak to the user.
- Existing functionality (search, ingestion) is unaffected.

## Common Failure Modes
- URLError handler missing from one of the duplicated function blocks (V1 vs V2).
- The error message format not matching the expected pattern.
- HTTPError messages accidentally broken while adding URLError handling.
