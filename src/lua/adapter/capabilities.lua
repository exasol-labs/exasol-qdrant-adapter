--- Capability definitions for the Qdrant Virtual Schema Lua adapter.
-- Returns a plain list of capability name strings as expected by the
-- virtual-schema-common-lua framework (AbstractVirtualSchemaAdapter).
-- EXCLUDED_CAPABILITIES is handled by the base class's get_capabilities().

local CAPABILITIES = {
    "SELECTLIST_EXPRESSIONS",
    "FILTER_EXPRESSIONS",
    "LIMIT",
    "LIMIT_WITH_OFFSET",
    "FN_PRED_EQUAL",
    "LITERAL_STRING",
}

return CAPABILITIES
