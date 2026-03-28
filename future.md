# Future Work

## Data Quality — TEXT column empty in Qdrant records

The `TEXT` column returns empty for many records when querying via the virtual schema.

**Root cause:** The `EMBED_AND_PUSH` UDF did not populate the `text` payload field in Qdrant when ingesting data from `MUFA.SEMANTIC`. The adapter correctly reads whatever is stored in the `text` field — the field is simply empty.

**Fix:** Re-ingest the data ensuring the `text` payload field is set to the source text column value for each point upserted into Qdrant.
