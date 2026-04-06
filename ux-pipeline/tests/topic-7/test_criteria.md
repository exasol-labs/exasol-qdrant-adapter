# Test Criteria: Topic 7 - No Exasol Docker Run Command

## Prerequisites
- README.md and install_all.sql exist in the project

## Test Cases

| # | Check | Expected Outcome | Pass Criteria |
|---|-------|-----------------|---------------|
| 1 | README.md Quick Start section | Contains Exasol docker run command before Qdrant/Ollama steps | README contains "docker run -d --name exasoldb" and step appears as Step 1 |
| 2 | README.md Quick Start section | Mentions privileged flag, wait time, and default credentials | README contains "--privileged", "90 seconds", "sys", "exasol" |
| 3 | install_all.sql prerequisites | Contains Exasol docker run command in comments | File contains "docker run -d --name exasoldb" |
| 4 | Step numbering | Steps are sequential: 1 (Exasol), 2 (Qdrant), 3 (Ollama), 4 (Install) | README has ### 1 through ### 4 in correct order |

## Negative Tests

N/A (documentation-only change, no SQL behavior to test)
