package com.exasol.adapter.qdrant.handler;

import com.exasol.adapter.qdrant.client.QdrantClient;
import com.exasol.adapter.qdrant.client.model.SearchResult;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

import java.util.Collections;
import java.util.List;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

/**
 * task 7.7 — Unit tests for SelectHandler query string extraction and result mapping.
 */
@ExtendWith(MockitoExtension.class)
class SelectHandlerTest {

    @Mock
    private QdrantClient qdrantClient;

    // -------------------------------------------------------------------------
    // query forwarding

    @Test
    void handle_forwards_query_to_qdrant_client() {
        when(qdrantClient.searchPoints("col", "find me", 5))
                .thenReturn(List.of(new SearchResult("id-1", "some text", 0.9)));

        final SelectHandler handler = new SelectHandler(qdrantClient);
        final List<SearchResult> results = handler.handle("col", "find me", 5);

        verify(qdrantClient).searchPoints("col", "find me", 5);
        assertEquals(1, results.size());
    }

    @Test
    void handle_uses_default_limit_when_limit_is_zero() {
        when(qdrantClient.searchPoints(eq("col"), eq("query"), eq(10)))
                .thenReturn(Collections.emptyList());

        new SelectHandler(qdrantClient).handle("col", "query", 0);

        verify(qdrantClient).searchPoints("col", "query", 10);
    }

    @Test
    void handle_uses_default_limit_when_limit_is_negative() {
        when(qdrantClient.searchPoints(eq("col"), eq("q"), eq(10)))
                .thenReturn(Collections.emptyList());

        new SelectHandler(qdrantClient).handle("col", "q", -1);

        verify(qdrantClient).searchPoints("col", "q", 10);
    }

    // -------------------------------------------------------------------------
    // empty / null query

    @Test
    void handle_returns_empty_list_for_null_query() {
        final List<SearchResult> results = new SelectHandler(qdrantClient).handle("col", null, 5);
        assertTrue(results.isEmpty());
        verifyNoInteractions(qdrantClient);
    }

    @Test
    void handle_returns_empty_list_for_blank_query() {
        final List<SearchResult> results = new SelectHandler(qdrantClient).handle("col", "  ", 5);
        assertTrue(results.isEmpty());
        verifyNoInteractions(qdrantClient);
    }

    // -------------------------------------------------------------------------
    // empty result set (task 7.6)

    @Test
    void handle_returns_empty_list_when_qdrant_returns_no_results() {
        when(qdrantClient.searchPoints(any(), any(), anyInt()))
                .thenReturn(Collections.emptyList());

        final List<SearchResult> results = new SelectHandler(qdrantClient).handle("col", "noresults", 5);
        assertTrue(results.isEmpty());
    }

    // -------------------------------------------------------------------------
    // result mapping (task 7.5 — original id, text, score)

    @Test
    void handle_preserves_original_id_text_and_score_from_qdrant() {
        final SearchResult expected = new SearchResult("orig-42", "the text", 0.876);
        when(qdrantClient.searchPoints(any(), any(), anyInt())).thenReturn(List.of(expected));

        final List<SearchResult> results = new SelectHandler(qdrantClient).handle("col", "q", 3);

        assertEquals(1, results.size());
        assertEquals("orig-42", results.get(0).getId());
        assertEquals("the text", results.get(0).getText());
        assertEquals(0.876, results.get(0).getScore(), 0.001);
    }
}
