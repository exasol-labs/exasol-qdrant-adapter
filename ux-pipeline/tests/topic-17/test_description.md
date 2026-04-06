# Test Description: Topic 17 - Broken Unit Test Suite

## What Changed
Rewrote both unit test files to match the current stdlib-only source code:
- `test_create_collection.py`: Removed qdrant_client mocks, now mocks urllib.request.urlopen
- `test_embed_and_push.py`: Removed OpenAI SDK, SentenceTransformer, and QdrantClient mocks, now mocks urllib

## How to Know It Works
All 16 tests pass with `python -m unittest tests.unit.test_create_collection tests.unit.test_embed_and_push`.
