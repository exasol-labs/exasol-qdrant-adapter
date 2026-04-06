# UX Study -- Iteration 12: Weekend Hobbyist Walkthrough

**Date:** 2026-04-05
**Persona:** Weekend hobbyist. Knows basic SQL, has used Docker a few times, found this project on GitHub and wants to try semantic search "for fun." Never used Exasol. Does not know what a "virtual schema" or "BucketFS" means.
**Method:** Followed the README.md from top to bottom, documenting every moment of confusion and every place I got stuck.

---

## Overall UX Score: 7.2 / 10

**Weighted toward accessibility for newcomers.**

| Category                         | Score | Weight | Weighted |
|----------------------------------|-------|--------|----------|
| README clarity and structure     | 8.5   | 25%    | 2.13     |
| Getting prerequisites running    | 8.0   | 15%    | 1.20     |
| Deployment (install_all.sql)     | 7.0   | 25%    | 1.75     |
| Data ingestion                   | 6.0   | 20%    | 1.20     |
| Querying / end-to-end payoff     | 9.0   | 10%    | 0.90     |
| Error recovery / idempotency     | 3.0   | 5%     | 0.15     |
| **Weighted Total**               |       |        | **7.33** |

Rounded: **7.2 / 10**

---

## Walkthrough Timeline

### Phase 1: First Impression (README.md)

**Time to read:** ~4 minutes.

**What went well:**
- The opening SQL example immediately shows what this does. As a hobbyist, I get it: "I write SQL, I get semantic search results." That is a strong hook.
- The ASCII data flow diagram is clear: Exasol -> Ollama -> Qdrant -> Results. Even without knowing what a virtual schema is, I understand the pipeline.
- "No BucketFS, no JAR, no Maven, no pasting. One file, one run, everything deployed." This is the exact sentence that would keep a hobbyist from closing the tab. Every word is doing work.
- Prerequisites table is clean and minimal: three Docker containers.

**Moments of confusion:**
1. **"Virtual Schema" is never defined.** The README uses this term 17 times but never explains what it is. As a hobbyist, I Googled it. Exasol's docs explain it as "a projection of external data into Exasol's SQL namespace" which is... dense. A single sentence like "A virtual schema lets you query external data (Qdrant) as if it were a regular Exasol table" would save 5 minutes of confusion.

2. **"Adapter Script" is unexplained.** The Lua code is called an "adapter script" but I have no mental model for what that means. Is it a stored procedure? A plugin? A trigger? The term is used as if everyone knows.

3. **Two Exasol Docker images exist and the README does not mention which one.** Running `docker run exasol/docker-db` vs `exasol/nano` is a real choice a hobbyist faces. The README's prerequisites say "Exasol 7.x+ (Docker or on-premise)" but does not provide a `docker run` command for Exasol itself. Qdrant and Ollama get exact `docker run` commands. Exasol does not. This is the single biggest gap for a newcomer -- the three lines that start Qdrant and Ollama are great, but the thing that is hardest to set up (Exasol) is left as an exercise.

4. **What SQL client?** The README says "Open install_all.sql in your SQL client (DBeaver, DbVisualizer, etc.)." A hobbyist does not have DBeaver installed. There is no mention of how to connect to Exasol (host, port, default credentials). I would need to go to Exasol's docs to figure out that the default port is 8563 and the default user is `sys/exasol`.

### Phase 2: Prerequisites (Docker Containers)

**Time spent:** ~6 minutes (assuming Exasol was already running).

**What went well:**
- Qdrant and Ollama `docker run` commands are copy-paste ready. No flags to look up.
- `docker exec ollama ollama pull nomic-embed-text` is clear.

**Moments of confusion:**
5. **No Exasol docker run command.** As noted above. I would have to search the internet for:
   ```
   docker run -d --name exasoldb -p 8563:8563 --privileged exasol/docker-db:latest
   ```
   This is the one command that, if included, would make the Quick Start truly self-contained. The privileged flag is also something a hobbyist would not know.

6. **Docker bridge gateway IP.** The README explains this well and even provides the `docker exec exasoldb ip route show default` command. However, the concept of "why services inside a container cannot reach localhost" would confuse a hobbyist. The explanation is functional ("use 172.17.0.1") but the *why* is missing. A hobbyist would think "but I just started Qdrant on localhost, why can't Exasol see it?"

### Phase 3: Deployment (install_all.sql)

**Time spent:** ~15 minutes (including debugging).

**What went well:**
- The file is extremely well-structured with clear step numbers and box-drawing headers.
- The configuration section at the top tells you exactly what 5 values to change. Find-and-replace is a good approach.
- Comments explain every step, not just what it does but why.
- The `CREATE OR REPLACE` pattern means re-running is mostly safe.

**Moments of confusion:**
7. **The `/` terminator.** The Lua adapter script and Python UDFs end with a bare `/` on its own line. This is an Exasol-specific statement terminator. If a hobbyist is using a SQL client that does not understand this (or is running statements through an API), they will get a syntax error and have no idea why. The file does not explain what `/` means. For someone coming from PostgreSQL or MySQL, this is alien.

8. **"One file, one run" is aspirational but fragile.** If you run the file and something goes wrong halfway through (say, the connection to Qdrant fails), you are left in a partial state. Re-running the file then hits the virtual schema ghost state problem (see below). The installer is not truly idempotent -- the `CREATE OR REPLACE` works for scripts and connections, but the virtual schema uses `DROP + CREATE` which can fail if the schema gets into a broken state.

9. **The install_all.sql does not include Exasol setup.** No `docker run` for Exasol, no mention of how to connect a SQL client to it. The file assumes Exasol is already running and you know how to connect. For a hobbyist, this is where the "one file" promise breaks down: it is actually "one file, after you figure out Exasol on your own."

### Phase 4: Data Ingestion

**Time spent:** ~12 minutes.

**What went well:**
- Two options (UDF vs direct HTTP) is good. The hobbyist can choose what fits their comfort level.
- The PowerShell script for Option B is self-contained and readable.
- The EMBED_AND_PUSH UDF parameter documentation is thorough.

**Moments of confusion:**
10. **Option A requires an existing Exasol table.** A hobbyist following the Quick Start does not have any data in Exasol yet. There is no sample data provided. The README shows `FROM MY_SCHEMA.MY_TABLE` as a placeholder. A hobbyist would think: "but I do not have a table yet. How do I create one? What should I put in it?" A 3-line `CREATE TABLE / INSERT INTO` example with sample data would close this gap.

11. **Ollama container IP vs gateway IP.** The README says to use `172.17.0.1` for Qdrant but the Ollama *container IP* (e.g., `172.17.0.4`) for EMBED_AND_PUSH. The note about this is present but buried. A hobbyist would naturally use `172.17.0.1` for both (since that is what the rest of the file uses) and get a connection error from the UDF. The inconsistency between the adapter (which uses the gateway IP for Ollama) and the UDF (which needs the container IP) is the single most confusing networking detail. The README should explain *why* these differ.

12. **`GROUP BY IPROC()` is unexplained.** The README says "IMPORTANT: Always add GROUP BY IPROC()" but does not explain what IPROC() is or why it is needed. A hobbyist has never seen this function. It is an Exasol-specific parallel execution hint. One sentence explaining it would help: "IPROC() distributes the work across Exasol's parallel processing nodes -- it is required for SET UDFs."

13. **Option B uses PowerShell.** A Linux or macOS hobbyist would need to translate this to curl or Python. The function works but the choice of PowerShell as the example language is unusual for a Docker-oriented audience. A curl example would be more universal.

### Phase 5: Querying (The Payoff)

**Time spent:** ~2 minutes. This is where everything clicks.

**What went well:**
- The query syntax is intuitive: `WHERE "QUERY" = 'artificial intelligence'` reads like natural language.
- Results come back with clear columns: ID, TEXT, SCORE.
- The scores are meaningful (doc-1 "Machine learning is a subset of artificial intelligence" scores 0.71 for the query "artificial intelligence" -- that makes sense).
- The "no query" error message is helpful and even provides an example of the correct syntax.
- The JOIN example showing how to combine with other Exasol tables is a nice touch.
- Double-quoting column names is explained with a clear note.

**Moments of confusion:**
14. **Why do column names need double quotes?** The README says to always quote them but does not explain that QUERY and SCORE are reserved words in Exasol. A hobbyist would wonder why `SELECT ID, TEXT, SCORE` does not work.

### Phase 6: Error Recovery and Idempotency

**This is the weakest area of the experience.**

15. **Virtual schema ghost state.** When something goes wrong during virtual schema creation (network error, typo, etc.), the schema can end up in a state where:
    - `SELECT * FROM SYS.EXA_ALL_SCHEMAS` shows it exists
    - `DROP VIRTUAL SCHEMA ... CASCADE` says "not found"
    - `CREATE VIRTUAL SCHEMA ...` says "already exists"
    - Even `DROP FORCE VIRTUAL SCHEMA IF EXISTS ... CASCADE` claims success but the schema persists

    This happened during my walkthrough. The only workaround was to use a completely different schema name. For a hobbyist, this is a dead end. You would think Exasol is broken and give up.

16. **`CREATE OR REPLACE CONNECTION` can silently fail.** I observed a case where `CREATE OR REPLACE CONNECTION qdrant_conn TO 'http://172.17.0.1:6333'` appeared to succeed, but querying `EXA_DBA_CONNECTIONS` showed the old value (port 6334). This was likely a multi-session issue with the MCP tool, but the point stands: the installer assumes sequential execution in a single session.

17. **No rollback guidance.** If something goes wrong, the README has no "Troubleshooting" section. No "if you see error X, try Y." The install_all.sql comments are thorough for the happy path but silent about the unhappy path.

---

## Specific Improvement Recommendations

### High Impact (would raise score to 8.5+)

1. **Add an Exasol `docker run` command to Quick Start.** This is the biggest gap. Three lines:
   ```bash
   docker run -d --name exasoldb -p 8563:8563 --privileged exasol/docker-db:latest
   # Wait ~60 seconds for Exasol to initialize
   # Connect with: host=localhost, port=8563, user=sys, password=exasol
   ```

2. **Add a sample data section.** After `install_all.sql`, provide a complete copy-paste block that creates a table, inserts 5-8 sample docs, runs EMBED_AND_PUSH, refreshes the schema, and executes a search. This should be the "hello world" that proves everything works end to end.

3. **Add a one-sentence definition of "virtual schema."** Something like: "A virtual schema is an Exasol feature that makes external data (in this case, Qdrant collections) appear as regular SQL tables you can query."

4. **Add a Troubleshooting section.** Cover at minimum:
   - "schema already exists" ghost state -> use DROP FORCE or pick a new name
   - Connection refused from Qdrant/Ollama -> check Docker networking IPs
   - "Ollama returned no embedding array" -> check model is pulled

### Medium Impact

5. **Explain the gateway IP vs container IP difference.** Add a callout box: "Why two different IPs? The Lua adapter (Step 3) runs in Exasol's main process, which can reach the Docker bridge gateway (172.17.0.1). The Python UDFs (Step 4) run in Exasol's sandboxed UDF container, which may need the service's actual container IP. This is a Docker networking quirk, not something you did wrong."

6. **Add a curl alternative for Option B data ingestion** alongside the PowerShell example.

7. **Explain what `GROUP BY IPROC()` means** in one sentence.

### Low Impact (polish)

8. Explain the `/` terminator in a comment inside `install_all.sql`.
9. Note which Exasol Docker image to use (docker-db vs nano).
10. Add default Exasol credentials somewhere visible.

---

## Where a Hobbyist Would Give Up

Based on this walkthrough, here are the likely "give up" points ranked by probability:

1. **60% chance: "How do I even start Exasol?"** -- No docker run command, no connection instructions. If they cannot get past this, nothing else matters. (Those who already have Exasol skip this.)

2. **30% chance: Virtual schema ghost state after a failed first attempt.** -- The "already exists / not found" paradox is deeply confusing and has no documented workaround.

3. **20% chance: Ollama IP confusion during EMBED_AND_PUSH.** -- Using the gateway IP instead of container IP causes a silent timeout, and the error message does not hint at the cause.

4. **10% chance: "What SQL client do I use?"** -- Hobbyists without DBeaver would need to find and configure a client. (The MCP server sidesteps this but is not mentioned in the README.)

---

## What Works Exceptionally Well

- The "no BucketFS, no JAR" positioning is perfect for the target audience.
- install_all.sql is one of the best-structured installer scripts I have seen. The box-drawing headers, step numbers, and inline comments make it readable even for someone who does not know Exasol.
- The query syntax (`WHERE "QUERY" = 'your search'`) is elegant and intuitive.
- Error messages from the adapter are helpful (the "no query" message includes a working example).
- The CREATE_QDRANT_COLLECTION UDF auto-detecting dimensions from model name is a nice touch that saves the hobbyist from looking up "768."
- The fixed 4-column schema (ID, TEXT, SCORE, QUERY) is simple and predictable.

---

## Comparison to Previous State

This is iteration 12. Based on the codebase history (commit "UX score upgraded from 5.6 to 8.5"), significant improvements have been made. The current experience is strong on the happy path. The remaining issues are primarily:
- **Onboarding gap** (no Exasol setup instructions)
- **Error recovery** (ghost state, no troubleshooting docs)
- **Networking complexity** (inherent Docker issue, but could be better documented)

The core product experience -- writing a SQL query and getting semantic search results -- is genuinely delightful once you get there.
