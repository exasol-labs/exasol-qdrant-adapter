# Test Description: Topic 14 - No SCORE Filtering

## What Changed
Documented that SCORE filtering already works via Exasol's post-pushdown filtering. Added example to README showing WHERE "QUERY" = 'text' AND "SCORE" > 0.6 syntax.

## How to Know It Works
Query with SCORE > 0.6 returns only high-relevance results. README documents the feature.
