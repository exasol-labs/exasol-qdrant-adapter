## 1. Rewrite the Opening

- [x] 1.1 Replace the generic one-liner intro with a 2–3 sentence user journey narrative (e.g., a data analyst at a company with a support knowledge base who wants users to find answers with plain-language questions, not exact keywords)

## 2. Replace the Sample Dataset

- [x] 2.1 Remove the 5 generic sample sentences from Step 5b
- [x] 2.2 Write 12 realistic support knowledge base articles covering 4 topic clusters: account/authentication (3 docs), billing (3 docs), connectivity/technical (3 docs), product features (3 docs)
- [x] 2.3 Update the collection name from `quickstart` to `support_kb` throughout the guide (Steps 5a, 5b, 5c, and all query examples)

## 3. Expand the Query Examples

- [x] 3.1 Replace the single "first query" example with 3 distinct queries:
  - Query 1: a direct question matching a document closely (with expected high score ≥ 0.85)
  - Query 2: a paraphrase query (no shared keywords with the top result) showing semantic matching
  - Query 3: a vague/incomplete intent query showing graceful degradation
- [x] 3.2 Add a one-sentence annotation after each query result table explaining why semantic search returned what it did

## 4. Add "Adapt This to Your Data" Section

- [x] 4.1 Add a new section immediately after the query examples titled "Adapting This to Your Own Data"
- [x] 4.2 Write a parameterised SQL template showing EMBED_AND_PUSH with placeholder variables (`YOUR_COLLECTION`, `YOUR_SCHEMA.YOUR_TABLE`, `YOUR_ID_COLUMN`, `YOUR_TEXT_COLUMN`)
- [x] 4.3 Add a short list of 3–4 alternative domains (HR policy documents, product descriptions, research abstracts, legal contracts) with one-line descriptions of the search use case for each

## 5. Add Real-World Join Pattern

- [x] 5.1 Add a new subsection in the query examples area titled "Combining Search Results with Your Exasol Data"
- [x] 5.2 Write a complete JOIN example: semantic search against `vector_schema.support_kb` joined to a fictional `SUPPORT.TICKETS` table on `ID`, ordered by `SCORE DESC`, selecting ticket metadata columns alongside the search result
