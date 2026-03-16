package com.exasol.adapter.qdrant.client;

import com.exasol.adapter.qdrant.client.model.Point;
import com.exasol.adapter.qdrant.client.model.SearchResult;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ArrayNode;
import com.fasterxml.jackson.databind.node.ObjectNode;
import okhttp3.*;

import java.io.IOException;
import java.util.ArrayList;
import java.util.List;

/**
 * tasks 3.1–3.6 — Qdrant REST API client.
 *
 * Translates adapter operations into Qdrant HTTP calls using OkHttp.
 * All methods throw {@link QdrantException} on API-level errors.
 */
public class QdrantClient {

    private static final MediaType JSON = MediaType.get("application/json; charset=utf-8");
    private static final int UPSERT_BATCH_SIZE = 100; // task 3.3 — batch limit

    private final String baseUrl;
    private final OkHttpClient httpClient;
    private final ObjectMapper mapper;

    // task 3.1 — constructor with auth headers baked in via an interceptor
    public QdrantClient(final String baseUrl, final String apiKey) {
        this.baseUrl = baseUrl;
        this.mapper = new ObjectMapper();

        final OkHttpClient.Builder builder = new OkHttpClient.Builder();
        if (apiKey != null && !apiKey.isBlank()) {
            builder.addInterceptor(chain -> {
                final Request original = chain.request();
                final Request authenticated = original.newBuilder()
                        .header("api-key", apiKey)
                        .build();
                return chain.proceed(authenticated);
            });
        }
        this.httpClient = builder.build();
    }

    // -------------------------------------------------------------------------
    // list all collections

    /**
     * Returns the names of all collections in Qdrant.
     * GET /collections → { "result": { "collections": [ { "name": "..." }, ... ] } }
     */
    public List<String> listCollections() {
        final Request request = new Request.Builder()
                .url(baseUrl + "/collections")
                .get()
                .build();
        try (Response response = httpClient.newCall(request).execute()) {
            final String body = safeBodyString(response);
            if (!response.isSuccessful()) throw new QdrantException(response.code(), body);
            final List<String> names = new ArrayList<>();
            final JsonNode collections = mapper.readTree(body).path("result").path("collections");
            if (collections.isArray()) {
                for (final JsonNode col : collections) {
                    final String name = col.path("name").asText(null);
                    if (name != null) names.add(name);
                }
            }
            return names;
        } catch (final IOException e) {
            throw new QdrantException("Failed to list collections: " + e.getMessage(), e);
        }
    }

    // -------------------------------------------------------------------------
    // task 3.5 — collection existence check
    // (also used by CreateCollectionHandler for duplicate detection)

    /**
     * Returns {@code true} if a collection with the given name already exists in Qdrant.
     */
    public boolean collectionExists(final String collectionName) {
        final Request request = new Request.Builder()
                .url(baseUrl + "/collections/" + collectionName)
                .get()
                .build();
        try (Response response = httpClient.newCall(request).execute()) {
            return response.code() == 200;
        } catch (final IOException e) {
            throw new QdrantException("Failed to check collection existence: " + e.getMessage(), e);
        }
    }

    // -------------------------------------------------------------------------
    // task 3.2 — create collection

    /**
     * Creates a Qdrant collection with a fixed dense vector size (cosine distance).
     *
     * Used for local/self-hosted Qdrant where the server does not compute embeddings.
     * The caller is responsible for providing pre-computed float vectors when upserting.
     *
     * @param collectionName name of the collection to create
     * @param vectorSize     dimensionality of the dense vector (must match the embedding model output)
     */
    public void createCollectionWithSize(final String collectionName, final int vectorSize) {
        final ObjectNode body = mapper.createObjectNode();
        final ObjectNode vectors = mapper.createObjectNode();
        final ObjectNode textVector = mapper.createObjectNode();
        textVector.put("size", vectorSize);
        textVector.put("distance", "Cosine");
        vectors.set("text", textVector);
        body.set("vectors", vectors);

        final String json = toJson(body);
        final Request request = new Request.Builder()
                .url(baseUrl + "/collections/" + collectionName)
                .put(RequestBody.create(json, JSON))
                .build();
        executeAndCheck(request,
                "Failed to create collection '" + collectionName + "'",
                "Collection '" + collectionName + "' already exists in Qdrant.");
    }

    /**
     * Creates a Qdrant collection configured with a named dense vector and a model hint
     * stored as collection metadata. Actual embedding must be computed client-side or
     * via a Qdrant-compatible inference endpoint before upsert.
     *
     * NOTE: The {@code model_config} field is only supported on Qdrant Cloud. For
     * self-hosted Qdrant use {@link #createCollectionWithSize} instead.
     *
     * @param collectionName name of the collection
     * @param modelName      inference model identifier stored as collection metadata
     * @param vectorSize     dense vector dimensionality matching the model's output
     */
    public void createCollection(final String collectionName,
                                 final String modelName,
                                 final int vectorSize) {
        // Store model name in collection metadata for documentation / tooling;
        // actual vector size drives Qdrant's storage.
        final ObjectNode body = mapper.createObjectNode();
        final ObjectNode vectors = mapper.createObjectNode();
        final ObjectNode textVector = mapper.createObjectNode();
        textVector.put("size", vectorSize);
        textVector.put("distance", "Cosine");
        vectors.set("text", textVector);
        body.set("vectors", vectors);

        // Store model name in on-disk payload metadata comment (best-effort)
        final ObjectNode metadata = mapper.createObjectNode();
        metadata.put("inference_model", modelName);
        body.set("on_disk_payload", mapper.valueToTree(false));

        final String json = toJson(body);
        final Request request = new Request.Builder()
                .url(baseUrl + "/collections/" + collectionName)
                .put(RequestBody.create(json, JSON))
                .build();
        executeAndCheck(request,
                "Failed to create collection '" + collectionName + "'",
                "Collection '" + collectionName + "' already exists in Qdrant.");
    }

    // -------------------------------------------------------------------------
    // task 3.3 — upsert points in batches

    /**
     * Upserts points with pre-computed float vectors.
     * Used when embedding is computed client-side (local Qdrant without inference API).
     *
     * @param collectionName target collection
     * @param points         list of points; each point's {@code text} field is stored as payload only
     * @param vectors        parallel list of float arrays (one per point)
     */
    public void upsertPointsWithVectors(final String collectionName,
                                        final List<Point> points,
                                        final List<float[]> vectors) {
        if (points.size() != vectors.size()) {
            throw new IllegalArgumentException("points and vectors lists must be the same length");
        }
        for (int offset = 0; offset < points.size(); offset += UPSERT_BATCH_SIZE) {
            final int end = Math.min(offset + UPSERT_BATCH_SIZE, points.size());
            upsertBatchWithVectors(collectionName, points.subList(offset, end), vectors.subList(offset, end));
        }
    }

    private void upsertBatchWithVectors(final String collectionName,
                                        final List<Point> batch,
                                        final List<float[]> batchVectors) {
        final ObjectNode body = mapper.createObjectNode();
        final ArrayNode pointsArray = mapper.createArrayNode();
        for (int i = 0; i < batch.size(); i++) {
            final Point point = batch.get(i);
            final float[] vector = batchVectors.get(i);
            final ObjectNode pointNode = mapper.createObjectNode();
            pointNode.put("id", point.getId());
            final ObjectNode payload = mapper.createObjectNode();
            payload.put("_original_id", point.getOriginalId());
            payload.put("text", point.getText());
            pointNode.set("payload", payload);
            final ObjectNode vectors = mapper.createObjectNode();
            final ArrayNode vectorArray = mapper.createArrayNode();
            for (final float v : vector) vectorArray.add(v);
            vectors.set("text", vectorArray);
            pointNode.set("vectors", vectors);
            pointsArray.add(pointNode);
        }
        body.set("points", pointsArray);
        final Request request = new Request.Builder()
                .url(baseUrl + "/collections/" + collectionName + "/points")
                .put(RequestBody.create(toJson(body), JSON))
                .build();
        executeAndCheck(request, "Failed to upsert points into '" + collectionName + "'", null);
    }

    /**
     * Searches using a pre-computed float query vector.
     * Used when embedding is computed client-side (local Qdrant without inference API).
     */
    public List<SearchResult> searchPointsWithVector(final String collectionName,
                                                     final float[] queryVector,
                                                     final int limit) {
        final ObjectNode body = mapper.createObjectNode();
        final ObjectNode query = mapper.createObjectNode();
        final ArrayNode vectorArray = mapper.createArrayNode();
        for (final float v : queryVector) vectorArray.add(v);
        query.set("nearest", vectorArray);
        body.set("query", query);
        body.put("using", "text");
        body.put("limit", limit);
        body.put("with_payload", true);

        final Request request = new Request.Builder()
                .url(baseUrl + "/collections/" + collectionName + "/points/query")
                .post(RequestBody.create(toJson(body), JSON))
                .build();
        try (Response response = httpClient.newCall(request).execute()) {
            final String responseBody = safeBodyString(response);
            if (!response.isSuccessful()) throw new QdrantException(response.code(), responseBody);
            return parseSearchResults(responseBody);
        } catch (final IOException e) {
            throw new QdrantException("Network error during vector search: " + e.getMessage(), e);
        }
    }

    /**
     * Upserts a list of points into the given collection.
     * Batches are capped at {@value UPSERT_BATCH_SIZE} per API call.
     *
     * Each point is sent as:
     * {
     *   "id": "<uuid>",
     *   "payload": { "_original_id": "...", "text": "..." },
     *   "vectors": { "text": "<raw text for inference>" }
     * }
     */
    public void upsertPoints(final String collectionName, final List<Point> points) {
        // split into batches of UPSERT_BATCH_SIZE
        for (int offset = 0; offset < points.size(); offset += UPSERT_BATCH_SIZE) {
            final List<Point> batch = points.subList(offset,
                    Math.min(offset + UPSERT_BATCH_SIZE, points.size()));
            upsertBatch(collectionName, batch);
        }
    }

    private void upsertBatch(final String collectionName, final List<Point> batch) {
        final ObjectNode body = mapper.createObjectNode();
        final ArrayNode pointsArray = mapper.createArrayNode();

        for (final Point point : batch) {
            final ObjectNode pointNode = mapper.createObjectNode();
            pointNode.put("id", point.getId());

            // payload: task 4.2 — store original id + text
            final ObjectNode payload = mapper.createObjectNode();
            payload.put("_original_id", point.getOriginalId());
            payload.put("text", point.getText());
            pointNode.set("payload", payload);

            // vectors: pass raw text to Qdrant inference API
            final ObjectNode vectors = mapper.createObjectNode();
            vectors.put("text", point.getText());
            pointNode.set("vectors", vectors);

            pointsArray.add(pointNode);
        }

        body.set("points", pointsArray);
        final String json = toJson(body);

        final Request request = new Request.Builder()
                .url(baseUrl + "/collections/" + collectionName + "/points")
                .put(RequestBody.create(json, JSON))
                .build();

        executeAndCheck(request,
                "Failed to upsert points into collection '" + collectionName + "'",
                null);
    }

    // -------------------------------------------------------------------------
    // task 3.4 — similarity search using Qdrant inference

    /**
     * Performs a similarity search using Qdrant's inference API.
     * The raw query text is forwarded to Qdrant; Qdrant computes the embedding internally.
     *
     * POST /collections/{name}/points/query
     * {
     *   "query": { "nearest": { "text": "<queryText>" } },
     *   "using": "text",
     *   "limit": <limit>,
     *   "with_payload": true
     * }
     */
    public List<SearchResult> searchPoints(final String collectionName,
                                           final String queryText,
                                           final int limit) {
        final ObjectNode body = mapper.createObjectNode();

        // inference query: pass raw text, Qdrant embeds it
        final ObjectNode query = mapper.createObjectNode();
        final ObjectNode nearest = mapper.createObjectNode();
        nearest.put("text", queryText);
        query.set("nearest", nearest);
        body.set("query", query);
        body.put("using", "text");
        body.put("limit", limit);
        body.put("with_payload", true);

        final String json = toJson(body);
        final Request request = new Request.Builder()
                .url(baseUrl + "/collections/" + collectionName + "/points/query")
                .post(RequestBody.create(json, JSON))
                .build();

        try (Response response = httpClient.newCall(request).execute()) {
            final String responseBody = safeBodyString(response);
            if (!response.isSuccessful()) {
                throw new QdrantException(response.code(), responseBody);
            }
            return parseSearchResults(responseBody);
        } catch (final IOException e) {
            throw new QdrantException("Network error during search in '" + collectionName + "': " + e.getMessage(), e);
        }
    }

    // -------------------------------------------------------------------------
    // task 3.6 — error handling helpers

    private void executeAndCheck(final Request request,
                                 final String networkErrorMessage,
                                 final String alreadyExistsMessage) {
        try (Response response = httpClient.newCall(request).execute()) {
            final String body = safeBodyString(response);
            if (!response.isSuccessful()) {
                if (alreadyExistsMessage != null && response.code() == 400
                        && body.toLowerCase().contains("already exists")) {
                    throw new QdrantException(response.code(), alreadyExistsMessage);
                }
                throw new QdrantException(response.code(), body);
            }
        } catch (final IOException e) {
            throw new QdrantException(networkErrorMessage + ": " + e.getMessage(), e);
        }
    }

    private String safeBodyString(final Response response) throws IOException {
        final ResponseBody body = response.body();
        return body != null ? body.string() : "";
    }

    private List<SearchResult> parseSearchResults(final String responseBody) {
        final List<SearchResult> results = new ArrayList<>();
        try {
            final JsonNode root = mapper.readTree(responseBody);
            // Qdrant /points/query response: { "result": { "points": [...] } }
            final JsonNode points = root.path("result").path("points");
            if (points.isMissingNode() || !points.isArray()) {
                return results;
            }
            for (final JsonNode point : points) {
                final double score = point.path("score").asDouble(0.0);
                final JsonNode payload = point.path("payload");
                final String originalId = payload.path("_original_id").asText("");
                final String text = payload.path("text").asText("");
                results.add(new SearchResult(originalId, text, score));
            }
        } catch (final IOException e) {
            throw new QdrantException("Failed to parse Qdrant search response: " + e.getMessage(), e);
        }
        return results;
    }

    private String toJson(final ObjectNode node) {
        try {
            return mapper.writeValueAsString(node);
        } catch (final IOException e) {
            throw new QdrantException("Failed to serialise request body: " + e.getMessage(), e);
        }
    }
}
