# Test Description: Topic 5 - No Sample Data / Hello World Block

## What Changed
Added a "Hello World: End-to-End Example" section to the README with a complete copy-pasteable SQL block that creates a sample table, inserts 5 documents, ingests them into Qdrant via EMBED_AND_PUSH_V2, and runs two semantic searches. Also added a "Hello World (quick test)" section to the install_all.sql usage examples.

## What to Test
1. Verify the Hello World section exists in both README.md and install_all.sql.
2. Verify the Hello World example actually works end-to-end (create table, ingest, search).
3. Verify it uses EMBED_AND_PUSH_V2 (not V1) as the recommended ingestion method.
4. Verify existing functionality is unaffected.

## How to Know It Works
- README.md has a "Hello World" section with complete SQL.
- install_all.sql has a "Hello World" section in the usage examples.
- Running the example produces semantic search results where AI/ML docs rank highest for "artificial intelligence".

## Common Failure Modes
- The hello_world Qdrant collection might already exist from a previous run (CREATE_QDRANT_COLLECTION returns "exists:" instead of "created:").
- The EMBED_AND_PUSH_V2 might fail if the embedding_conn CONNECTION is missing or misconfigured.
- The virtual schema might need a REFRESH before the new collection is visible.
