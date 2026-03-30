## 1. Create the Quickstart Document

- [x] 1.1 Create `docs/quickstart.md` with a Prerequisites section listing Docker as the only requirement (with install link)
- [x] 1.2 Add numbered Service Startup section with copy-paste `docker run` commands for Qdrant, Ollama (with `nomic-embed-text` pull), and Exasol
- [x] 1.3 Add a clearly marked callout explaining the Docker bridge IP issue with the `docker exec exasoldb ip route show default` discovery command
- [x] 1.4 Add Adapter Installation section: instruct user to copy `dist/adapter.lua` into the SQL template, with the full `CREATE SCHEMA`, `CREATE CONNECTION`, `CREATE LUA ADAPTER SCRIPT`, and `CREATE VIRTUAL SCHEMA` SQL block using `<DOCKER_BRIDGE_IP>` as a placeholder
- [x] 1.5 Add Data Loading section with 3–5 inline sample documents using the `EMBED_AND_PUSH` UDF (or fallback REST approach), including `ALTER VIRTUAL SCHEMA ... REFRESH`
- [x] 1.6 Add First Query section with a ready-to-run `SELECT` statement and a description of expected output columns (ID, TEXT, SCORE)
- [x] 1.7 Add "What's Next" section with links to `usage-guide.md`, `udf-ingestion.md`, and `limitations.md`

## 2. Link from README

- [x] 2.1 Add a "Quickstart" link near the top of `README.md` pointing to `docs/quickstart.md` so new visitors can find it immediately
