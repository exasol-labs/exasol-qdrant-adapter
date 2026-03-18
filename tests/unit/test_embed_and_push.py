"""Unit tests for embed_and_push.py — mocks OpenAI, sentence-transformers, and Qdrant."""

import sys
import os
import types
import unittest
from unittest.mock import MagicMock, patch, call

# Make the exasol_udfs package importable without installing
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'exasol_udfs'))

import embed_and_push


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _make_ctx(rows, qdrant_host='localhost', qdrant_port=6333,
              qdrant_api_key='', collection='test_col',
              provider='openai', embedding_key='sk-test',
              model_name='text-embedding-3-small'):
    """Build a minimal mock ExaContext that yields the given rows."""
    ctx = MagicMock()
    ctx.qdrant_host    = qdrant_host
    ctx.qdrant_port    = qdrant_port
    ctx.qdrant_api_key = qdrant_api_key
    ctx.collection     = collection
    ctx.provider       = provider
    ctx.embedding_key  = embedding_key
    ctx.model_name     = model_name

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


# ---------------------------------------------------------------------------
# Tests: OpenAI embedding provider
# ---------------------------------------------------------------------------

class TestEmbedOpenAI(unittest.TestCase):

    @patch('embed_and_push.OpenAI')
    def test_embed_openai_returns_vectors(self, MockOpenAI):
        fake_response = MagicMock()
        fake_response.data = [MagicMock(embedding=[0.1, 0.2]), MagicMock(embedding=[0.3, 0.4])]
        MockOpenAI.return_value.embeddings.create.return_value = fake_response

        result = embed_and_push._embed_openai(['hello', 'world'], 'sk-test', 'text-embedding-3-small')

        self.assertEqual(result, [[0.1, 0.2], [0.3, 0.4]])
        MockOpenAI.return_value.embeddings.create.assert_called_once_with(
            input=['hello', 'world'], model='text-embedding-3-small'
        )

    @patch('embed_and_push.time.sleep')
    @patch('embed_and_push.OpenAI')
    def test_embed_openai_retries_on_rate_limit(self, MockOpenAI, mock_sleep):
        from openai import RateLimitError

        fake_response = MagicMock()
        fake_response.data = [MagicMock(embedding=[0.5])]

        # Fail twice, then succeed
        MockOpenAI.return_value.embeddings.create.side_effect = [
            RateLimitError('rate limited', response=MagicMock(), body={}),
            RateLimitError('rate limited', response=MagicMock(), body={}),
            fake_response,
        ]

        result = embed_and_push._embed_openai(['text'], 'sk-test', 'text-embedding-3-small')
        self.assertEqual(result, [[0.5]])
        self.assertEqual(mock_sleep.call_count, 2)

    @patch('embed_and_push.OpenAI')
    def test_embed_openai_raises_after_max_retries(self, MockOpenAI):
        from openai import RateLimitError

        MockOpenAI.return_value.embeddings.create.side_effect = RateLimitError(
            'rate limited', response=MagicMock(), body={}
        )

        with self.assertRaises(RuntimeError) as ctx:
            embed_and_push._embed_openai(['text'], 'sk-test', 'text-embedding-3-small')

        self.assertIn('3 attempts', str(ctx.exception))


# ---------------------------------------------------------------------------
# Tests: local sentence-transformers provider
# ---------------------------------------------------------------------------

class TestEmbedLocal(unittest.TestCase):

    def test_embed_local_returns_vectors(self):
        import numpy as np

        mock_model = MagicMock()
        mock_model.encode.return_value = np.array([[0.1, 0.2, 0.3], [0.4, 0.5, 0.6]])

        with patch('embed_and_push.SentenceTransformer', return_value=mock_model):
            result = embed_and_push._embed_local(['a', 'b'], 'all-MiniLM-L6-v2')

        self.assertEqual(result, [[0.1, 0.2, 0.3], [0.4, 0.5, 0.6]])
        mock_model.encode.assert_called_once_with(
            ['a', 'b'], convert_to_numpy=True, show_progress_bar=False
        )


# ---------------------------------------------------------------------------
# Tests: Qdrant upsert logic
# ---------------------------------------------------------------------------

class TestUpsertBatch(unittest.TestCase):

    def test_upsert_batch_calls_client(self):
        mock_client = MagicMock()
        ids     = ['id-1', 'id-2']
        texts   = ['hello', 'world']
        vectors = [[0.1, 0.2], [0.3, 0.4]]

        embed_and_push._upsert_batch(mock_client, 'my_col', ids, texts, vectors)

        mock_client.upsert.assert_called_once()
        args = mock_client.upsert.call_args
        self.assertEqual(args.kwargs['collection_name'], 'my_col')
        points = args.kwargs['points']
        self.assertEqual(len(points), 2)
        self.assertEqual(points[0].payload, {'id': 'id-1', 'text': 'hello'})
        self.assertEqual(points[0].vector, [0.1, 0.2])

    def test_upsert_batch_uses_stable_uuid(self):
        mock_client = MagicMock()
        embed_and_push._upsert_batch(mock_client, 'col', ['doc-1'], ['x'], [[0.0]])
        point_id = mock_client.upsert.call_args.kwargs['points'][0].id
        # Same id should produce same UUID
        self.assertEqual(point_id, embed_and_push._text_to_uuid('doc-1'))


# ---------------------------------------------------------------------------
# Tests: run() orchestration
# ---------------------------------------------------------------------------

class TestRun(unittest.TestCase):

    @patch('embed_and_push.QdrantClient')
    @patch('embed_and_push._generate_embeddings')
    def test_run_batches_and_emits(self, mock_embed, MockQdrant):
        rows = [(f'id-{i}', f'text {i}') for i in range(5)]
        ctx = _make_ctx(rows)
        mock_embed.return_value = [[float(i)] * 3 for i in range(5)]

        embed_and_push.run(ctx)

        # One batch (5 rows < 100)
        mock_embed.assert_called_once()
        MockQdrant.return_value.upsert.assert_called_once()
        ctx.emit.assert_called_once()
        _, upserted = ctx.emit.call_args[0]
        self.assertEqual(upserted, 5)

    @patch('embed_and_push.QdrantClient')
    @patch('embed_and_push._generate_embeddings')
    def test_run_splits_into_multiple_batches(self, mock_embed, MockQdrant):
        rows = [(f'id-{i}', f'text {i}') for i in range(250)]
        ctx = _make_ctx(rows)
        mock_embed.side_effect = lambda texts, *a, **kw: [[0.1] * 3] * len(texts)

        embed_and_push.run(ctx)

        # 250 rows → 3 batches (100+100+50)
        self.assertEqual(mock_embed.call_count, 3)
        _, upserted = ctx.emit.call_args[0]
        self.assertEqual(upserted, 250)

    @patch('embed_and_push.QdrantClient')
    @patch('embed_and_push._generate_embeddings')
    def test_run_raises_on_qdrant_error(self, mock_embed, MockQdrant):
        rows = [('id-1', 'text')]
        ctx = _make_ctx(rows)
        mock_embed.return_value = [[0.1]]
        MockQdrant.return_value.upsert.side_effect = Exception('Qdrant down')

        with self.assertRaises(RuntimeError) as exc_ctx:
            embed_and_push.run(ctx)

        self.assertIn('Qdrant upsert failed', str(exc_ctx.exception))


if __name__ == '__main__':
    unittest.main()
