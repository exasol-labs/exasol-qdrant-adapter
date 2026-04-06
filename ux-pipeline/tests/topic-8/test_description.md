# Test Description: Topic 8 - Silent Behavior on Unsupported Predicates

## What Changed
Modified the hint row returned when no valid QUERY = 'text' predicate is found. Changes:
1. SCORE changed from 0 to 1 (so hint survives WHERE "SCORE" > X post-filtering)
2. QUERY column now contains descriptive text about supported predicates (so hint is more visible)
3. ID changed from 'NO_QUERY' to 'HINT' for consistency
4. Added detection of unsupported filter types with a more specific error message

## What to Test
1. Normal search queries still work (regression check)
2. No-filter queries return the hint row
3. The hint row survives SCORE-based post-filtering (SCORE > 0.5)
4. The QUERY column contains useful guidance

## How to Know It Works
- Query without WHERE returns a hint row with SCORE=1.0 and descriptive text
- WHERE "SCORE" > 0.5 still shows the hint row (previously returned 0 rows)
- Normal WHERE "QUERY" = 'text' queries work as before

## Common Failure Modes
- Exasol might filter out the hint row if SCORE or QUERY values don't pass the filter
- LIKE predicates may still filter out the hint (this is a known limitation)
