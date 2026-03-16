package com.exasol.adapter.qdrant.it;

import org.junit.jupiter.api.*;

import java.net.Socket;
import java.sql.*;

import static org.junit.jupiter.api.Assertions.*;
import static org.junit.jupiter.api.Assumptions.assumeTrue;

/**
 * task 9.5 — Exasol connectivity and basic SQL tests.
 *
 * Connects to the Exasol instance running in Docker and verifies:
 *   - JDBC connection succeeds with sys/exasol credentials
 *   - Basic SQL queries execute correctly
 *   - The database is healthy enough for adapter deployment
 *
 * Run with: mvn verify -Pit
 * Exasol expected at: localhost:9563 (mapped from container port 8563)
 */
@Tag("integration")
class ExasolConnectivityIT {

    private static final String EXASOL_HOST     = System.getProperty("exasol.host", "localhost");
    private static final String EXASOL_PORT     = System.getProperty("exasol.port", "9563");
    private static final String EXASOL_USER     = System.getProperty("exasol.user", "sys");
    private static final String EXASOL_PASSWORD = System.getProperty("exasol.password", "exasol");

    private static final String JDBC_URL =
            "jdbc:exa:" + EXASOL_HOST + ":" + EXASOL_PORT
            + ";validateservercertificate=0";

    private Connection connection;

    @BeforeAll
    static void checkExasolReachable() {
        final int port = Integer.parseInt(EXASOL_PORT);
        assumeTrue(isReachable(EXASOL_HOST, port),
                "Skipping Exasol integration tests — not reachable at " + EXASOL_HOST + ":" + port);
    }

    @BeforeEach
    void connect() throws SQLException {
        try {
            Class.forName("com.exasol.jdbc.EXADriver");
        } catch (final ClassNotFoundException e) {
            fail("Exasol JDBC driver not found on classpath: " + e.getMessage());
        }
        connection = DriverManager.getConnection(JDBC_URL, EXASOL_USER, EXASOL_PASSWORD);
    }

    @AfterEach
    void disconnect() throws SQLException {
        if (connection != null && !connection.isClosed()) {
            connection.close();
        }
    }

    // -------------------------------------------------------------------------

    @Test
    void connection_is_valid() throws SQLException {
        assertTrue(connection.isValid(5), "Exasol JDBC connection should be valid");
    }

    @Test
    void basic_select_dual_executes() throws SQLException {
        try (Statement stmt = connection.createStatement();
             ResultSet rs = stmt.executeQuery("SELECT 1 FROM DUAL")) {
            assertTrue(rs.next());
            assertEquals(1, rs.getInt(1));
        }
    }

    @Test
    void exasol_version_is_retrievable() throws SQLException {
        final DatabaseMetaData meta = connection.getMetaData();
        final String version = meta.getDatabaseProductVersion();
        assertNotNull(version);
        System.out.println("Exasol version: " + version);
    }

    @Test
    void can_create_and_drop_schema() throws SQLException {
        final String schema = "IT_TEST_SCHEMA_" + System.nanoTime();
        try (Statement stmt = connection.createStatement()) {
            stmt.execute("CREATE SCHEMA " + schema);
            stmt.execute("DROP SCHEMA " + schema + " CASCADE");
        }
    }

    @Test
    void can_create_connection_object_for_qdrant() throws SQLException {
        // Verifies that an Exasol CONNECTION object can be created (prerequisite for adapter deployment)
        final String connName = "IT_QDRANT_CONN_" + System.nanoTime();
        try (Statement stmt = connection.createStatement()) {
            stmt.execute(
                "CREATE OR REPLACE CONNECTION " + connName
                + " TO 'http://localhost:6333'"
                + " USER ''"
                + " IDENTIFIED BY 'test-key'");
            // Verify it exists
            try (ResultSet rs = stmt.executeQuery(
                    "SELECT CONNECTION_NAME FROM EXA_ALL_CONNECTIONS"
                    + " WHERE CONNECTION_NAME = '" + connName + "'")) {
                assertTrue(rs.next(),
                        "CONNECTION object should exist after creation");
            }
        } finally {
            // Cleanup
            try (Statement stmt = connection.createStatement()) {
                stmt.execute("DROP CONNECTION " + connName);
            } catch (final Exception ignored) {}
        }
    }

    @Test
    void can_list_schemas() throws SQLException {
        try (Statement stmt = connection.createStatement();
             ResultSet rs = stmt.executeQuery(
                     "SELECT SCHEMA_NAME FROM EXA_ALL_SCHEMAS ORDER BY SCHEMA_NAME LIMIT 5")) {
            int count = 0;
            while (rs.next()) count++;
            assertTrue(count > 0, "Should have at least one schema");
        }
    }

    // -------------------------------------------------------------------------

    private static boolean isReachable(final String host, final int port) {
        try (Socket s = new Socket(host, port)) { return true; }
        catch (final Exception e) { return false; }
    }
}
