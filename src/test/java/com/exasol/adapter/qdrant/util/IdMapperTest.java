package com.exasol.adapter.qdrant.util;

import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.*;

/**
 * task 4.3 — Unit tests for IdMapper UUID v5 generation.
 */
class IdMapperTest {

    @Test
    void toUuidV5_returns_valid_uuid_string() {
        final String uuid = IdMapper.toUuidV5("some-id");
        assertNotNull(uuid);
        // UUID format: 8-4-4-4-12 hex chars with dashes
        assertTrue(uuid.matches("[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"),
                "Expected UUID format but got: " + uuid);
    }

    @Test
    void toUuidV5_is_deterministic_for_same_input() {
        final String id = "user-123";
        assertEquals(IdMapper.toUuidV5(id), IdMapper.toUuidV5(id));
    }

    @Test
    void toUuidV5_produces_different_uuids_for_different_inputs() {
        assertNotEquals(IdMapper.toUuidV5("id-a"), IdMapper.toUuidV5("id-b"));
    }

    @Test
    void toUuidV5_sets_version_5_in_uuid() {
        final String uuid = IdMapper.toUuidV5("any-value");
        // Version is encoded in the 13th character (position 14 in string with dashes)
        final char versionChar = uuid.charAt(14);
        assertEquals('5', versionChar, "UUID version nibble should be '5'");
    }

    @Test
    void toUuidV5_handles_empty_string() {
        assertDoesNotThrow(() -> IdMapper.toUuidV5(""));
    }

    @Test
    void toUuidV5_handles_unicode_input() {
        assertDoesNotThrow(() -> IdMapper.toUuidV5("日本語テスト"));
    }

    @Test
    void toUuidV5_round_trip_is_stable() {
        // The same original ID always maps to the same UUID across calls
        final String originalId = "record-abc-456";
        final String uuid1 = IdMapper.toUuidV5(originalId);
        final String uuid2 = IdMapper.toUuidV5(originalId);
        assertEquals(uuid1, uuid2);
    }
}
