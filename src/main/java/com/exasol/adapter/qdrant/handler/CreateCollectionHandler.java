package com.exasol.adapter.qdrant.handler;

import com.exasol.adapter.qdrant.client.QdrantClient;
import com.exasol.adapter.qdrant.client.QdrantException;

/**
 * tasks 5.1–5.3 — Handles the "CREATE TABLE" use case by creating a Qdrant collection.
 *
 * In the Exasol virtual schema framework, CREATE TABLE DDL is not forwarded to the
 * adapter via push-down. Instead, collection creation is exposed as a companion
 * operation that can be triggered:
 *   (a) from a Lua/Python stored script that calls this handler's logic, OR
 *   (b) from the adapter's createVirtualSchema callback when the schema is first set up.
 *
 * This handler encapsulates the core collection-creation logic independently of
 * how it is invoked, making it testable in isolation.
 */
public class CreateCollectionHandler {

    private final QdrantClient qdrantClient;
    private final String modelName;

    private final int vectorSize;

    public CreateCollectionHandler(final QdrantClient qdrantClient,
                                   final String modelName,
                                   final int vectorSize) {
        this.qdrantClient = qdrantClient;
        this.modelName = modelName;
        this.vectorSize = vectorSize;
    }

    /** Convenience constructor using a default vector size of 384 (all-MiniLM-L6-v2 output dim). */
    public CreateCollectionHandler(final QdrantClient qdrantClient, final String modelName) {
        this(qdrantClient, modelName, 384);
    }

    /**
     * task 5.1 — Creates a Qdrant collection for the given table name.
     * task 5.2 — Checks for duplicate collection; throws if already exists.
     * task 5.3 — Passes the schema-level model name to Qdrant.
     *
     * @param collectionName the Qdrant collection name (maps to the virtual schema table name)
     * @throws QdrantException         if Qdrant returns an error
     * @throws CollectionExistsException if a collection with that name already exists
     */
    public void handle(final String collectionName) {
        // task 5.2 — fail fast with a meaningful error if collection already exists
        if (qdrantClient.collectionExists(collectionName)) {
            throw new CollectionExistsException(
                    "Cannot create vector table: a Qdrant collection named '"
                            + collectionName + "' already exists.");
        }

        // task 5.3 — create with the schema-level inference model and configured vector size
        qdrantClient.createCollection(collectionName, modelName, vectorSize);
    }

    // -------------------------------------------------------------------------

    /** Thrown when CREATE TABLE targets a collection that already exists. */
    public static class CollectionExistsException extends RuntimeException {
        public CollectionExistsException(final String message) {
            super(message);
        }
    }
}
