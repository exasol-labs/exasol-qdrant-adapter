package com.exasol.adapter.qdrant.handler;

import com.exasol.adapter.qdrant.client.QdrantClient;
import com.exasol.adapter.qdrant.client.model.Point;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.ArgumentCaptor;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

import java.util.ArrayList;
import java.util.List;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

/**
 * tasks 6.5 — Unit tests for InsertHandler batch chunking and row mapping.
 */
@ExtendWith(MockitoExtension.class)
class InsertHandlerTest {

    @Mock
    private QdrantClient qdrantClient;

    // -------------------------------------------------------------------------
    // basic routing

    @Test
    void handle_calls_upsertPoints_once_for_small_batch() {
        final InsertHandler handler = new InsertHandler(qdrantClient);
        final List<String[]> rows = List.of(
                new String[]{"id-1", "text one"},
                new String[]{"id-2", "text two"}
        );
        handler.handle("my_collection", rows);
        verify(qdrantClient, times(1)).upsertPoints(eq("my_collection"), anyList());
    }

    @Test
    void handle_maps_original_id_into_point() {
        final InsertHandler handler = new InsertHandler(qdrantClient);
        final ArgumentCaptor<List<Point>> captor = ArgumentCaptor.forClass(List.class);

        handler.handle("col", List.<String[]>of(new String[]{"my-orig-id", "hello"}));

        verify(qdrantClient).upsertPoints(eq("col"), captor.capture());
        final Point point = captor.getValue().get(0);
        assertEquals("my-orig-id", point.getOriginalId());
        assertEquals("hello", point.getText());
    }

    @Test
    void handle_uuid_is_not_same_as_original_id() {
        final InsertHandler handler = new InsertHandler(qdrantClient);
        final ArgumentCaptor<List<Point>> captor = ArgumentCaptor.forClass(List.class);

        handler.handle("col", List.<String[]>of(new String[]{"simple-id", "text"}));

        verify(qdrantClient).upsertPoints(eq("col"), captor.capture());
        final Point point = captor.getValue().get(0);
        assertNotEquals("simple-id", point.getId()); // UUID v5, not original
    }

    // -------------------------------------------------------------------------
    // task 6.5 — batch chunking: QdrantClient.upsertPoints receives all points
    // (batching is inside QdrantClient); InsertHandler passes all in one call
    // per invocation. Verify 101 rows reach upsertPoints correctly.

    @Test
    void handle_passes_all_101_rows_to_upsertPoints() {
        final InsertHandler handler = new InsertHandler(qdrantClient);
        final List<String[]> rows = new ArrayList<>();
        for (int i = 0; i < 101; i++) {
            rows.add(new String[]{"id-" + i, "text " + i});
        }
        final ArgumentCaptor<List<Point>> captor = ArgumentCaptor.forClass(List.class);
        handler.handle("col", rows);
        verify(qdrantClient, times(1)).upsertPoints(eq("col"), captor.capture());
        assertEquals(101, captor.getValue().size());
    }

    // -------------------------------------------------------------------------
    // edge cases

    @Test
    void handle_does_nothing_for_empty_list() {
        new InsertHandler(qdrantClient).handle("col", List.of());
        verifyNoInteractions(qdrantClient);
    }

    @Test
    void handle_does_nothing_for_null_list() {
        new InsertHandler(qdrantClient).handle("col", null);
        verifyNoInteractions(qdrantClient);
    }

    @Test
    void handle_throws_for_row_with_fewer_than_two_columns() {
        final InsertHandler handler = new InsertHandler(qdrantClient);
        assertThrows(IllegalArgumentException.class,
                () -> handler.handle("col", List.<String[]>of(new String[]{"only-one-column"})));
    }
}
