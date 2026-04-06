# Test Description: Topic 11 - REFRESH After CREATE is Redundant

## What Changed
Already fixed in a previous pipeline run. The explicit ALTER VIRTUAL SCHEMA REFRESH was removed from install_all.sql and replaced with a comment explaining why it's unnecessary (CREATE VIRTUAL SCHEMA performs an implicit refresh).

## How to Know It Works
All ALTER VIRTUAL SCHEMA REFRESH occurrences in install_all.sql are in comments only.
