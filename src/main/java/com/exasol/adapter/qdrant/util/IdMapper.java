package com.exasol.adapter.qdrant.util;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.UUID;

/**
 * tasks 4.1 & 4.2 — Maps arbitrary VARCHAR IDs to deterministic UUID v5.
 *
 * Qdrant point IDs must be unsigned integers or UUIDs. This class converts
 * VARCHAR IDs to UUID v5 using a fixed namespace so the mapping is:
 *   - deterministic (same input always yields same UUID)
 *   - collision-resistant (SHA-1 based)
 *
 * The original VARCHAR ID is stored in the Qdrant point payload under the
 * key "_original_id" so it can be recovered on search (task 4.2).
 *
 * UUID v5 namespace used: a fixed adapter-specific UUID.
 */
public class IdMapper {

    /** Adapter-specific UUID v5 namespace (fixed constant). */
    private static final UUID NAMESPACE =
            UUID.fromString("6ba7b810-9dad-11d1-80b4-00c04fd430c8"); // DNS namespace per RFC 4122

    private IdMapper() {
        // utility class
    }

    /**
     * Converts a VARCHAR id to a deterministic UUID v5 string.
     *
     * @param originalId the original VARCHAR id from the Exasol INSERT
     * @return UUID v5 string suitable for use as a Qdrant point id
     */
    public static String toUuidV5(final String originalId) {
        final byte[] namespaceBytes = toBytes(NAMESPACE);
        final byte[] nameBytes = originalId.getBytes(StandardCharsets.UTF_8);
        final byte[] combined = new byte[namespaceBytes.length + nameBytes.length];
        System.arraycopy(namespaceBytes, 0, combined, 0, namespaceBytes.length);
        System.arraycopy(nameBytes, 0, combined, namespaceBytes.length, nameBytes.length);

        final byte[] digest = sha1(combined);

        // set version to 5 (0101 in upper nibble of byte 6)
        digest[6] = (byte) ((digest[6] & 0x0f) | 0x50);
        // set variant bits (10xx in upper two bits of byte 8)
        digest[8] = (byte) ((digest[8] & 0x3f) | 0x80);

        return fromBytes(digest).toString();
    }

    private static byte[] toBytes(final UUID uuid) {
        final long msb = uuid.getMostSignificantBits();
        final long lsb = uuid.getLeastSignificantBits();
        final byte[] bytes = new byte[16];
        for (int i = 7; i >= 0; i--) {
            bytes[i]     = (byte) (msb >>> (8 * (7 - i)));
            bytes[i + 8] = (byte) (lsb >>> (8 * (7 - i)));
        }
        return bytes;
    }

    private static UUID fromBytes(final byte[] bytes) {
        long msb = 0;
        long lsb = 0;
        for (int i = 0; i < 8; i++) {
            msb = (msb << 8) | (bytes[i] & 0xff);
        }
        for (int i = 8; i < 16; i++) {
            lsb = (lsb << 8) | (bytes[i] & 0xff);
        }
        return new UUID(msb, lsb);
    }

    private static byte[] sha1(final byte[] input) {
        try {
            return MessageDigest.getInstance("SHA-1").digest(input);
        } catch (final NoSuchAlgorithmException e) {
            // SHA-1 is guaranteed to be present in all Java SE implementations
            throw new IllegalStateException("SHA-1 not available", e);
        }
    }
}
