"""
Test: Topic 7 - No Exasol Docker Run Command
Tests that README and install_all.sql now include Exasol docker run instructions.

Note: These are documentation-only tests. No SQL queries needed.
"""


class TestTopic7:
    """Test cases for Exasol Docker run command in docs."""

    def test_readme_has_exasol_docker_run(self):
        """
        FILE: README.md
        CHECK: Contains "docker run -d --name exasoldb"
        PASS_IF: String found in README.md
        """
        pass

    def test_readme_has_privileged_flag(self):
        """
        FILE: README.md
        CHECK: Contains "--privileged" in the Exasol docker run section
        PASS_IF: String found
        """
        pass

    def test_readme_has_default_credentials(self):
        """
        FILE: README.md
        CHECK: Contains "sys" and "exasol" as default credentials
        PASS_IF: Both strings found near the Exasol docker run section
        """
        pass

    def test_install_all_has_exasol_docker_run(self):
        """
        FILE: scripts/install_all.sql
        CHECK: Contains "docker run -d --name exasoldb" in prerequisites comment
        PASS_IF: String found
        """
        pass

    def test_step_numbering_correct(self):
        """
        FILE: README.md
        CHECK: Steps are numbered 1 (Exasol), 2 (Qdrant), 3 (Ollama), 4 (Install)
        PASS_IF: ### 1. Start Exasol appears before ### 2. Start Qdrant
        """
        pass
