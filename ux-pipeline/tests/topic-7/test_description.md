# Test Description: Topic 7 - No Exasol Docker Run Command

## What Changed
Added an Exasol docker run step (Step 1) to the README Quick Start section, with the --privileged flag, 90-second wait note, and default credentials. Also added docker run commands for all three services in the install_all.sql prerequisites comment. Renumbered existing steps (Qdrant became 2, Ollama became 3, Install became 4).

## What to Test
Verify that README.md and install_all.sql contain the Exasol docker run command with all required details. Verify step numbering is sequential and correct.

## How to Know It Works
- README.md Quick Start Step 1 is "Start Exasol" with docker run command
- The command includes --privileged flag
- Default credentials (sys/exasol) and wait time (90 seconds) are documented
- install_all.sql prerequisites mention the Exasol docker command

## Common Failure Modes
- Step numbering might be off if the edit didn't correctly insert
- Privileged flag might be missing (Exasol requires it)
