## Why

The existing documentation assumes familiarity with Docker networking, Exasol internals, and SQL client tooling — creating a steep barrier for analysts and data professionals who want to use semantic search but aren't infrastructure engineers. A dedicated quickstart doc with a clear, step-by-step path to "first query in 15 minutes" will dramatically reduce time-to-value for non-technical users.

## What Changes

- Add `docs/quickstart.md` — a standalone, beginner-friendly guide that walks a user from zero to running their first semantic search query
- The guide covers: starting services with Docker, installing the adapter (copy-paste SQL), loading sample data, and running a search
- No new code, scripts, or adapter changes — documentation only

## Capabilities

### New Capabilities

- `quickstart-guide`: End-to-end beginner guide covering Docker setup, adapter installation, data loading, and first query — targeting users with no prior Exasol/Qdrant/Ollama experience

### Modified Capabilities

_(none — no existing spec-level behavior is changing)_

## Impact

- New file: `docs/quickstart.md`
- README.md may optionally gain a link to the quickstart (minor edit, not required for this change)
- No code changes, no API changes, no dependency changes
