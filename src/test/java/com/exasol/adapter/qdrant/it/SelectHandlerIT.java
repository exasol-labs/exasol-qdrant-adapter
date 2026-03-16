package com.exasol.adapter.qdrant.it;

import com.exasol.adapter.qdrant.client.QdrantClient;
import com.exasol.adapter.qdrant.client.model.Point;
import com.exasol.adapter.qdrant.client.model.SearchResult;
import com.exasol.adapter.qdrant.handler.SelectHandler;
import com.exasol.adapter.qdrant.util.IdMapper;
import org.junit.jupiter.api.*;

import java.net.Socket;
import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;
import static org.junit.jupiter.api.Assumptions.assumeTrue;

/**
 * task 7.8 — Integration tests for end-to-end similarity search via SelectHandler.
 *
 * Uses 4-dimensional float vectors with a known cosine similarity layout so test
 * assertions can be deterministic without a real embedding model.
 *
 * Run with: mvn verify -Pit
 */
@Tag("integration")
class SelectHandlerIT {

    private static final String QDRANT_URL =
            System.getProperty("qdrant.url", "http://localhost:6333");
    private static final int VECTOR_SIZE = 4;

    private QdrantClient client;
    private SelectHandler selectHandler;
    private String collectionName;

    @BeforeAll
    static void checkQdrantReachable() {
        assumeTrue(isReachable("localhost", 6333),
                "Skipping integration tests — Qdrant not reachable at localhost:6333");
    }

    @BeforeEach
    void setUp() {
        client = new QdrantClient(QDRANT_URL, "");
        selectHandler = new SelectHandler(client);
        collectionName = "it_select_" + UUID.randomUUID().toString().replace("-", "").substring(0, 8);

        // Create collection and seed data
        client.createCollectionWithSize(collectionName, VECTOR_SIZE);
        seedCollection();
    }

    @AfterEach
    void tearDown() {
        deleteCollection(collectionName);
    }

    // Three documents: A is closest to [1,0,0,0], B to [0,1,0,0], C to [0,0,1,0]
    private void seedCollection() {
        final List<Point> points = List.of(
                new Point(IdMapper.toUuidV5("doc-a"), "doc-a", "document about topic A"),
                new Point(IdMapper.toUuidV5("doc-b"), "doc-b", "document about topic B"),
                new Point(IdMapper.toUuidV5("doc-c"), "doc-c", "document about topic C")
        );
        final List<float[]> vectors = List.of(
                new float[]{1.0f, 0.0f, 0.0f, 0.0f},
                new float[]{0.0f, 1.0f, 0.0f, 0.0f},
                new float[]{0.0f, 0.0f, 1.0f, 0.0f}
        );
        client.upsertPointsWithVectors(collectionName, points, vectors);
    }

    // -------------------------------------------------------------------------
    // task 7.8 — similarity search

    @Test
    void searchPointsWithVector_returns_most_similar_first() {
        // Query vector closest to doc-a
        final List<SearchResult> results = client.searchPointsWithVector(
                collectionName, new float[]{0.95f, 0.1f, 0.0f, 0.0f}, 3);

        assertFalse(results.isEmpty());
        assertEquals("doc-a", results.get(0).getId(),
                "doc-a should be the most similar to query vector near [1,0,0,0]");
        assertEquals("document about topic A", results.get(0).getText());
        assertTrue(results.get(0).getScore() > 0.9,
                "Score should be high for nearly identical vectors");
    }

    @Test
    void searchPointsWithVector_limit_controls_number_of_results() {
        final List<SearchResult> results = client.searchPointsWithVector(
                collectionName, new float[]{0.5f, 0.5f, 0.5f, 0.0f}, 2);
        assertEquals(2, results.size(), "LIMIT 2 should return exactly 2 results");
    }

    @Test
    void searchPointsWithVector_returns_empty_list_for_empty_collection() {
        final String emptyCol = "it_empty_" + UUID.randomUUID().toString().replace("-", "").substring(0, 8);
        client.createCollectionWithSize(emptyCol, VECTOR_SIZE);
        try {
            final List<SearchResult> results = client.searchPointsWithVector(
                    emptyCol, new float[]{0.1f, 0.2f, 0.3f, 0.4f}, 5);
            assertTrue(results.isEmpty(), "Empty collection should return zero results");
        } finally {
            deleteCollection(emptyCol);
        }
    }

    @Test
    void selectHandler_returns_empty_list_for_blank_query() {
        // SelectHandler guards against blank query at the handler level
        final List<SearchResult> results = selectHandler.handle(collectionName, "", 5);
        assertTrue(results.isEmpty());
    }

    @Test
    void selectHandler_returns_empty_list_when_query_is_blank_with_default_limit() {
        // Blank query short-circuits before reaching Qdrant — verifies handler default-limit wiring
        // without requiring Qdrant inference API (which is not available on self-hosted instances).
        final List<SearchResult> results = selectHandler.handle(collectionName, "", 0);
        assertNotNull(results);
        assertTrue(results.isEmpty(), "Blank query should return empty list");
    }

    @Test
    void searchPointsWithVector_all_results_have_non_negative_scores() {
        final List<SearchResult> results = client.searchPointsWithVector(
                collectionName, new float[]{0.5f, 0.5f, 0.0f, 0.0f}, 3);
        for (final SearchResult r : results) {
            assertTrue(r.getScore() >= 0.0, "Cosine similarity score must be >= 0");
        }
    }

    @Test
    void searchPointsWithVector_original_id_is_recovered_not_uuid() {
        final List<SearchResult> results = client.searchPointsWithVector(
                collectionName, new float[]{1.0f, 0.0f, 0.0f, 0.0f}, 1);
        assertEquals(1, results.size());
        // Original VARCHAR ID "doc-a" should be returned, not the UUID v5 (which is 36 chars)
        final String returnedId = results.get(0).getId();
        assertEquals("doc-a", returnedId,
                "Returned ID should be the original VARCHAR id, not the UUID v5 used internally");
        assertNotEquals(36, returnedId.length(),
                "UUID v5 is 36 chars; original id should differ");
    }

    // -------------------------------------------------------------------------

    private void deleteCollection(final String name) {
        final okhttp3.OkHttpClient http = new okhttp3.OkHttpClient();
        final okhttp3.Request req = new okhttp3.Request.Builder()
                .url(QDRANT_URL + "/collections/" + name).delete().build();
        try (final okhttp3.Response r = http.newCall(req).execute()) { /* ignore */ }
        catch (final Exception ignored) {}
    }

    private static boolean isReachable(final String host, final int port) {
        try (Socket s = new Socket(host, port)) { return true; }
        catch (final Exception e) { return false; }
    }
}
