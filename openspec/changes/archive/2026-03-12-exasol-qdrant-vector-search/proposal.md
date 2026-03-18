## Why

Exasol users lack native vector/semantic search capabilities within their SQL environment. By bridging Exasol's virtual schema mechanism to Qdrant, users can create vector tables, insert text for automatic embedding, and perform semantic similarity searches using standard SQL — without managing embeddings, credentials, or external tooling outside their existing workflows.

## What Changes

- New virtual schema adapter enabling Exasol SQL (`CREATE TABLE`, `INSERT INTO`, `SELECT`) to be routed to Qdrant as vector operations
- `CREATE TABLE` against the vector virtual schema triggers Qdrant collection creation with a configured embedding model (cosine similarity by default)
- `INSERT INTO` forwards raw text to Qdrant; Qdrant computes and stores embeddings automatically
- `SELECT` with a query string triggers Qdrant's internal embedding + similarity search, returning ranked results (ID, text, score) as a standard Exasol result set
- `LIMIT` clause maps to Qdrant's top-k parameter
- Virtual schema properties store the Qdrant endpoint, API key, and inference model name centrally — no per-query credential management
- Credentials stored via Exasol's native connection object mechanism

## Capabilities

### New Capabilities

- `collection-management`: Create and manage Qdrant collections via SQL `CREATE TABLE` against the vector virtual schema
- `text-ingestion`: Insert raw text rows that are automatically embedded and stored in Qdrant via `INSERT INTO`
- `vector-search`: Perform semantic similarity search via `SELECT` with a query string, returning ranked results with ID, text, and score
- `virtual-schema-config`: Configure and manage Qdrant connection, API key, and embedding model at the virtual schema level using Exasol connection objects

### Modified Capabilities

## Impact

- **New component**: Exasol Virtual Schema adapter (Java-based, using Exasol's Virtual Schema API) that translates SQL push-down operations to Qdrant REST API calls
- **External dependency**: Qdrant instance with inference API enabled (model must be available in Qdrant's inference API)
- **Exasol**: Requires a virtual schema definition and a named connection object for credentials; no changes to Exasol core
- **No breaking changes** to existing Exasol schemas or functionality
