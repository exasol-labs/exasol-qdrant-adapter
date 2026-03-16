package com.exasol.adapter.qdrant;

import java.util.Map;

/**
 * Reads and validates virtual schema properties.
 *
 * Required properties:
 *   CONNECTION_NAME  - name of the Exasol CONNECTION object holding the Qdrant URL and API key
 *   QDRANT_MODEL     - inference model name as configured in Qdrant (e.g. "sentence-transformers/all-MiniLM-L6-v2")
 *
 * Optional properties:
 *   QDRANT_URL       - direct Qdrant base URL; overrides the address in CONNECTION_NAME when set
 */
public class AdapterProperties {

    // task 2.1 — property key constants
    public static final String PROP_CONNECTION_NAME = "CONNECTION_NAME";
    public static final String PROP_QDRANT_MODEL    = "QDRANT_MODEL";
    public static final String PROP_QDRANT_URL      = "QDRANT_URL";
    public static final String PROP_OLLAMA_URL      = "OLLAMA_URL";

    private static final String DEFAULT_OLLAMA_URL  = "http://localhost:11434";

    private final Map<String, String> properties;

    public AdapterProperties(final Map<String, String> properties) {
        this.properties = properties;
    }

    // task 2.2 — property validation

    /**
     * Validates that all required properties are present and non-empty.
     *
     * @throws AdapterPropertiesException if any required property is missing or blank
     */
    public void validate() {
        requireNonBlank(PROP_CONNECTION_NAME);
        requireNonBlank(PROP_QDRANT_MODEL);
    }

    public String getConnectionName() {
        return properties.get(PROP_CONNECTION_NAME);
    }

    public String getQdrantModel() {
        return properties.get(PROP_QDRANT_MODEL);
    }

    /**
     * Returns the Ollama base URL, defaulting to {@code http://localhost:11434} if not set.
     */
    public String getOllamaUrl() {
        final String val = properties.get(PROP_OLLAMA_URL);
        return (val != null && !val.isBlank()) ? val : DEFAULT_OLLAMA_URL;
    }

    /** Returns an explicit URL override, or {@code null} if not set (URL comes from the connection object). */
    public String getQdrantUrlOverride() {
        return properties.get(PROP_QDRANT_URL);
    }

    public boolean hasQdrantUrlOverride() {
        final String val = properties.get(PROP_QDRANT_URL);
        return val != null && !val.isBlank();
    }

    private void requireNonBlank(final String key) {
        final String val = properties.get(key);
        if (val == null || val.isBlank()) {
            throw new AdapterPropertiesException(
                    "Required virtual schema property '" + key + "' is missing or empty.");
        }
    }

    // -------------------------------------------------------------------------

    /** Thrown when required virtual schema properties are absent or invalid. */
    public static class AdapterPropertiesException extends RuntimeException {
        public AdapterPropertiesException(final String message) {
            super(message);
        }
    }
}
