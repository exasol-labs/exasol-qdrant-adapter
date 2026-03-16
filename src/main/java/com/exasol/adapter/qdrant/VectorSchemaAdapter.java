package com.exasol.adapter.qdrant;

import com.exasol.ExaIterator;
import com.exasol.ExaMetadata;
import com.exasol.adapter.AdapterException;
import com.exasol.adapter.RequestDispatcher;
import com.exasol.adapter.VirtualSchemaAdapter;
import com.exasol.adapter.capabilities.*;
import com.exasol.adapter.metadata.*;
import com.exasol.adapter.qdrant.client.OllamaEmbeddingClient;
import com.exasol.adapter.qdrant.client.QdrantClient;
import com.exasol.adapter.qdrant.client.model.SearchResult;
import com.exasol.adapter.qdrant.handler.SelectHandler;
import com.exasol.adapter.request.*;
import com.exasol.adapter.response.*;
import com.exasol.adapter.sql.*;
import com.exasol.adapter.sql.SqlStatementSelect;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;

/**
 * tasks 8.1–8.3 — Main Exasol Virtual Schema Adapter for Qdrant.
 *
 * Implements {@link VirtualSchemaAdapter}; discovered via the AdapterFactory service loader
 * registered in META-INF/services/com.exasol.adapter.AdapterFactory.
 *
 * Deployment (UDF script definition):
 *
 *   CREATE OR REPLACE JAVA SET SCRIPT ADAPTER.VECTOR_SCHEMA_ADAPTER(input VARCHAR(2000000))
 *   EMITS (result VARCHAR(2000000)) AS
 *     %scriptclass com.exasol.adapter.qdrant.VectorSchemaAdapter;
 *     %jar /buckets/bfsdefault/adapter/qdrant-virtual-schema-0.1.0-all.jar;
 *   /
 *
 * The static {@link #adapterCall} method is the UDF entry point.
 */
public class VectorSchemaAdapter implements VirtualSchemaAdapter {

    // -------------------------------------------------------------------------
    // task 8.1 — UDF entry point

    /**
     * Called by Exasol for every adapter request.
     * Delegates to the RequestDispatcher which discovers this class via AdapterFactory.
     */
    public static void adapterCall(final ExaMetadata meta, final ExaIterator iter) throws Exception {
        final String input = iter.getString(0);
        iter.emit(RequestDispatcher.adapterCall(meta, input));
    }

    // -------------------------------------------------------------------------
    // Virtual schema lifecycle

    @Override
    public CreateVirtualSchemaResponse createVirtualSchema(final ExaMetadata exaMetadata,
                                                           final CreateVirtualSchemaRequest request)
            throws AdapterException {
        try {
            final com.exasol.adapter.qdrant.AdapterProperties props =
                    loadAndValidateProperties(request.getSchemaMetadataInfo().getProperties());
            final CredentialResolver credentials = new CredentialResolver(exaMetadata, props);
            final QdrantClient qdrantClient = new QdrantClient(
                    credentials.resolveBaseUrl(), credentials.resolveApiKey());
            return CreateVirtualSchemaResponse.builder()
                    .schemaMetadata(buildSchemaFromQdrant(qdrantClient))
                    .build();
        } catch (final Exception e) {
            throw new AdapterException("Failed to create virtual schema: " + e.getMessage(), e);
        }
    }

    @Override
    public RefreshResponse refresh(final ExaMetadata exaMetadata,
                                   final RefreshRequest request) throws AdapterException {
        try {
            final com.exasol.adapter.qdrant.AdapterProperties props =
                    loadAndValidateProperties(request.getSchemaMetadataInfo().getProperties());
            final CredentialResolver credentials = new CredentialResolver(exaMetadata, props);
            final QdrantClient qdrantClient = new QdrantClient(
                    credentials.resolveBaseUrl(), credentials.resolveApiKey());
            return RefreshResponse.builder()
                    .schemaMetadata(buildSchemaFromQdrant(qdrantClient))
                    .build();
        } catch (final Exception e) {
            throw new AdapterException("Failed to refresh virtual schema: " + e.getMessage(), e);
        }
    }

    @Override
    public SetPropertiesResponse setProperties(final ExaMetadata exaMetadata,
                                               final SetPropertiesRequest request)
            throws AdapterException {
        final Map<String, String> merged = new java.util.HashMap<>(
                request.getSchemaMetadataInfo().getProperties());
        merged.putAll(request.getProperties());
        final com.exasol.adapter.qdrant.AdapterProperties props =
                new com.exasol.adapter.qdrant.AdapterProperties(merged);
        props.validate();
        return SetPropertiesResponse.builder()
                .schemaMetadata(emptySchema())
                .build();
    }

    @Override
    public DropVirtualSchemaResponse dropVirtualSchema(final ExaMetadata exaMetadata,
                                                       final DropVirtualSchemaRequest request) {
        return DropVirtualSchemaResponse.builder().build();
    }

    // -------------------------------------------------------------------------
    // task 8.3 — capabilities declaration

    @Override
    public GetCapabilitiesResponse getCapabilities(final ExaMetadata exaMetadata,
                                                   final GetCapabilitiesRequest request) {
        final Capabilities capabilities = Capabilities.builder()
                .addMain(MainCapability.SELECTLIST_EXPRESSIONS)
                .addMain(MainCapability.FILTER_EXPRESSIONS)
                .addMain(MainCapability.LIMIT)
                .addMain(MainCapability.LIMIT_WITH_OFFSET)
                .addPredicate(PredicateCapability.EQUAL)
                .addLiteral(LiteralCapability.STRING)
                .build();
        return GetCapabilitiesResponse.builder().capabilities(capabilities).build();
    }

    // -------------------------------------------------------------------------
    // task 8.2 — push-down routing

    @Override
    public PushDownResponse pushdown(final ExaMetadata exaMetadata,
                                     final PushDownRequest request) throws AdapterException {
        try {
            final com.exasol.adapter.qdrant.AdapterProperties props =
                    loadAndValidateProperties(request.getSchemaMetadataInfo().getProperties());
            final CredentialResolver credentials = new CredentialResolver(exaMetadata, props);
            final QdrantClient qdrantClient = new QdrantClient(
                    credentials.resolveBaseUrl(),
                    credentials.resolveApiKey());

            final OllamaEmbeddingClient ollamaClient = new OllamaEmbeddingClient(
                    props.getOllamaUrl(),
                    props.getQdrantModel());

            // Expect the pushed-down statement to be a SqlStatementSelect
            if (!(request.getSelect() instanceof SqlStatementSelect)) {
                throw new AdapterException("Only SELECT push-downs are supported.");
            }
            final SqlStatementSelect select = (SqlStatementSelect) request.getSelect();

            final String collectionName = extractCollectionName(request);
            final String queryText = extractQueryString(select);
            final int limit = extractLimit(select);

            final SelectHandler selectHandler = new SelectHandler(qdrantClient, ollamaClient);
            final List<SearchResult> results = selectHandler.handle(collectionName, queryText, limit);

            return PushDownResponse.builder()
                    .pushDownSql(buildResultSql(queryText, results))
                    .build();
        } catch (final AdapterException e) {
            throw e;
        } catch (final Exception e) {
            throw new AdapterException("Push-down failed: " + e.getMessage(), e);
        }
    }

    // -------------------------------------------------------------------------
    // Helpers

    private com.exasol.adapter.qdrant.AdapterProperties loadAndValidateProperties(
            final Map<String, String> properties) {
        final com.exasol.adapter.qdrant.AdapterProperties props =
                new com.exasol.adapter.qdrant.AdapterProperties(properties);
        props.validate();
        return props;
    }

    private SchemaMetadata buildSchemaFromQdrant(final QdrantClient qdrantClient) {
        final List<TableMetadata> tables = new ArrayList<>();
        for (final String name : qdrantClient.listCollections()) {
            tables.add(buildTableMetadata(name.toUpperCase()));
        }
        return new SchemaMetadata("", tables);
    }

    private SchemaMetadata emptySchema() {
        return new SchemaMetadata("", List.of());
    }

    private TableMetadata buildTableMetadata(final String tableName) {
        final List<ColumnMetadata> columns = List.of(
                ColumnMetadata.builder().name("ID")
                        .type(DataType.createVarChar(2_000_000, DataType.ExaCharset.UTF8)).build(),
                ColumnMetadata.builder().name("TEXT")
                        .type(DataType.createVarChar(2_000_000, DataType.ExaCharset.UTF8)).build(),
                ColumnMetadata.builder().name("SCORE")
                        .type(DataType.createDouble()).build(),
                ColumnMetadata.builder().name("QUERY")
                        .type(DataType.createVarChar(2_000_000, DataType.ExaCharset.UTF8)).build()
        );
        return new TableMetadata(tableName, "", columns, "");
    }

    /** Extracts the collection name from the first involved table, lowercased to match Qdrant. */
    private String extractCollectionName(final PushDownRequest request) {
        return request.getInvolvedTablesMetadata().get(0).getName().toLowerCase();
    }

    /**
     * Walks the WHERE clause AST looking for a predicate of the form QUERY = 'literal'.
     * Returns the literal value, or empty string if not found.
     */
    private String extractQueryString(final SqlStatementSelect select) {
        if (!select.hasFilter()) {
            return "";
        }
        return extractFromNode(select.getWhereClause());
    }

    private String extractFromNode(final SqlNode node) {
        if (node instanceof SqlPredicateEqual) {
            final SqlPredicateEqual eq = (SqlPredicateEqual) node;
            final String val = extractEqualValue(eq.getLeft(), eq.getRight());
            return val != null ? val : extractEqualValue(eq.getRight(), eq.getLeft());
        }
        return "";
    }

    /** If one side is column QUERY and the other is a string literal, return the literal. */
    private String extractEqualValue(final SqlNode maybCol, final SqlNode maybeVal) {
        if (maybCol instanceof SqlColumn && maybeVal instanceof SqlLiteralString) {
            final String colName = ((SqlColumn) maybCol).getName();
            if ("QUERY".equalsIgnoreCase(colName)) {
                return ((SqlLiteralString) maybeVal).getValue();
            }
        }
        return null;
    }

    /** Extracts the LIMIT value, defaulting to 10 if absent. */
    private int extractLimit(final SqlStatementSelect select) {
        if (select.hasLimit()) {
            return select.getLimit().getLimit();
        }
        return 10;
    }

    /**
     * Builds a VALUES-based SELECT that Exasol uses to materialise the result set.
     * This is the push-down response SQL returned to the Exasol engine.
     */
    private String buildResultSql(final String queryText, final List<SearchResult> results) {
        if (results.isEmpty()) {
            return "SELECT CAST('' AS VARCHAR(36) UTF8) AS ID,"
                    + " CAST('' AS VARCHAR(2000000) UTF8) AS TEXT,"
                    + " CAST(0 AS DOUBLE) AS SCORE,"
                    + " CAST('' AS VARCHAR(2000000) UTF8) AS QUERY"
                    + " FROM DUAL WHERE FALSE";
        }
        final StringBuilder sb = new StringBuilder("SELECT * FROM VALUES ");
        for (int i = 0; i < results.size(); i++) {
            final SearchResult r = results.get(i);
            if (i > 0) sb.append(", ");
            sb.append("(CAST('")
              .append(escape(r.getId())).append("' AS VARCHAR(2000000) UTF8),CAST('")
              .append(escape(r.getText())).append("' AS VARCHAR(2000000) UTF8),")
              .append("CAST(").append(r.getScore()).append(" AS DOUBLE),CAST('")
              .append(escape(queryText)).append("' AS VARCHAR(2000000) UTF8))");
        }
        sb.append(" AS t(ID, TEXT, SCORE, QUERY)");
        return sb.toString();
    }

    private String escape(final String s) {
        return s == null ? "" : s.replace("'", "''");
    }
}
