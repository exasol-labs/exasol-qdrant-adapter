"""
Integration tests for the UDF ingestion pipeline.

Requires a running Qdrant instance (default: localhost:6333).
Start one with:
    docker run -d --name qdrant -p 6333:6333 qdrant/qdrant

Run tests with:
    pytest tests/integration/test_udf_ingestion.py -v

Environment variables:
    QDRANT_HOST      (default: localhost)
    QDRANT_PORT      (default: 6333)
    QDRANT_API_KEY   (default: '')
    OPENAI_API_KEY   (required for OpenAI tests; set to 'skip' to skip them)
"""

import os
import sys
import uuid
import unittest
from unittest.mock import MagicMock

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'exasol_udfs'))

QDRANT_HOST    = os.environ.get('QDRANT_HOST', 'localhost')
QDRANT_PORT    = int(os.environ.get('QDRANT_PORT', '6333'))
QDRANT_API_KEY = os.environ.get('QDRANT_API_KEY', '')
OPENAI_KEY     = os.environ.get('OPENAI_API_KEY', 'skip')

TEST_COLLECTION = f"udf_integration_test_{uuid.uuid4().hex[:8]}"


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _make_ctx(rows, **kwargs):
    """Build a minimal mock ExaContext."""
    defaults = dict(
        qdrant_host=QDRANT_HOST,
        qdrant_port=QDRANT_PORT,
        qdrant_api_key=QDRANT_API_KEY,
        collection=TEST_COLLECTION,
        provider='local',
        embedding_key='',
        model_name='all-MiniLM-L6-v2',
    )
    defaults.update(kwargs)

    ctx = MagicMock()
    for k, v in defaults.items():
        setattr(ctx, k, v)

    row_iter = iter(rows)
    first = next(row_iter)
    ctx.id       = first[0]
    ctx.text_col = first[1]

    remaining = list(row_iter)

    def _next():
        if not remaining:
            return False
        row = remaining.pop(0)
        ctx.id       = row[0]
        ctx.text_col = row[1]
        return True

    ctx.next.side_effect = _next
    return ctx


def _qdrant_client():
    from qdrant_client import QdrantClient
    return QdrantClient(host=QDRANT_HOST, port=QDRANT_PORT,
                        api_key=QDRANT_API_KEY or None, https=False)


# ---------------------------------------------------------------------------
# Setup / teardown
# ---------------------------------------------------------------------------

class IntegrationBase(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        """Create the test collection."""
        import create_collection

        ctx = MagicMock()
        ctx.host        = QDRANT_HOST
        ctx.port        = QDRANT_PORT
        ctx.api_key     = QDRANT_API_KEY
        ctx.collection  = TEST_COLLECTION
        ctx.vector_size = 384          # all-MiniLM-L6-v2 dimension
        ctx.distance    = 'Cosine'
        ctx.model_name  = ''
        create_collection.run(ctx)

    @classmethod
    def tearDownClass(cls):
        """Delete the test collection."""
        try:
            _qdrant_client().delete_collection(TEST_COLLECTION)
        except Exception:
            pass


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

class TestCreateCollectionIntegration(unittest.TestCase):

    def test_create_and_verify_collection(self):
        import create_collection

        col = f"int_test_col_{uuid.uuid4().hex[:6]}"
        ctx = MagicMock()
        ctx.host        = QDRANT_HOST
        ctx.port        = QDRANT_PORT
        ctx.api_key     = QDRANT_API_KEY
        ctx.collection  = col
        ctx.vector_size = 64
        ctx.distance    = 'Dot'
        ctx.model_name  = ''

        try:
            create_collection.run(ctx)
            ctx.emit.assert_called_once_with(f'created: {col}')

            # Second call → exists
            ctx.emit.reset_mock()
            create_collection.run(ctx)
            ctx.emit.assert_called_once_with(f'exists: {col}')
        finally:
            try:
                _qdrant_client().delete_collection(col)
            except Exception:
                pass


class TestEmbedAndPushLocalIntegration(IntegrationBase):

    def test_ingests_rows_with_local_model(self):
        import embed_and_push

        rows = [
            ('doc-1', 'Machine learning is a subset of artificial intelligence'),
            ('doc-2', 'The Eiffel Tower is located in Paris'),
            ('doc-3', 'Python is a popular programming language'),
        ]
        ctx = _make_ctx(rows)
        embed_and_push.run(ctx)

        ctx.emit.assert_called_once()
        _, count = ctx.emit.call_args[0]
        self.assertEqual(count, 3)

        # Verify points exist in Qdrant
        client = _qdrant_client()
        results, _ = client.scroll(
            collection_name=TEST_COLLECTION,
            limit=10,
            with_payload=True,
        )
        found_ids = {p.payload.get('id') for p in results}
        self.assertIn('doc-1', found_ids)
        self.assertIn('doc-2', found_ids)
        self.assertIn('doc-3', found_ids)

    def test_upsert_overwrites_existing_point(self):
        import embed_and_push

        rows = [('doc-1', 'Updated text for doc-1')]
        ctx = _make_ctx(rows)
        embed_and_push.run(ctx)

        client = _qdrant_client()
        results, _ = client.scroll(
            collection_name=TEST_COLLECTION,
            scroll_filter=None,
            limit=100,
            with_payload=True,
        )
        doc1 = next((p for p in results if p.payload.get('id') == 'doc-1'), None)
        self.assertIsNotNone(doc1)
        self.assertEqual(doc1.payload['text'], 'Updated text for doc-1')

    def test_ingests_more_than_batch_size(self):
        import embed_and_push

        rows = [(f'bulk-{i}', f'Document number {i} with some text') for i in range(150)]
        ctx = _make_ctx(rows)
        embed_and_push.run(ctx)

        _, count = ctx.emit.call_args[0]
        self.assertEqual(count, 150)


@unittest.skipIf(OPENAI_KEY == 'skip', 'OPENAI_API_KEY not set — skipping OpenAI integration tests')
class TestEmbedAndPushOpenAIIntegration(IntegrationBase):

    def test_ingests_rows_with_openai(self):
        import embed_and_push

        # Need a collection with the right OpenAI dimension (1536)
        openai_col = f"openai_int_{uuid.uuid4().hex[:6]}"
        import create_collection

        col_ctx = MagicMock()
        col_ctx.host        = QDRANT_HOST
        col_ctx.port        = QDRANT_PORT
        col_ctx.api_key     = QDRANT_API_KEY
        col_ctx.collection  = openai_col
        col_ctx.vector_size = None
        col_ctx.distance    = 'Cosine'
        col_ctx.model_name  = 'text-embedding-3-small'
        create_collection.run(col_ctx)

        try:
            rows = [('oa-1', 'Semantic search enables meaning-based retrieval')]
            ctx = _make_ctx(rows, collection=openai_col,
                            provider='openai', embedding_key=OPENAI_KEY,
                            model_name='text-embedding-3-small')
            embed_and_push.run(ctx)

            _, count = ctx.emit.call_args[0]
            self.assertEqual(count, 1)
        finally:
            try:
                _qdrant_client().delete_collection(openai_col)
            except Exception:
                pass


if __name__ == '__main__':
    unittest.main()
