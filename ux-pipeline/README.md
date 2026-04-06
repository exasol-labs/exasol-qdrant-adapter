# UX Pipeline

Automated pipeline for implementing and testing UX fixes from `ux-pipeline/ux-study/consolidated_findings.md`.

## One-line usage

Launch the `ux-pipeline` agent in Claude Code. It orchestrates everything automatically.

## Architecture

- **Orchestrator** (`.claude/agents/ux-pipeline.md`) — single entry point, manages the full flow
- **Infra-guardian** — ensures Docker, Exasol, Qdrant, Ollama are running
- **Topic-provider** — reads consolidated_findings.md, tracks progress, serves topics sequentially
- **UX-fixer** — implements code fixes, writes test artifacts
- **UX-tester** — runs tests via MCP SQL tools, makes judgment calls
- **Deploy-wrapper** — tears down and redeploys the full stack from scratch

## Flow

1. Infra-guardian verifies all services are running
2. Topic-provider returns next pending topic
3. UX-fixer implements the fix and writes test criteria
4. Deploy-wrapper tears down and redeploys from scratch
5. UX-tester runs topic-specific tests
6. On pass: mark implemented, next topic. On fail: fixer retries (max 3).
7. After 3 failures: orchestrator proposes fixes and pauses for user input.

## Folder structure

```
ux-pipeline/
  agents/           # Sub-agent prompt definitions
  state/            # progress.json — topic status tracking
  tests/topic-N/    # Test artifacts per topic (committed to git)
```

## Transferring to another project

1. Copy `ux-pipeline/` folder
2. Copy `.claude/agents/ux-pipeline.md`
3. Update paths in `ux-pipeline.md` if your project root differs
