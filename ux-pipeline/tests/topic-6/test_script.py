"""
Test: Topic 6 - OLLAMA_URL Default Misleading
Tests that OLLAMA_URL is now required (no misleading localhost default)
and that clear error messages guide users to set it correctly.

Note: These tests are designed to be run by the UX Tester agent
which has access to mcp__exasol_db__execute_query.
"""


class TestTopic6:
    """Test cases for OLLAMA_URL default removal."""

    def test_search_works_with_ollama_url_set(self):
        """
        SQL: SELECT "ID", "TEXT", "SCORE" FROM vector_schema.bank_failures WHERE "QUERY" = 'large bank failures' LIMIT 3
        EXPECT: Returns search results proving OLLAMA_URL is correctly configured
        PASS_IF: At least 1 row returned with non-null ID and SCORE > 0
        """
        pass  # Executed by UX Tester agent via MCP

    def test_adapter_script_contains_ollama_url_assertion(self):
        """
        SQL: SELECT SCRIPT_TEXT FROM SYS.EXA_ALL_SCRIPTS WHERE SCRIPT_NAME = 'VECTOR_SCHEMA_ADAPTER' AND SCRIPT_SCHEMA = 'ADAPTER'
        EXPECT: The deployed adapter script asserts OLLAMA_URL is present
        PASS_IF: Script text contains 'OLLAMA_URL property is not set'
        """
        pass  # Executed by UX Tester agent via MCP

    def test_missing_ollama_url_gives_clear_error(self):
        """
        This is a design verification test. The adapter code now asserts OLLAMA_URL
        is present before attempting to use it, instead of silently falling back to
        localhost:11434 which never works inside Docker.

        VERIFY: The SCRIPT_TEXT of VECTOR_SCHEMA_ADAPTER does NOT contain
                the old fallback pattern: 'or "http://localhost:11434"'
        SQL: SELECT SCRIPT_TEXT FROM SYS.EXA_ALL_SCRIPTS WHERE SCRIPT_NAME = 'VECTOR_SCHEMA_ADAPTER' AND SCRIPT_SCHEMA = 'ADAPTER'
        PASS_IF: Script text does NOT contain 'or "http://localhost:11434"'
        """
        pass  # Executed by UX Tester agent via MCP
