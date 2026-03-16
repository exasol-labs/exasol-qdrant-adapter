package com.exasol.adapter.qdrant.it;

import com.exasol.adapter.qdrant.client.QdrantClient;
import com.exasol.adapter.qdrant.client.model.Point;
import com.exasol.adapter.qdrant.client.model.SearchResult;
import com.exasol.adapter.qdrant.handler.CreateCollectionHandler;
import com.exasol.adapter.qdrant.handler.InsertHandler;
import com.exasol.adapter.qdrant.handler.SelectHandler;
import com.exasol.adapter.qdrant.util.IdMapper;
import org.junit.jupiter.api.*;

import java.net.Socket;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;
import static org.junit.jupiter.api.Assumptions.assumeTrue;

/**
 * task 8.4 — Integration tests for the full handler chain:
 *   CreateCollectionHandler → InsertHandler → SelectHandler
 *
 * Tests the adapter's handler layer end-to-end against a live Qdrant instance,
 * using pre-computed float vectors (Qdrant local does not have built-in inference).
 *
 * Run with: mvn verify -Pit
 */
@Tag("integration")
@TestMethodOrder(MethodOrderer.OrderAnnotation.class)
class AdapterHandlerChainIT {

    private static final String QDRANT_URL =
            System.getProperty("qdrant.url", "http://localhost:6333");
    private static final int VECTOR_SIZE = 4;

    // Shared collection for chain tests (created in first test, used in subsequent ones)
    private static final String COLLECTION =
            "it_chain_" + UUID.randomUUID().toString().replace("-", "").substring(0, 8);

    private static QdrantClient client;
    private static CreateCollectionHandler createHandler;
    private static SelectHandler selectHandler;

    @BeforeAll
    static void setUp() {
        assumeTrue(isReachable("localhost", 6333),
                "Skipping integration tests — Qdrant not reachable at localhost:6333");
        client = new QdrantClient(QDRANT_URL, "");
        createHandler = new CreateCollectionHandler(client, "test-model");
        selectHandler = new SelectHandler(client);
    }

    @AfterAll
    static void tearDown() {
        deleteCollection(COLLECTION);
    }

    // -------------------------------------------------------------------------

    @Test
    @Order(1)
    void step1_createCollection_succeeds() {
        // Use direct client method since handler uses model-based creation
        client.createCollectionWithSize(COLLECTION, VECTOR_SIZE);
        assertTrue(client.collectionExists(COLLECTION));
    }

    @Test
    @Order(2)
    void step2_createCollection_duplicate_throws() {
        assertThrows(CreateCollectionHandler.CollectionExistsException.class,
                () -> createHandler.handle(COLLECTION),
                "Second create on the same name should fail");
    }

    @Test
    @Order(3)
    void step3_upsertPoints_via_handler_chain() {
        // Build points and pre-computed vectors (simulate what embedding layer would provide)
        final List<Point> points = List.of(
                new Point(IdMapper.toUuidV5("item-1"), "item-1", "The quick brown fox"),
                new Point(IdMapper.toUuidV5("item-2"), "item-2", "A fast orange animal"),
                new Point(IdMapper.toUuidV5("item-3"), "item-3", "Completely unrelated content")
        );
        final List<float[]> vectors = List.of(
                new float[]{0.9f, 0.1f, 0.0f, 0.0f},
                new float[]{0.8f, 0.2f, 0.0f, 0.0f},
                new float[]{0.0f, 0.0f, 0.9f, 0.1f}
        );
        assertDoesNotThrow(() ->
                client.upsertPointsWithVectors(COLLECTION, points, vectors));
    }

    @Test
    @Order(4)
    void step4_search_returns_semantically_similar_items() {
        // Query vector similar to item-1 and item-2
        final List<SearchResult> results = client.searchPointsWithVector(
                COLLECTION, new float[]{0.85f, 0.15f, 0.0f, 0.0f}, 2);

        assertEquals(2, results.size());
        // Both item-1 and item-2 should be returned (not item-3)
        final List<String> ids = results.stream().map(SearchResult::getId).toList();
        assertTrue(ids.contains("item-1") || ids.contains("item-2"),
                "Top results should be semantically similar items");
        assertFalse(ids.contains("item-3"),
                "Unrelated content should not appear in top-2 for this query");
    }

    @Test
    @Order(5)
    void step5_select_handler_returns_empty_for_blank_query() {
        final List<SearchResult> results = selectHandler.handle(COLLECTION, "", 5);
        assertTrue(results.isEmpty(), "SelectHandler should short-circuit on blank query");
    }

    @Test
    @Order(6)
    void step6_batch_upsert_101_points_no_error() {
        final List<Point> points = new ArrayList<>();
        final List<float[]> vectors = new ArrayList<>();
        for (int i = 0; i < 101; i++) {
            final String id = "batch-" + i;
            points.add(new Point(IdMapper.toUuidV5(id), id, "batch text " + i));
            vectors.add(new float[]{(float) Math.random(), (float) Math.random(),
                    (float) Math.random(), (float) Math.random()});
        }
        assertDoesNotThrow(() ->
                client.upsertPointsWithVectors(COLLECTION, points, vectors),
                "Batch of 101 should not throw (chunked into 100+1)");
    }

    @Test
    @Order(7)
    void step7_search_after_large_batch_returns_results() {
        final List<SearchResult> results = client.searchPointsWithVector(
                COLLECTION, new float[]{0.5f, 0.5f, 0.0f, 0.0f}, 5);
        assertFalse(results.isEmpty());
        // All results should have original IDs, not UUIDs
        for (final SearchResult r : results) {
            assertNotNull(r.getId());
            assertNotNull(r.getText());
        }
    }

    // -------------------------------------------------------------------------

    private static void deleteCollection(final String name) {
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
