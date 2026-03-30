# Specification: Quickstart Guide

## Overview
This specification defines the requirements for the `docs/quickstart.md` file — a self-contained guide enabling a user with no prior Exasol, Qdrant, or Ollama experience to achieve a working semantic search query using only Docker.

---

## Requirements

### Requirement: Single-file quickstart guide exists in docs
The project SHALL provide a `docs/quickstart.md` file that a user with no prior Exasol, Qdrant, or Ollama experience can follow to achieve a working semantic search query.

#### Scenario: File is present and discoverable
- **WHEN** a user opens the `docs/` directory
- **THEN** they SHALL find `quickstart.md` as a top-level file in that directory

---

### Requirement: Prerequisites section lists only Docker
The quickstart guide SHALL list Docker (or Docker Desktop) as the only required prerequisite, with no mention of Maven, Java, BucketFS, or Lua tooling.

#### Scenario: User reads prerequisites
- **WHEN** a user reads the Prerequisites section
- **THEN** they SHALL see Docker listed as the sole requirement with a link to install it

---

### Requirement: Service startup steps are sequential and copy-paste ready
The guide SHALL provide ordered, numbered steps to start Qdrant, Ollama, and Exasol using `docker run` commands that can be copied verbatim.

#### Scenario: User starts all three services
- **WHEN** a user runs the three `docker run` commands in order
- **THEN** Qdrant SHALL be accessible on port 6333, Ollama on port 11434, and Exasol on its standard SQL port

---

### Requirement: Adapter installation is a single copy-paste SQL block
The guide SHALL instruct the user to copy the contents of `dist/adapter.lua` into a SQL statement and execute it in their SQL client, with no build step required.

#### Scenario: User installs the adapter
- **WHEN** a user copies `dist/adapter.lua` contents into the provided SQL template and executes it
- **THEN** the adapter script SHALL be registered in Exasol and the virtual schema SHALL be created

---

### Requirement: Docker bridge IP is explained with a discovery command
The guide SHALL explain that `localhost` does not work inside the Exasol container and provide the exact shell command to find the correct Docker bridge gateway IP.

#### Scenario: User encounters connection failure due to wrong IP
- **WHEN** a user reads the guide before executing any SQL
- **THEN** they SHALL see a clearly marked callout that explains the bridge IP issue and shows `docker exec exasoldb ip route show default` to resolve it

---

### Requirement: Guide opens with a user journey narrative
The quickstart SHALL open with a 2–3 sentence scenario framing — introducing a fictitious but realistic user (e.g., a data analyst at a company with a support knowledge base) — that establishes why semantic search is useful in context, before any technical steps begin.

#### Scenario: User reads the intro
- **WHEN** a user opens `docs/quickstart.md`
- **THEN** they SHALL encounter a concrete scenario description before seeing any Docker or SQL instructions

---

### Requirement: Sample data is provided inline for copy-paste ingestion
The guide SHALL include 10–15 sample documents drawn from a single coherent domain (a customer support knowledge base), covering at least 4 distinct topic clusters (authentication/account, billing, connectivity/technical, product features), as ready-to-run SQL statements using the `EMBED_AND_PUSH` UDF, so that the user can observe semantically meaningful search results across a realistic dataset without preparing their own data.

#### Scenario: User loads sample data
- **WHEN** a user runs the provided sample data SQL statements
- **THEN** at least 10 documents SHALL be inserted into a Qdrant collection named in the guide, spanning at least 4 distinct topic areas

#### Scenario: Dataset coherence
- **WHEN** a user reads the sample documents in the guide
- **THEN** they SHALL be able to identify a common domain and understand how to substitute their own data from the same or a similar domain

---

### Requirement: First query example produces ranked results
The guide SHALL include at least 3 `SELECT` statements against the virtual schema, each with a different `WHERE "QUERY" = '...'` clause, demonstrating: (1) a direct question that matches a document, (2) a paraphrase that shares no keywords with the top result, and (3) a vague or partial query. Each query SHALL be accompanied by a brief explanation of why semantic search ranked the result it did.

#### Scenario: User runs a direct-match query
- **WHEN** a user executes a query that closely mirrors document language
- **THEN** the most relevant document SHALL appear first with a high SCORE (≥ 0.85)

#### Scenario: User runs a paraphrase query
- **WHEN** a user executes a query that paraphrases document content without sharing keywords
- **THEN** the semantically matching document SHALL still appear in the top 3 results

#### Scenario: User runs a vague intent query
- **WHEN** a user executes a query with minimal or generic terms
- **THEN** the results SHALL be plausibly relevant and scored proportionally, demonstrating graceful degradation

---

### Requirement: "Adapt This to Your Data" section follows the first working query
Immediately after the first successful query result, the guide SHALL include a clearly marked section explaining how to substitute the sample dataset with the user's own data. This section SHALL include a parameterised SQL template showing which values to replace (collection name, source table, ID column, text column) and SHALL name at least 3 alternative domains where semantic search applies.

#### Scenario: User wants to use their own data
- **WHEN** a user reaches the "Adapt This to Your Data" section
- **THEN** they SHALL see a SQL snippet with clearly labelled placeholder variables and a list of domain examples they can map to their own use case

---

### Requirement: Real-world join pattern is demonstrated
The guide SHALL include at least one SQL example showing how to join semantic search results back to a real Exasol table, using a clearly fictional but representative table name and schema (e.g., `SUPPORT.TICKETS`), so users understand how to combine vector search with structured data they already have in Exasol.

#### Scenario: User joins search results to existing data
- **WHEN** a user reads the join example
- **THEN** they SHALL see a complete, runnable SQL query that joins `vector_schema.<collection>` to a named Exasol table on the `ID` column, ordered by SCORE

---

### Requirement: "What's Next" section links to deeper docs
The guide SHALL end with a short section pointing to `usage-guide.md`, `udf-ingestion.md`, and `limitations.md` for users who want to go further.

#### Scenario: User finishes the quickstart
- **WHEN** a user reaches the end of `docs/quickstart.md`
- **THEN** they SHALL see named links to at least two other documentation files in the `docs/` directory
