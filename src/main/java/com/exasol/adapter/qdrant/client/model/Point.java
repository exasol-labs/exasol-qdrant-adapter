package com.exasol.adapter.qdrant.client.model;

import java.util.Map;

/**
 * Represents a single Qdrant point to be upserted.
 *
 * id           → UUID string derived from the original VARCHAR id via IdMapper
 * originalId   → original VARCHAR id stored in payload under "_original_id"
 * text         → raw text to be embedded by Qdrant's inference API
 * extraPayload → additional key/value pairs to store alongside the text
 */
public class Point {

    private final String id;
    private final String originalId;
    private final String text;

    public Point(final String id, final String originalId, final String text) {
        this.id = id;
        this.originalId = originalId;
        this.text = text;
    }

    public String getId() {
        return id;
    }

    public String getOriginalId() {
        return originalId;
    }

    public String getText() {
        return text;
    }
}
