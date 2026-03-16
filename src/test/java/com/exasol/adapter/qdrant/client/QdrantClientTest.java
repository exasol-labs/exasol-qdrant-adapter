package com.exasol.adapter.qdrant.client;

import com.exasol.adapter.qdrant.client.model.Point;
import com.exasol.adapter.qdrant.client.model.SearchResult;
import okhttp3.mockwebserver.MockResponse;
import okhttp3.mockwebserver.MockWebServer;
import okhttp3.mockwebserver.RecordedRequest;
import org.junit.jupiter.api.*;

import java.io.IOException;
import java.util.List;

import static org.junit.jupiter.api.Assertions.*;

/**
 * task 3.7 — Unit tests for QdrantClient using OkHttp MockWebServer.
 */
class QdrantClientTest {

    private MockWebServer server;
    private QdrantClient client;

    @BeforeEach
    void setUp() throws IOException {
        server = new MockWebServer();
        server.start();
        client = new QdrantClient(server.url("/").toString().replaceAll("/$", ""), "test-api-key");
    }

    @AfterEach
    void tearDown() throws IOException {
        server.shutdown();
    }

    // -------------------------------------------------------------------------
    // collectionExists

    @Test
    void collectionExists_returns_true_when_server_returns_200() {
        server.enqueue(new MockResponse().setResponseCode(200).setBody("{}"));
        assertTrue(client.collectionExists("my_collection"));
    }

    @Test
    void collectionExists_returns_false_when_server_returns_404() {
        server.enqueue(new MockResponse().setResponseCode(404).setBody("{\"status\":{\"error\":\"Not found\"}}"));
        assertFalse(client.collectionExists("missing"));
    }

    @Test
    void collectionExists_sends_GET_to_correct_path() throws InterruptedException {
        server.enqueue(new MockResponse().setResponseCode(200));
        client.collectionExists("test_col");
        final RecordedRequest req = server.takeRequest();
        assertEquals("GET", req.getMethod());
        assertTrue(req.getPath().contains("/collections/test_col"));
    }

    @Test
    void collectionExists_includes_api_key_header() throws InterruptedException {
        server.enqueue(new MockResponse().setResponseCode(200));
        client.collectionExists("col");
        final RecordedRequest req = server.takeRequest();
        assertEquals("test-api-key", req.getHeader("api-key"));
    }

    // -------------------------------------------------------------------------
    // createCollection

    @Test
    void createCollection_sends_PUT_with_size_and_cosine_distance() throws InterruptedException {
        server.enqueue(new MockResponse().setResponseCode(200).setBody("{\"result\":true,\"status\":\"ok\"}"));
        client.createCollection("articles", "sentence-transformers/all-MiniLM-L6-v2", 384);
        final RecordedRequest req = server.takeRequest();
        assertEquals("PUT", req.getMethod());
        assertTrue(req.getPath().contains("/collections/articles"));
        final String body = req.getBody().readUtf8();
        assertTrue(body.contains("384"), "Body should contain vector size 384");
        assertTrue(body.contains("Cosine"), "Body should specify Cosine distance");
    }

    @Test
    void createCollection_throws_QdrantException_on_400() {
        server.enqueue(new MockResponse().setResponseCode(400)
                .setBody("{\"status\":{\"error\":\"already exists\"}}"));
        final QdrantException ex = assertThrows(QdrantException.class,
                () -> client.createCollection("dup", "model", 384));
        assertEquals(400, ex.getHttpStatus());
    }

    // -------------------------------------------------------------------------
    // upsertPoints / batching

    @Test
    void upsertPoints_sends_single_PUT_for_small_batch() throws InterruptedException {
        server.enqueue(new MockResponse().setResponseCode(200).setBody("{\"result\":{\"operation_id\":1,\"status\":\"completed\"}}"));
        final List<Point> points = List.of(
                new Point("uuid-1", "orig-1", "hello world"),
                new Point("uuid-2", "orig-2", "foo bar")
        );
        client.upsertPoints("col", points);
        assertEquals(1, server.getRequestCount());
        final RecordedRequest req = server.takeRequest();
        assertEquals("PUT", req.getMethod());
        assertTrue(req.getPath().contains("/collections/col/points"));
    }

    @Test
    void upsertPoints_payload_contains_original_id_and_text() throws InterruptedException {
        server.enqueue(new MockResponse().setResponseCode(200).setBody("{}"));
        client.upsertPoints("col", List.of(new Point("uuid-a", "my-orig-id", "sample text")));
        final String body = server.takeRequest().getBody().readUtf8();
        assertTrue(body.contains("_original_id"));
        assertTrue(body.contains("my-orig-id"));
        assertTrue(body.contains("sample text"));
    }

    @Test
    void upsertPoints_batches_101_points_into_two_requests() {
        // Enqueue two success responses (one per batch)
        server.enqueue(new MockResponse().setResponseCode(200).setBody("{}"));
        server.enqueue(new MockResponse().setResponseCode(200).setBody("{}"));

        final List<Point> points = new java.util.ArrayList<>();
        for (int i = 0; i < 101; i++) {
            points.add(new Point("uuid-" + i, "id-" + i, "text " + i));
        }
        client.upsertPoints("col", points);
        assertEquals(2, server.getRequestCount());
    }

    // -------------------------------------------------------------------------
    // searchPoints

    @Test
    void searchPoints_sends_POST_to_query_endpoint() throws InterruptedException {
        server.enqueue(new MockResponse().setResponseCode(200)
                .setBody("{\"result\":{\"points\":[{\"id\":\"uuid\",\"score\":0.92," +
                        "\"payload\":{\"_original_id\":\"orig\",\"text\":\"hello\"}}]}}"));
        client.searchPoints("col", "query text", 5);
        final RecordedRequest req = server.takeRequest();
        assertEquals("POST", req.getMethod());
        assertTrue(req.getPath().contains("/collections/col/points/query"));
    }

    @Test
    void searchPoints_returns_parsed_results() {
        server.enqueue(new MockResponse().setResponseCode(200)
                .setBody("{\"result\":{\"points\":[" +
                        "{\"id\":\"u1\",\"score\":0.85,\"payload\":{\"_original_id\":\"id-1\",\"text\":\"some text\"}}," +
                        "{\"id\":\"u2\",\"score\":0.72,\"payload\":{\"_original_id\":\"id-2\",\"text\":\"other text\"}}" +
                        "]}}"));
        final List<SearchResult> results = client.searchPoints("col", "query", 10);
        assertEquals(2, results.size());
        assertEquals("id-1", results.get(0).getId());
        assertEquals("some text", results.get(0).getText());
        assertEquals(0.85, results.get(0).getScore(), 0.001);
    }

    @Test
    void searchPoints_returns_empty_list_when_no_results() {
        server.enqueue(new MockResponse().setResponseCode(200)
                .setBody("{\"result\":{\"points\":[]}}"));
        final List<SearchResult> results = client.searchPoints("col", "query", 10);
        assertTrue(results.isEmpty());
    }

    @Test
    void searchPoints_throws_on_non_200_response() {
        server.enqueue(new MockResponse().setResponseCode(500).setBody("{\"error\":\"Internal\"}"));
        assertThrows(QdrantException.class, () -> client.searchPoints("col", "q", 5));
    }
}
