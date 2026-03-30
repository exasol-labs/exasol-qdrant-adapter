## Why

The current quickstart uses generic, disconnected sample sentences (Eiffel Tower facts, random AI statements) that don't help users understand how to apply semantic search to their own data. A realistic, domain-specific user journey — told through a single coherent scenario — will let users immediately see themselves in the guide and understand how to adapt it to their real-world use case.

## What Changes

- Rewrite `docs/quickstart.md` to lead with a **user journey narrative**: a fictitious but realistic scenario (a support team using semantic search over a product knowledge base) that frames every step in context
- Replace the disconnected sample data with a coherent, domain-realistic dataset (10–15 support articles / FAQ entries) that a user can plausibly map to their own data
- Add a "Adapt This to Your Data" section after the first working query, showing how to substitute the sample collection with their own content
- Add 3 realistic query examples that demonstrate different semantic search behaviours (synonyms, paraphrase, vague intent) against the scenario data
- Add a "Real-World Patterns" section showing how to join search results back to a real Exasol table (the kind of SQL a data analyst would actually write)
- Keep all existing technical steps (Docker, IP discovery, adapter install, UDF setup) unchanged — only the narrative framing and data change

## Capabilities

### New Capabilities

_(none — no net-new capabilities are being introduced)_

### Modified Capabilities

- `quickstart-guide`: The REQUIREMENTS for the guide are changing — it must now include a user journey narrative, a coherent domain dataset, real-world query examples, an adaptation guide, and a join pattern example. These are spec-level behaviour changes to what the guide must contain.

## Impact

- Modified file: `docs/quickstart.md`
- No code changes, no adapter changes, no SQL script changes
- The existing `openspec/specs/quickstart-guide/spec.md` will need delta requirements for the new content sections
