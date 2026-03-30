## ADDED Requirements

### Requirement: Single-file quickstart guide exists in docs
The project SHALL provide a `docs/quickstart.md` file that a user with no prior Exasol, Qdrant, or Ollama experience can follow to achieve a working semantic search query.

#### Scenario: File is present and discoverable
- **WHEN** a user opens the `docs/` directory
- **THEN** they SHALL find `quickstart.md` as a top-level file in that directory

### Requirement: Prerequisites section lists only Docker
The quickstart guide SHALL list Docker (or Docker Desktop) as the only required prerequisite, with no mention of Maven, Java, BucketFS, or Lua tooling.

#### Scenario: User reads prerequisites
- **WHEN** a user reads the Prerequisites section
- **THEN** they SHALL see Docker listed as the sole requirement with a link to install it

### Requirement: Service startup steps are sequential and copy-paste ready
The guide SHALL provide ordered, numbered steps to start Qdrant, Ollama, and Exasol using `docker run` commands that can be copied verbatim.

#### Scenario: User starts all three services
- **WHEN** a user runs the three `docker run` commands in order
- **THEN** Qdrant SHALL be accessible on port 6333, Ollama on port 11434, and Exasol on its standard SQL port

### Requirement: Adapter installation is a single copy-paste SQL block
The guide SHALL instruct the user to copy the contents of `dist/adapter.lua` into a SQL statement and execute it in their SQL client, with no build step required.

#### Scenario: User installs the adapter
- **WHEN** a user copies `dist/adapter.lua` contents into the provided SQL template and executes it
- **THEN** the adapter script SHALL be registered in Exasol and the virtual schema SHALL be created

### Requirement: Docker bridge IP is explained with a discovery command
The guide SHALL explain that `localhost` does not work inside the Exasol container and provide the exact shell command to find the correct Docker bridge gateway IP.

#### Scenario: User encounters connection failure due to wrong IP
- **WHEN** a user reads the guide before executing any SQL
- **THEN** they SHALL see a clearly marked callout that explains the bridge IP issue and shows `docker exec exasoldb ip route show default` to resolve it

### Requirement: Sample data is provided inline for copy-paste ingestion
The guide SHALL include 3–5 sample text documents as ready-to-run SQL statements using the `EMBED_AND_PUSH` UDF or equivalent, so the user can load data without preparing their own.

#### Scenario: User loads sample data
- **WHEN** a user runs the provided sample data SQL statements
- **THEN** at least 3 documents SHALL be inserted into a Qdrant collection named in the guide

### Requirement: First query example produces ranked results
The guide SHALL include a `SELECT` statement against the virtual schema with a `WHERE "QUERY" = '...'` clause and show the expected output format (ID, TEXT, SCORE columns).

#### Scenario: User runs the first search query
- **WHEN** a user executes the provided sample `SELECT` query
- **THEN** they SHALL receive rows ordered by SCORE descending with non-empty ID and TEXT values

### Requirement: "What's Next" section links to deeper docs
The guide SHALL end with a short section pointing to `usage-guide.md`, `udf-ingestion.md`, and `limitations.md` for users who want to go further.

#### Scenario: User finishes the quickstart
- **WHEN** a user reaches the end of `docs/quickstart.md`
- **THEN** they SHALL see named links to at least two other documentation files in the `docs/` directory
