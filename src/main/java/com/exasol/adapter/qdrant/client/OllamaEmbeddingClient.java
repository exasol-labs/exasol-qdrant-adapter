package com.exasol.adapter.qdrant.client;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import okhttp3.*;

import java.io.IOException;

/**
 * Calls Ollama's local embedding API to convert text into float vectors.
 *
 * API: POST /api/embeddings
 * Body: {"model":"<modelName>","prompt":"<text>"}
 * Response: {"embedding":[0.1, 0.2, ...]}
 *
 * Default model: nomic-embed-text (768-dimensional)
 * Default URL: http://localhost:11434
 */
public class OllamaEmbeddingClient {

    private static final MediaType JSON = MediaType.get("application/json");
    private static final ObjectMapper MAPPER = new ObjectMapper();

    private final String baseUrl;
    private final String modelName;
    private final OkHttpClient http;

    public OllamaEmbeddingClient(final String baseUrl, final String modelName) {
        this.baseUrl = baseUrl.endsWith("/") ? baseUrl.substring(0, baseUrl.length() - 1) : baseUrl;
        this.modelName = modelName;
        this.http = new OkHttpClient();
    }

    /**
     * Embeds the given text using Ollama and returns the float vector.
     *
     * @param text input text to embed
     * @return float array representing the embedding vector
     * @throws OllamaException if Ollama returns an error or is unreachable
     */
    public float[] embed(final String text) {
        final String bodyJson;
        try {
            bodyJson = MAPPER.writeValueAsString(
                    new java.util.LinkedHashMap<String, String>() {{
                        put("model", modelName);
                        put("prompt", text);
                    }});
        } catch (final IOException e) {
            throw new OllamaException("Failed to serialise embedding request: " + e.getMessage(), e);
        }

        final Request request = new Request.Builder()
                .url(baseUrl + "/api/embeddings")
                .post(RequestBody.create(bodyJson, JSON))
                .build();

        try (final Response response = http.newCall(request).execute()) {
            final String responseBody = response.body() != null ? response.body().string() : "";
            if (!response.isSuccessful()) {
                throw new OllamaException("Ollama returned HTTP " + response.code()
                        + " for model '" + modelName + "': " + responseBody);
            }
            final JsonNode root = MAPPER.readTree(responseBody);
            final JsonNode embeddingNode = root.get("embedding");
            if (embeddingNode == null || !embeddingNode.isArray()) {
                throw new OllamaException("Ollama response missing 'embedding' array: " + responseBody);
            }
            final float[] vector = new float[embeddingNode.size()];
            for (int i = 0; i < vector.length; i++) {
                vector[i] = (float) embeddingNode.get(i).asDouble();
            }
            return vector;
        } catch (final OllamaException e) {
            throw e;
        } catch (final IOException e) {
            throw new OllamaException("Failed to reach Ollama at " + baseUrl + ": " + e.getMessage(), e);
        }
    }

    // -------------------------------------------------------------------------

    /** Thrown when the Ollama embedding service returns an error or is unreachable. */
    public static class OllamaException extends RuntimeException {
        public OllamaException(final String message) {
            super(message);
        }
        public OllamaException(final String message, final Throwable cause) {
            super(message, cause);
        }
    }
}
