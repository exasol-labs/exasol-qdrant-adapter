# Test Criteria: Topic 17 - Broken Unit Test Suite

## Test Cases
| # | Check | Pass Criteria |
|---|-------|---------------|
| 1 | `python -m unittest tests.unit.test_create_collection -v` | All tests pass (0 failures) |
| 2 | `python -m unittest tests.unit.test_embed_and_push -v` | All tests pass (0 failures) |
| 3 | No imports of qdrant_client in unit tests | No qdrant_client import in test files |
