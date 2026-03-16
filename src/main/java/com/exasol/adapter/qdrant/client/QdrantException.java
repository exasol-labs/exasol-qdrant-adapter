package com.exasol.adapter.qdrant.client;

/**
 * task 3.6 — Wraps Qdrant REST API errors with a descriptive message.
 */
public class QdrantException extends RuntimeException {

    private final int httpStatus;

    public QdrantException(final String message) {
        super(message);
        this.httpStatus = -1;
    }

    public QdrantException(final int httpStatus, final String qdrantMessage) {
        super("Qdrant returned HTTP " + httpStatus + ": " + qdrantMessage);
        this.httpStatus = httpStatus;
    }

    public QdrantException(final String message, final Throwable cause) {
        super(message, cause);
        this.httpStatus = -1;
    }

    public int getHttpStatus() {
        return httpStatus;
    }

    public boolean isCollectionAlreadyExists() {
        // Qdrant returns 400 with "already exists" in the body for duplicate collections
        return httpStatus == 400;
    }
}
