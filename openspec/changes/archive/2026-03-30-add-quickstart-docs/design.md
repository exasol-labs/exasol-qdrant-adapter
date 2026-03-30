## Context

The project has a detailed README and several docs covering specific subsystems (deployment, UDF ingestion, limitations), but no single entry point that walks a brand-new user through every step without prerequisite knowledge. Non-technical users — analysts, data scientists, or business users — currently have to piece together information from multiple documents and navigate Docker networking gotchas on their own.

This change is documentation-only. There are no code, schema, or dependency changes.

## Goals / Non-Goals

**Goals:**
- Produce a single `docs/quickstart.md` that a non-technical user can follow top-to-bottom
- Cover the full path: start services → install adapter → load sample data → run first query
- Use the simplest possible path (Docker Compose or sequential `docker run` commands, copy-paste SQL)
- Call out the one known stumbling block (Docker networking IP) in plain language with a clear fix
- Keep the guide self-contained — no required reading of other docs to succeed

**Non-Goals:**
- Replacing or rewriting the existing detailed docs (deployment.md, udf-ingestion.md, usage-guide.md)
- Covering advanced topics (OpenAI provider, custom TLS, large-scale ingestion, production hardening)
- Modifying any adapter code or SQL scripts
- Adding a Docker Compose file (out of scope; sequential `docker run` is sufficient and requires no new files)

## Decisions

**Decision: Target Docker as the only setup path**
The quickstart will assume Docker is available. This eliminates branching for OS-specific installation instructions and covers the vast majority of non-production use cases. Users on bare-metal or Kubernetes are directed to the existing deployment.md.
_Alternative considered:_ Native install instructions per OS — rejected because complexity would undermine the "non-technical user" goal.

**Decision: Use a hardcoded sample dataset (3–5 short sentences)**
Rather than asking the user to bring their own data, the guide provides a tiny copy-paste dataset so the user gets a result on their very first query. This creates an immediate "it works" moment.
_Alternative considered:_ Pointing to a CSV or external dataset — rejected because it adds a download/import step.

**Decision: Document the Docker bridge IP gotcha inline, not as a footnote**
The most common failure point for new users is using `localhost` instead of the Docker bridge IP when Exasol runs in a container. This will be surfaced prominently as a "Common Issue" callout right where it matters, not buried in a limitations doc.

**Decision: Include a "What's Next" section at the end**
After success, point non-technical users to usage-guide.md and udf-ingestion.md so they have a natural path to deeper capability without being overwhelmed upfront.

## Risks / Trade-offs

- **Risk: Docker bridge IP varies by machine** → Mitigation: Include the exact `docker exec exasoldb ip route show default` command to discover the IP dynamically; use a placeholder like `<DOCKER_BRIDGE_IP>` in SQL samples.
- **Risk: Guide goes stale if adapter changes** → Mitigation: The guide references `dist/adapter.lua` and SQL syntax that has been stable; keep language version-agnostic where possible.
- **Risk: Exasol Docker image version drift** → Mitigation: Link to the official Exasol Docker Hub page rather than hardcoding a version tag.
