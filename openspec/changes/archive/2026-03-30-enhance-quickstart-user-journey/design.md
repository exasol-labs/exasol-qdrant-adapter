## Context

The current `docs/quickstart.md` gets users to a working query but leaves them without a mental model for how to apply semantic search to their own data. The sample sentences (random geography facts, generic AI statements) are incoherent as a dataset — they don't demonstrate the real value of semantic search, which shines when users search with their own words across a body of related content.

This change is purely documentation. No code, scripts, or adapter behaviour changes.

## Goals / Non-Goals

**Goals:**
- Give the guide a single, consistent real-world scenario from start to finish
- Use a dataset realistic enough that users immediately see how to map it to their own data
- Show semantic search's distinctive value: finding relevant results even when query wording differs from document wording
- Provide a clear "now substitute your own data" moment after the first success
- Show one realistic downstream SQL pattern (joining search results to a real table)

**Non-Goals:**
- Replacing existing technical steps (Docker, IP, adapter, UDF setup are unchanged)
- Covering multiple domains or letting the user choose a scenario
- Adding new code, scripts, or adapter features
- Comprehensive SQL tutorial — one join example is enough

## Decisions

**Decision: Use a customer support knowledge base as the scenario domain**
A support KB is immediately relatable to nearly any company using Exasol — most organisations have FAQs, help articles, or policy documents they'd want to search semantically. It also showcases semantic search's core value proposition: users phrase questions in their own words, not in the exact language of the article.
_Alternative considered:_ Product catalog (e-commerce) — rejected because it implies numeric/structured search more than semantic; research papers — rejected because too academic for the target audience.

**Decision: Use 12 sample support articles covering 4 topic clusters**
Four clusters (account/auth, billing, technical/connectivity, features) allow the guide to demonstrate that:
1. Semantically similar queries rank cluster members highly even without keyword overlap
2. Unrelated queries rank low, showing the discriminative power of the score
3. The dataset is small enough to fit in a VALUES clause, large enough to be illustrative

_Alternative considered:_ 5 documents (too few to show cross-cluster discrimination) or 20+ (too long to read in a guide).

**Decision: Show 3 query examples with commentary, not just one**
Three queries demonstrate: (1) a direct question, (2) a paraphrase that shares no keywords with the matching article, (3) a vague/incomplete intent. Each is annotated to show why semantic search retrieved what it did.
_Alternative considered:_ One query — insufficient to teach the concept; five queries — too verbose for a quickstart.

**Decision: "Adapt This to Your Data" section uses a fill-in-the-blank SQL pattern**
Rather than prose advice, give users a parameterised SQL template they can run immediately with their own table name and text column. This keeps the guide action-oriented.

**Decision: Join example uses a fictional `SUPPORT.TICKETS` table**
The join pattern is shown against a simple, clearly fictional table. This keeps the example self-contained while making the pattern immediately obvious for users with their own customer/case tables.

## Risks / Trade-offs

- **Risk: Scenario feels too narrow (only support teams feel it applies)** → Mitigation: The "Adapt This to Your Data" section explicitly names 3 other domains (HR policies, product descriptions, research notes) and shows the substitution is a 2-line change.
- **Risk: 12-row VALUES block feels long to paste** → Mitigation: It's still a single SQL statement; annotate it clearly as "copy and run as-is".
- **Risk: Guide grows significantly longer** → Mitigation: Technical setup steps are unchanged; new content replaces the existing thin sample data section, it doesn't add on top of it. Net length increase is modest.
