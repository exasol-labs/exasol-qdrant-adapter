package com.exasol.adapter.qdrant;

import com.exasol.adapter.AdapterFactory;
import com.exasol.adapter.VirtualSchemaAdapter;

/**
 * Service-loader entry point for the Qdrant Virtual Schema Adapter.
 *
 * Registered via META-INF/services/com.exasol.adapter.AdapterFactory so that
 * RequestDispatcher.adapterCall() can discover and instantiate the adapter.
 */
public class VectorSchemaAdapterFactory implements AdapterFactory {

    static final String ADAPTER_NAME    = "QDRANT_ADAPTER";
    static final String ADAPTER_VERSION = "0.1.0";

    @Override
    public VirtualSchemaAdapter createAdapter() {
        return new VectorSchemaAdapter();
    }

    @Override
    public String getAdapterVersion() {
        return ADAPTER_VERSION;
    }

    @Override
    public String getAdapterName() {
        return ADAPTER_NAME;
    }
}
