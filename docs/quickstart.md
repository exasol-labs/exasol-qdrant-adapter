# Quickstart: Semantic Search in Exasol

Imagine you're a data analyst at a company with hundreds of support articles. Your users can't find what they need because keyword search forces them to guess the exact words used in the document. With this adapter, users can ask questions in plain language — "why can't I log in?" — and get the most relevant articles back, even if the article never uses the word "login". This guide walks you through a complete working example using a realistic support knowledge base, from zero to your first semantic search query.

---

## Before You Begin

**The only thing you need installed is Docker.**

- [Download Docker Desktop](https://www.docker.com/products/docker-desktop/) (Windows / Mac / Linux)

Once Docker Desktop is running, open a terminal (Command Prompt, PowerShell, or Terminal on Mac/Linux) and follow the steps below.

---

## Step 1 — Start the Services

Run each command in your terminal. Wait for each one to finish before running the next.

**1. Start Qdrant (the vector database)**

```bash
docker run -d --name qdrant -p 6333:6333 qdrant/qdrant
```

**2. Start Ollama (the embedding model server)**

```bash
docker run -d --name ollama -p 11434:11434 ollama/ollama
```

**3. Download the embedding model into Ollama** (takes a minute or two)

```bash
docker exec ollama ollama pull nomic-embed-text
```

**4. Start Exasol**

```bash
docker run -d --name exasoldb \
  -p 8563:8563 \
  -p 2580:2580 \
  --privileged \
  exasol/docker-db:latest
```

> Exasol can take 1–2 minutes to fully start up. You can check it is ready by trying to connect:
> `docker exec exasoldb /bin/bash -c 'exaplus -c localhost:8563 -u sys -p exasol -sql "SELECT 1;"' 2>&1 | tail -5`
> If this returns `1`, Exasol is ready. If it fails, wait another minute and retry.

---

## Step 2 — Find Your Network IPs

> **Why this matters:** When Exasol runs inside a Docker container, the word `localhost` refers to the container itself — not your computer. You need to use special IP addresses so the services can talk to each other.

### Your Docker Bridge IP (used for ALL services)

Run this command to find it:

```bash
docker exec exasoldb ip route show default
# Example output: default via 172.17.0.1 dev eth0
```

The IP after `via` (e.g., `172.17.0.1`) is your **Docker bridge IP**. Write it down — you'll use it for **everything**: Qdrant, Ollama, the virtual schema, and the ingestion UDFs. You do NOT need individual container IPs.

---

## Step 3 — Install Everything in Exasol

Open your SQL client (DBeaver, DbVisualizer, or any Exasol-compatible tool) and connect to:

- **Host:** `localhost`
- **Port:** `8563`
- **User:** `sys`
- **Password:** `exasol`

Open the file [`scripts/install_all.sql`](../scripts/install_all.sql) from this project. Replace `172.17.0.1` with the Docker bridge IP you found in Step 2 (if different), then run the entire file as a script.

> **SQL client setup:** This file uses `/` (forward slash on its own line) as the
> statement separator — not `;`. Configure your SQL client accordingly:
>
> - **DBeaver:** Use *SQL Editor → Execute SQL Script* (Alt+X). If it fails,
>   go to *Window → Preferences → SQL Editor* and set the "Script statement delimiter" to `/`.
> - **DbVisualizer:** The `/` delimiter is supported by default when using "Execute as Script."
> - **exaplus (CLI):** Run with `exaplus -f install_all.sql` — it handles `/` natively.

This single file deploys everything:

- Schema and connection to Qdrant
- Lua adapter script (the virtual schema engine)
- Python UDFs for data ingestion (`CREATE_QDRANT_COLLECTION`, `EMBED_AND_PUSH_V2`, `EMBED_AND_PUSH`)
- Preflight health check UDF (`PREFLIGHT_CHECK`)
- Virtual schema ready for queries

> **No pasting, no manual steps.** One file, one run, everything deployed.

---

## Step 4 — Create a Collection and Load the Support Knowledge Base

Replace `<DOCKER_BRIDGE_IP>` with the IP you found in Step 2 (e.g., `172.17.0.1`). Use the same IP for everything.

### 4a. Create a Qdrant collection

```sql
SELECT ADAPTER.CREATE_QDRANT_COLLECTION(
    '<DOCKER_BRIDGE_IP>', 6333, '', 'support_kb', 768, 'Cosine', ''
);
```

### 4b. Load the sample knowledge base

This embeds 12 realistic support articles across 4 topic clusters and stores them in Qdrant. The `embedding_conn` CONNECTION was already created by `install_all.sql` — it contains the Qdrant URL, Ollama URL, provider, and model config so you only need 4 parameters.

> **Timing:** Embedding 12 documents takes about 10–15 seconds. The query will
> appear to "hang" until all embeddings are computed and uploaded — this is normal.

```sql
SELECT ADAPTER.EMBED_AND_PUSH_V2(
    'embedding_conn',
    'support_kb',
    id_col,
    text_col
)
FROM (
    VALUES
    -- Account & Authentication
    ('auth-001', 'How to reset your password: Navigate to the login page and click Forgot password. Enter your registered email address and you will receive a reset link within 5 minutes. The link expires after 24 hours.'),
    ('auth-002', 'Setting up two-factor authentication: Two-factor authentication adds an extra layer of security to your account. Go to Account Settings then Security then Enable 2FA and follow the setup wizard to link your authenticator app.'),
    ('auth-003', 'Account locked after failed login attempts: Your account is automatically locked after 5 consecutive failed login attempts to protect against unauthorised access. Wait 15 minutes for automatic unlock, or contact support for an immediate reset.'),
    -- Billing
    ('bill-001', 'Downloading your invoice: Invoices are available in the Billing section of your account dashboard. Select the relevant billing period and click Download PDF. Invoices are generated on the first of each month.'),
    ('bill-002', 'Updating your payment method: To change your credit card or payment details, go to Billing then Payment Methods then Add New Method. Your new payment method will be used for the next billing cycle.'),
    ('bill-003', 'Cancelling your subscription: To cancel your subscription, navigate to Account Settings then Subscription then Cancel Plan. Your access continues until the end of the current billing period. Data is retained for 30 days after cancellation.'),
    -- Connectivity & Technical
    ('tech-001', 'Troubleshooting VPN connection issues: If you cannot connect through the VPN, first verify that your client is up to date. Check that your firewall allows outbound traffic on port 443. Corporate network users may need to whitelist our IP range.'),
    ('tech-002', 'Dashboard loading slowly or timing out: Slow dashboard performance is often caused by browser extensions or ad blockers. Try disabling extensions, clearing your cache, or opening an incognito window. If the issue persists, check our status page for ongoing incidents.'),
    ('tech-003', 'API rate limits and request throttling: The API allows 1000 requests per minute per API key. If you receive a 429 Too Many Requests response, implement exponential backoff in your client. Enterprise plans have higher rate limits available on request.'),
    -- Product Features
    ('feat-001', 'Exporting data to CSV: To export a report or dataset as CSV, open the relevant view and click the Export button in the top-right toolbar. Large exports are processed in the background and a download link is emailed when ready.'),
    ('feat-002', 'Managing user roles and permissions: Administrators can assign roles such as Viewer, Editor, or Admin to team members under Team Settings then Members. Role changes take effect immediately. Only Admins can invite new users or modify billing settings.'),
    ('feat-003', 'Customising your dashboard with widgets: Click Edit Dashboard to enter layout mode. Drag widgets from the side panel into your layout. Each widget can be resized and configured independently. Save your layout to make the changes permanent.')
) AS t(id_col, text_col)
GROUP BY IPROC();
```

### 4c. Refresh the virtual schema

This makes the `support_kb` collection visible as a table:

```sql
ALTER VIRTUAL SCHEMA vector_schema REFRESH;
```

---

## Step 5 — Run Semantic Searches

Now run some searches and see how semantic understanding works in practice.

> **Note on scores:** Your exact similarity scores will differ from the examples below — they vary by Ollama version, model version, and system architecture. What matters is the **ranking order** and that the correct **topic cluster** appears at the top.

### Query 1 — Direct match

A user asks a question that closely matches an article's language:

```sql
SELECT "ID", "TEXT", "SCORE"
FROM vector_schema.support_kb
WHERE "QUERY" = 'how do I reset my password'
LIMIT 3;
```

| ID       | TEXT (truncated)                                              | SCORE   |
|----------|---------------------------------------------------------------|---------|
| auth-001 | How to reset your password: Navigate to the login page...    | ~0.75+  |
| auth-002 | Setting up two-factor authentication: Two-factor auth adds...| ~0.60+  |
| auth-003 | Account locked after failed login attempts: Your account...  | ~0.60+  |

> `auth-001` scores highest because the article is about exactly this — password reset. The other two are also about account security, so they score in the same neighbourhood.

---

### Query 2 — Paraphrase (no shared keywords)

This query shares no keywords with the top result, but the *meaning* is the same:

```sql
SELECT "ID", "TEXT", "SCORE"
FROM vector_schema.support_kb
WHERE "QUERY" = 'I keep getting locked out and cannot get in'
LIMIT 3;
```

| ID       | TEXT (truncated)                                              | SCORE   |
|----------|---------------------------------------------------------------|---------|
| auth-003 | Account locked after failed login attempts: Your account...  | ~0.70+  |
| auth-001 | How to reset your password: Navigate to the login page...    | ~0.60+  |
| auth-002 | Setting up two-factor authentication: Two-factor auth adds...| ~0.55+  |

> Even though "locked out" and "cannot get in" don't appear in `auth-003`, the semantic meaning is the same as "account locked after failed login attempts." A keyword search would have returned nothing useful here.

---

### Query 3 — Vague intent

A user isn't sure what's wrong and uses generic language:

```sql
SELECT "ID", "TEXT", "SCORE"
FROM vector_schema.support_kb
WHERE "QUERY" = 'something is wrong with my billing'
LIMIT 3;
```

| ID       | TEXT (truncated)                                              | SCORE   |
|----------|---------------------------------------------------------------|---------|
| bill-003 | Cancelling your subscription: To cancel your subscription... | ~0.65+  |
| bill-002 | Updating your payment method: To change your credit card...  | ~0.60+  |
| bill-001 | Downloading your invoice: Invoices are available in the...   | ~0.55+  |

> A vague query still surfaces the right cluster — all three billing articles. The scores are lower than the direct-match query, which reflects appropriate uncertainty. The user has enough to start exploring.

---

### Combining Search Results with Your Exasol Data

If you have a tickets or cases table in Exasol, you can join it directly to the search results to add context:

```sql
-- Find the most relevant KB articles for "slow performance"
-- and enrich with open ticket data
SELECT
    t.ticket_id,
    t.customer_name,
    t.opened_date,
    t.status,
    s."SCORE"  AS relevance,
    s."TEXT"   AS matched_article
FROM (
    SELECT "ID", "TEXT", "SCORE"
    FROM vector_schema.support_kb
    WHERE "QUERY" = 'dashboard is slow and keeps freezing'
    LIMIT 5
) s
JOIN SUPPORT.TICKETS t ON s."ID" = t.article_id
ORDER BY s."SCORE" DESC;
```

This pattern lets you surface the most semantically relevant KB articles for every open ticket — without maintaining a keyword tag system or manually categorising tickets.

---

## Adapting This to Your Own Data

The `support_kb` collection above is a drop-in example. Replacing it with your own data takes two steps:

**1. Create your collection**

```sql
SELECT ADAPTER.CREATE_QDRANT_COLLECTION(
    '<DOCKER_BRIDGE_IP>', 6333, '', 'YOUR_COLLECTION', 768, 'Cosine', ''
);
```

**2. Load from your Exasol table**

The UDF takes two columns from your table:

- **`YOUR_ID_COLUMN`** -- A unique identifier for each row (e.g. a primary key or row number). This is stored as `_original_id` in Qdrant and returned as the `"ID"` column in search results, so you can join back to your source table.
- **`YOUR_TEXT_COLUMN`** -- The text to embed and search against. This is the content that gets converted into a vector by Ollama. For best results, concatenate multiple columns into a descriptive sentence rather than using a single field (see example below).

Both must be `VARCHAR` -- cast numeric or date columns with `CAST(... AS VARCHAR(...))`.

```sql
SELECT ADAPTER.EMBED_AND_PUSH(
    CAST(YOUR_ID_COLUMN AS VARCHAR(36)),
    YOUR_TEXT_COLUMN,                    -- or a concatenation (see below)
    '<DOCKER_BRIDGE_IP>', 6333, '',
    'YOUR_COLLECTION',
    'ollama',
    'http://<OLLAMA_IP>:11434',
    'nomic-embed-text'
)
FROM YOUR_SCHEMA.YOUR_TABLE
GROUP BY IPROC();
```

**Concatenation example:** If your table has `name`, `city`, and `date` columns, combine them into a richer text for better search quality:

```sql
SELECT ADAPTER.EMBED_AND_PUSH(
    CAST("id" AS VARCHAR(36)),
    "name" || ' in ' || "city" || '. Date: ' || CAST("date" AS VARCHAR(10)),
    '<DOCKER_BRIDGE_IP>', 6333, '',
    'events',
    'ollama',
    'http://<OLLAMA_IP>:11434',
    'nomic-embed-text'
)
FROM MY_SCHEMA.EVENTS
GROUP BY IPROC();
```

Then refresh and query:

```sql
ALTER VIRTUAL SCHEMA vector_schema REFRESH;

SELECT "ID", "TEXT", "SCORE"
FROM vector_schema.YOUR_COLLECTION
WHERE "QUERY" = 'your search phrase here'
LIMIT 10;
```

### Domain examples

| Domain | Source table | ID column | Text column | What you can search |
|---|---|---|---|---|
| **HR policy documents** | `HR.POLICIES` | `policy_id` | `policy_text` | "what is the parental leave policy" |
| **Product descriptions** | `CATALOG.PRODUCTS` | `product_id` | `description` | "lightweight waterproof jacket for hiking" |
| **Research abstracts** | `PAPERS.ABSTRACTS` | `paper_id` | `abstract_text` | "graph neural networks for drug discovery" |
| **Legal contracts** | `LEGAL.CLAUSES` | `clause_id` | `clause_text` | "termination without cause" |

The only columns you need are an **ID** (any unique text or number, used to join back to your data) and a **text field** (the content you want to search over).

---

## What's Next

- [Usage Guide](usage-guide.md) — SQL patterns for filtering, joining, and managing collections
- [UDF Ingestion Guide](udf-ingestion.md) — Load from existing Exasol tables, use OpenAI for embeddings, handle large batches
- [Limitations](limitations.md) — Known constraints (TLS, read-only schema, model consistency)
