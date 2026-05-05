"""Unit tests for QueryRewriter — the simplified pushdown SQL builder.

The Lua adapter no longer runs SQL or HTTP itself during pushdown (Exasol
forbids exa.pquery_no_preprocessing in that context). Instead, it generates
SQL that calls the ADAPTER.SEARCH_QDRANT_LOCAL SET UDF, and that UDF owns
embed + Qdrant search work.

These tests drive the Lua module from Python via `lupa` and assert that the
generated SQL string has the expected shape for representative pushdown
requests. We don't need to stub `pquery`, `cjson`, or any HTTP layer —
QueryRewriter has none of those imports anymore.

Skipped if `lupa` is not installed.
"""

import os
import unittest

try:
    import lupa
    from lupa import LuaRuntime
except ImportError:  # pragma: no cover
    lupa = None


def _project_root():
    return os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))


def _read(rel_path):
    with open(os.path.join(_project_root(), rel_path), "r", encoding="utf-8") as f:
        return f.read()


@unittest.skipIf(lupa is None, "lupa not installed; pip install lupa to run")
class TestQueryRewriterRewrite(unittest.TestCase):
    """The full happy path: a QUERY = '...' filter with a LIMIT."""

    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        src = _read("src/lua/adapter/QueryRewriter.lua")
        self.QueryRewriter = self.lua.execute(src)

    def _new(self, conn_name="qdrant_conn"):
        return self.QueryRewriter.new(self.QueryRewriter, conn_name)

    def _request(self, table_name="bank_failures", query_text="banks in NY",
                 limit=10, filter_node=None):
        L = self.lua.eval
        if filter_node is None:
            filter_node = L(
                "function(qt) return {"
                " type='predicate_equal',"
                " left={type='column', name='QUERY'},"
                " right={type='literal_string', value=qt}"
                "} end"
            )(query_text)
        push = self.lua.table_from({})
        push["filter"] = filter_node
        if limit is not None:
            push["limit"] = self.lua.table_from({"numElements": limit})
        req = self.lua.table_from({})
        req["pushdownRequest"] = push
        # involvedTables is a 1-indexed array of {name=...}
        tables = self.lua.table()
        tables[1] = self.lua.table_from({"name": table_name})
        req["involvedTables"] = tables
        return req

    def test_generates_search_qdrant_local_call_with_correct_args(self):
        rewriter = self._new("qdrant_conn")
        req = self._request("bank_failures", "banks acquired by JP Morgan", 10)
        sql = rewriter.rewrite(rewriter, req)
        self.assertIn("ADAPTER.SEARCH_QDRANT_LOCAL", sql)
        self.assertIn("'qdrant_conn'", sql)
        self.assertIn("'bank_failures'", sql)
        self.assertIn("'banks acquired by JP Morgan'", sql)
        self.assertIn(", 10)", sql)
        self.assertIn("FROM DUAL", sql)

    def test_aliases_emit_columns_to_virtual_schema_columns(self):
        rewriter = self._new()
        req = self._request("foo", "bar", 5)
        sql = rewriter.rewrite(rewriter, req)
        self.assertIn('result_id AS "ID"', sql)
        self.assertIn('result_text AS "TEXT"', sql)
        self.assertIn('result_score AS "SCORE"', sql)
        self.assertIn('result_query AS "QUERY"', sql)

    def test_lowercases_collection_name(self):
        rewriter = self._new()
        req = self._request("BANK_FAILURES", "anything", 10)
        sql = rewriter.rewrite(rewriter, req)
        self.assertIn("'bank_failures'", sql)
        self.assertNotIn("'BANK_FAILURES'", sql)

    def test_default_limit_when_none_specified(self):
        rewriter = self._new()
        req = self._request("foo", "bar", limit=None)
        sql = rewriter.rewrite(rewriter, req)
        self.assertIn(", 10)", sql)

    def test_escapes_single_quotes_in_query_text(self):
        rewriter = self._new()
        req = self._request("foo", "Bob's bank", 5)
        sql = rewriter.rewrite(rewriter, req)
        # Single quote SHALL be doubled in SQL literal form.
        self.assertIn("'Bob''s bank'", sql)

    def test_supports_reversed_predicate_literal_eq_query(self):
        L = self.lua.eval
        flipped = L(
            "function() return {"
            " type='predicate_equal',"
            " left={type='literal_string', value='reversed text'},"
            " right={type='column', name='QUERY'}"
            "} end"
        )()
        rewriter = self._new()
        req = self._request("foo", "ignored", 7, filter_node=flipped)
        sql = rewriter.rewrite(rewriter, req)
        self.assertIn("'reversed text'", sql)
        self.assertIn(", 7)", sql)


@unittest.skipIf(lupa is None, "lupa not installed; pip install lupa to run")
class TestQueryRewriterEmptyQuery(unittest.TestCase):
    """When the user omits or mis-specifies the QUERY predicate, the rewriter
    SHALL return a single-row hint instead of crashing. The hint surfaces in
    the result set as ID='HINT' so the user sees actionable advice."""

    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        src = _read("src/lua/adapter/QueryRewriter.lua")
        self.QueryRewriter = self.lua.execute(src)

    def _new(self):
        return self.QueryRewriter.new(self.QueryRewriter, "qdrant_conn")

    def _request(self, filter_node):
        push = self.lua.table_from({})
        if filter_node is not None:
            push["filter"] = filter_node
        req = self.lua.table_from({})
        req["pushdownRequest"] = push
        tables = self.lua.table()
        tables[1] = self.lua.table_from({"name": "bank_failures"})
        req["involvedTables"] = tables
        return req

    def test_no_filter_returns_help_hint(self):
        rewriter = self._new()
        sql = rewriter.rewrite(rewriter, self._request(None))
        self.assertIn("HINT", sql)
        self.assertIn("Semantic search requires", sql)
        self.assertNotIn("SEARCH_QDRANT_LOCAL", sql)

    def test_unsupported_filter_returns_unsupported_hint(self):
        L = self.lua.eval
        unsupported = L(
            "function() return {"
            " type='predicate_less',"
            " left={type='column', name='SCORE'},"
            " right={type='literal_double', value=0.5}"
            "} end"
        )()
        rewriter = self._new()
        sql = rewriter.rewrite(rewriter, self._request(unsupported))
        self.assertIn("HINT", sql)
        self.assertIn("Unsupported predicate", sql)
        self.assertNotIn("SEARCH_QDRANT_LOCAL", sql)


if __name__ == "__main__":
    unittest.main()
