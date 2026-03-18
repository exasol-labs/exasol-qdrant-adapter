"""Unit tests for create_collection.py — mocks qdrant_client and sentence-transformers."""

import sys
import os
import unittest
from unittest.mock import MagicMock, patch

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'exasol_udfs'))

import create_collection


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _make_ctx(host='localhost', port=6333, api_key='',
              collection='test_col', vector_size=1536,
              distance='Cosine', model_name=''):
    ctx = MagicMock()
    ctx.host        = host
    ctx.port        = port
    ctx.api_key     = api_key
    ctx.collection  = collection
    ctx.vector_size = vector_size
    ctx.distance    = distance
    ctx.model_name  = model_name
    return ctx


# ---------------------------------------------------------------------------
# Tests: collection does not exist → created
# ---------------------------------------------------------------------------

class TestCollectionCreated(unittest.TestCase):

    @patch('create_collection.QdrantClient')
    def test_creates_collection_when_not_exists(self, MockQdrant):
        mock_client = MockQdrant.return_value
        mock_client.get_collections.return_value.collections = []  # empty

        ctx = _make_ctx()
        create_collection.run(ctx)

        mock_client.create_collection.assert_called_once()
        ctx.emit.assert_called_once_with('created: test_col')

    @patch('create_collection.QdrantClient')
    def test_uses_correct_distance_and_size(self, MockQdrant):
        from qdrant_client.models import Distance, VectorParams

        mock_client = MockQdrant.return_value
        mock_client.get_collections.return_value.collections = []

        ctx = _make_ctx(vector_size=768, distance='Euclid')
        create_collection.run(ctx)

        call_kwargs = mock_client.create_collection.call_args.kwargs
        self.assertEqual(call_kwargs['collection_name'], 'test_col')
        self.assertEqual(call_kwargs['vectors_config'].size, 768)
        self.assertEqual(call_kwargs['vectors_config'].distance, Distance.EUCLID)


# ---------------------------------------------------------------------------
# Tests: collection already exists
# ---------------------------------------------------------------------------

class TestCollectionExists(unittest.TestCase):

    @patch('create_collection.QdrantClient')
    def test_returns_exists_when_collection_present(self, MockQdrant):
        mock_client = MockQdrant.return_value
        existing = MagicMock()
        existing.name = 'test_col'
        mock_client.get_collections.return_value.collections = [existing]

        ctx = _make_ctx()
        create_collection.run(ctx)

        mock_client.create_collection.assert_not_called()
        ctx.emit.assert_called_once_with('exists: test_col')


# ---------------------------------------------------------------------------
# Tests: invalid distance metric
# ---------------------------------------------------------------------------

class TestInvalidDistance(unittest.TestCase):

    def test_raises_on_unknown_distance(self):
        ctx = _make_ctx(distance='L2_norm')
        with self.assertRaises(ValueError) as exc_ctx:
            create_collection.run(ctx)
        self.assertIn('Invalid distance metric', str(exc_ctx.exception))
        self.assertIn('Cosine', str(exc_ctx.exception))


# ---------------------------------------------------------------------------
# Tests: vector size inference
# ---------------------------------------------------------------------------

class TestVectorSizeInference(unittest.TestCase):

    @patch('create_collection.QdrantClient')
    def test_infers_size_for_openai_model(self, MockQdrant):
        mock_client = MockQdrant.return_value
        mock_client.get_collections.return_value.collections = []

        ctx = _make_ctx(vector_size=None, model_name='text-embedding-3-small')
        create_collection.run(ctx)

        call_kwargs = mock_client.create_collection.call_args.kwargs
        self.assertEqual(call_kwargs['vectors_config'].size, 1536)

    @patch('create_collection.QdrantClient')
    def test_infers_size_via_sentence_transformers(self, MockQdrant):
        mock_client = MockQdrant.return_value
        mock_client.get_collections.return_value.collections = []

        mock_st_model = MagicMock()
        mock_st_model.get_sentence_embedding_dimension.return_value = 512

        with patch('create_collection.SentenceTransformer', return_value=mock_st_model):
            ctx = _make_ctx(vector_size=None, model_name='some-unknown-model')
            create_collection.run(ctx)

        call_kwargs = mock_client.create_collection.call_args.kwargs
        self.assertEqual(call_kwargs['vectors_config'].size, 512)

    def test_raises_when_no_size_and_unknown_model(self):
        ctx = _make_ctx(vector_size=None, model_name='not-a-real-model-xyz')
        with patch('create_collection.SentenceTransformer', side_effect=Exception('not found')):
            with self.assertRaises(ValueError) as exc_ctx:
                create_collection.run(ctx)
        self.assertIn('explicit vector_size', str(exc_ctx.exception))

    def test_raises_when_no_size_and_no_model(self):
        ctx = _make_ctx(vector_size=None, model_name='')
        with self.assertRaises(ValueError) as exc_ctx:
            create_collection.run(ctx)
        self.assertIn('no model_name', str(exc_ctx.exception))


# ---------------------------------------------------------------------------
# Tests: Qdrant connection failure
# ---------------------------------------------------------------------------

class TestConnectionFailure(unittest.TestCase):

    @patch('create_collection.QdrantClient')
    def test_propagates_connection_error(self, MockQdrant):
        MockQdrant.side_effect = Exception('Connection refused')

        ctx = _make_ctx()
        with self.assertRaises(Exception) as exc_ctx:
            create_collection.run(ctx)
        self.assertIn('Connection refused', str(exc_ctx.exception))


if __name__ == '__main__':
    unittest.main()
