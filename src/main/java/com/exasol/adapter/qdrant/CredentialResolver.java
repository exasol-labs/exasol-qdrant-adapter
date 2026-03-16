package com.exasol.adapter.qdrant;

import com.exasol.ExaConnectionInformation;
import com.exasol.ExaMetadata;

/**
 * task 2.3 — Resolves Qdrant connection details from an Exasol CONNECTION object.
 *
 * The Exasol CONNECTION is created by an administrator via:
 *
 *   CREATE OR REPLACE CONNECTION qdrant_conn
 *       TO 'https://qdrant-host:6333'
 *       USER ''
 *       IDENTIFIED BY 'your-api-key';
 *
 * ADDRESS  → Qdrant base URL
 * PASSWORD → Qdrant API key
 */
public class CredentialResolver {

    private final ExaMetadata exaMetadata;
    private final AdapterProperties adapterProperties;

    public CredentialResolver(final ExaMetadata exaMetadata, final AdapterProperties adapterProperties) {
        this.exaMetadata = exaMetadata;
        this.adapterProperties = adapterProperties;
    }

    /** @return Qdrant base URL (trailing slash removed) */
    public String resolveBaseUrl() throws Exception {
        if (adapterProperties.hasQdrantUrlOverride()) {
            return normalise(adapterProperties.getQdrantUrlOverride());
        }
        final ExaConnectionInformation conn = exaMetadata.getConnection(adapterProperties.getConnectionName());
        return normalise(conn.getAddress());
    }

    /** @return Qdrant API key, or empty string if not set */
    public String resolveApiKey() throws Exception {
        final ExaConnectionInformation conn = exaMetadata.getConnection(adapterProperties.getConnectionName());
        final String apiKey = conn.getPassword();
        return apiKey != null ? apiKey : "";
    }

    private String normalise(final String url) {
        return url.endsWith("/") ? url.substring(0, url.length() - 1) : url;
    }
}
