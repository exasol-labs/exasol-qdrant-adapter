package com.exasol.adapter.qdrant;

import org.junit.jupiter.api.Test;

import java.util.HashMap;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.*;

/**
 * task 2.4 — Unit tests for AdapterProperties validation.
 */
class AdapterPropertiesTest {

    @Test
    void validate_succeeds_with_all_required_properties() {
        final Map<String, String> props = Map.of(
                AdapterProperties.PROP_CONNECTION_NAME, "qdrant_conn",
                AdapterProperties.PROP_QDRANT_MODEL, "sentence-transformers/all-MiniLM-L6-v2"
        );
        assertDoesNotThrow(() -> new AdapterProperties(props).validate());
    }

    @Test
    void validate_throws_when_connection_name_is_missing() {
        final Map<String, String> props = Map.of(
                AdapterProperties.PROP_QDRANT_MODEL, "some-model"
        );
        final AdapterProperties.AdapterPropertiesException ex = assertThrows(
                AdapterProperties.AdapterPropertiesException.class,
                () -> new AdapterProperties(props).validate());
        assertTrue(ex.getMessage().contains(AdapterProperties.PROP_CONNECTION_NAME));
    }

    @Test
    void validate_throws_when_model_is_missing() {
        final Map<String, String> props = Map.of(
                AdapterProperties.PROP_CONNECTION_NAME, "qdrant_conn"
        );
        final AdapterProperties.AdapterPropertiesException ex = assertThrows(
                AdapterProperties.AdapterPropertiesException.class,
                () -> new AdapterProperties(props).validate());
        assertTrue(ex.getMessage().contains(AdapterProperties.PROP_QDRANT_MODEL));
    }

    @Test
    void validate_throws_when_connection_name_is_blank() {
        final Map<String, String> props = Map.of(
                AdapterProperties.PROP_CONNECTION_NAME, "   ",
                AdapterProperties.PROP_QDRANT_MODEL, "some-model"
        );
        assertThrows(AdapterProperties.AdapterPropertiesException.class,
                () -> new AdapterProperties(props).validate());
    }

    @Test
    void hasQdrantUrlOverride_returns_false_when_not_set() {
        final Map<String, String> props = Map.of(
                AdapterProperties.PROP_CONNECTION_NAME, "conn",
                AdapterProperties.PROP_QDRANT_MODEL, "model"
        );
        assertFalse(new AdapterProperties(props).hasQdrantUrlOverride());
    }

    @Test
    void hasQdrantUrlOverride_returns_true_when_url_is_set() {
        final Map<String, String> props = Map.of(
                AdapterProperties.PROP_CONNECTION_NAME, "conn",
                AdapterProperties.PROP_QDRANT_MODEL, "model",
                AdapterProperties.PROP_QDRANT_URL, "http://localhost:6333"
        );
        assertTrue(new AdapterProperties(props).hasQdrantUrlOverride());
    }

    @Test
    void getQdrantModel_returns_model_value() {
        final Map<String, String> props = Map.of(
                AdapterProperties.PROP_CONNECTION_NAME, "conn",
                AdapterProperties.PROP_QDRANT_MODEL, "my-model"
        );
        assertEquals("my-model", new AdapterProperties(props).getQdrantModel());
    }
}
