package com.exasol.adapter.qdrant.client.model;

/**
 * Represents a single result row from a Qdrant similarity search.
 *
 * id    → original VARCHAR id recovered from the "_original_id" payload field
 * text  → original text from the "text" payload field
 * score → cosine similarity score returned by Qdrant
 */
public class SearchResult {

    private final String id;
    private final String text;
    private final double score;

    public SearchResult(final String id, final String text, final double score) {
        this.id = id;
        this.text = text;
        this.score = score;
    }

    public String getId() {
        return id;
    }

    public String getText() {
        return text;
    }

    public double getScore() {
        return score;
    }
}
