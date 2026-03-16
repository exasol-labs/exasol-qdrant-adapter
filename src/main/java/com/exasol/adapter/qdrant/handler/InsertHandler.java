package com.exasol.adapter.qdrant.handler;

import com.exasol.adapter.qdrant.client.OllamaEmbeddingClient;
import com.exasol.adapter.qdrant.client.QdrantClient;
import com.exasol.adapter.qdrant.client.QdrantException;
import com.exasol.adapter.qdrant.client.model.Point;
import com.exasol.adapter.qdrant.util.IdMapper;

import java.util.ArrayList;
import java.util.List;

/**
 * tasks 6.1–6.4 — Handles INSERT INTO operations by upserting text rows into Qdrant.
 *
 * When an {@link OllamaEmbeddingClient} is provided the text is embedded locally via
 * Ollama before being sent to Qdrant (explicit float-vector upsert). Without an Ollama
 * client the adapter falls back to Qdrant's server-side inference path.
 */
public class InsertHandler {

    private final QdrantClient qdrantClient;
    private final OllamaEmbeddingClient ollamaClient;

    /** Constructor with Ollama embedding support (recommended for local Qdrant). */
    public InsertHandler(final QdrantClient qdrantClient, final OllamaEmbeddingClient ollamaClient) {
        this.qdrantClient = qdrantClient;
        this.ollamaClient = ollamaClient;
    }

    /** Fallback constructor — uses Qdrant server-side inference (no local embedding). */
    public InsertHandler(final QdrantClient qdrantClient) {
        this(qdrantClient, null);
    }

    /**
     * Accepts a list of (id, text) row pairs and upserts them.
     *
     * @param collectionName target Qdrant collection
     * @param rows           list of rows; each element is a String[2] = {id, text}
     * @throws QdrantException if Qdrant returns an error (task 6.4)
     */
    public void handle(final String collectionName, final List<String[]> rows) {
        if (rows == null || rows.isEmpty()) {
            return;
        }

        final List<Point> points = new ArrayList<>(rows.size());
        final List<float[]> vectors = ollamaClient != null ? new ArrayList<>(rows.size()) : null;

        for (final String[] row : rows) {
            if (row.length < 2) {
                throw new IllegalArgumentException(
                        "Each INSERT row must have exactly 2 columns: [id, text]");
            }
            final String originalId = row[0];
            final String text       = row[1];
            final String uuid       = IdMapper.toUuidV5(originalId);
            points.add(new Point(uuid, originalId, text));

            if (vectors != null) {
                vectors.add(ollamaClient.embed(text));
            }
        }

        if (vectors != null) {
            qdrantClient.upsertPointsWithVectors(collectionName, points, vectors);
        } else {
            qdrantClient.upsertPoints(collectionName, points);
        }
    }
}
