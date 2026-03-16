package com.exasol.adapter.qdrant.handler;

import com.exasol.adapter.qdrant.client.OllamaEmbeddingClient;
import com.exasol.adapter.qdrant.client.QdrantClient;
import com.exasol.adapter.qdrant.client.model.SearchResult;

import java.util.Collections;
import java.util.List;

/**
 * tasks 7.1–7.6 — Handles SELECT similarity-search queries against a Qdrant collection.
 *
 * When an {@link OllamaEmbeddingClient} is provided the query text is first converted to
 * a float vector via Ollama, then the explicit-vector search path is used. Without an
 * Ollama client the adapter falls back to Qdrant's server-side inference path (requires
 * a Qdrant Cloud deployment with an inference model configured).
 */
public class SelectHandler {

    private static final int DEFAULT_LIMIT = 10;

    private final QdrantClient qdrantClient;
    private final OllamaEmbeddingClient ollamaClient;

    /** Constructor with Ollama embedding support (recommended for local Qdrant). */
    public SelectHandler(final QdrantClient qdrantClient, final OllamaEmbeddingClient ollamaClient) {
        this.qdrantClient = qdrantClient;
        this.ollamaClient = ollamaClient;
    }

    /** Fallback constructor — uses Qdrant server-side inference (no local embedding). */
    public SelectHandler(final QdrantClient qdrantClient) {
        this(qdrantClient, null);
    }

    /**
     * Executes a similarity search for the given query text.
     *
     * @param collectionName target Qdrant collection
     * @param queryText      raw query string
     * @param limit          max results (top-k); 0 or negative → DEFAULT_LIMIT
     * @return results ordered by descending similarity score
     */
    public List<SearchResult> handle(final String collectionName,
                                     final String queryText,
                                     final int limit) {
        if (queryText == null || queryText.isBlank()) {
            return Collections.emptyList();
        }

        final int effectiveLimit = (limit > 0) ? limit : DEFAULT_LIMIT;

        if (ollamaClient != null) {
            final float[] vector = ollamaClient.embed(queryText);
            return qdrantClient.searchPointsWithVector(collectionName, vector, effectiveLimit);
        }

        // fallback: server-side inference path
        return qdrantClient.searchPoints(collectionName, queryText, effectiveLimit);
    }
}
