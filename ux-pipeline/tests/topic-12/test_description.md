# Test Description: Topic 12 - No Performance Tuning Knobs

## What Changed
EMBED_AND_PUSH_V2 now reads optional `batch_size` and `max_chars` from the CONNECTION config JSON. Defaults are preserved (100, 6000). Documented in README and install_all.sql comments.

## How to Know It Works
- EMBED_AND_PUSH_V2 script text contains config.get("batch_size")
- README has "Ingestion Tuning" section
