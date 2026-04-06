"""Test: Topic 14 - SCORE filtering"""
class TestTopic14:
    def test_score_filtering_works(self):
        """
        SQL: SELECT "ID", "TEXT", "SCORE" FROM vector_schema.bank_failures WHERE "QUERY" = 'banks in New York' AND "SCORE" > 0.6 LIMIT 5
        PASS_IF: All returned rows have SCORE > 0.6
        """
        pass
    def test_score_filtering_documented(self):
        """
        FILE: README.md
        CHECK: Contains "SCORE filtering"
        PASS_IF: Found
        """
        pass
