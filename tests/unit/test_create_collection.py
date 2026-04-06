"""Unit tests for create_collection.py — uses stdlib urllib (no qdrant_client)."""

import sys
import os
import json
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


def _mock_qdrant_response(collections=None):
    """Create a mock urllib response for GET /collections."""
    if collections is None:
        collections = []
    body = json.dumps({
        "result": {"collections": [{"name": c} for c in collections]},
        "status": "ok"
    }).encode()
    resp = MagicMock()
    resp.read.return_value = body
    resp.__enter__ = MagicMock(return_value=resp)
    resp.__exit__ = MagicMock(return_value=False)
    return resp


def _mock_create_response():
    """Create a mock urllib response for PUT /collections/<name>."""
    body = json.dumps({"result": True, "status": "ok"}).encode()
    resp = MagicMock()
    resp.read.return_value = body
    resp.__enter__ = MagicMock(return_value=resp)
    resp.__exit__ = MagicMock(return_value=False)
    return resp


# ---------------------------------------------------------------------------
# Tests: collection does not exist -> created
# ---------------------------------------------------------------------------

class TestCollectionCreated(unittest.TestCase):

    @patch('urllib.request.urlopen')
    def test_creates_collection_when_not_exists(self, mock_urlopen):
        # First call: GET /collections -> empty
        # Second call: PUT /collections/test_col -> ok
        mock_urlopen.side_effect = [
            _mock_qdrant_response([]),
            _mock_create_response()
        ]

        ctx = _make_ctx()
        result = create_collection.run(ctx)

        self.assertEqual(result, 'created: test_col')
        self.assertEqual(mock_urlopen.call_count, 2)


# ---------------------------------------------------------------------------
# Tests: collection already exists
# ---------------------------------------------------------------------------

class TestCollectionExists(unittest.TestCase):

    @patch('urllib.request.urlopen')
    def test_returns_exists_when_collection_present(self, mock_urlopen):
        mock_urlopen.return_value = _mock_qdrant_response(['test_col'])

        ctx = _make_ctx()
        result = create_collection.run(ctx)

        self.assertEqual(result, 'exists: test_col')
        # Only one call (GET /collections), no PUT
        mock_urlopen.assert_called_once()


# ---------------------------------------------------------------------------
# Tests: invalid distance metric
# ---------------------------------------------------------------------------

class TestInvalidDistance(unittest.TestCase):

    def test_raises_on_unknown_distance(self):
        ctx = _make_ctx(distance='L2_norm')
        with self.assertRaises(ValueError) as exc_ctx:
            create_collection.run(ctx)
        self.assertIn('Invalid distance', str(exc_ctx.exception))
        self.assertIn('Cosine', str(exc_ctx.exception))


# ---------------------------------------------------------------------------
# Tests: vector size inference
# ---------------------------------------------------------------------------

class TestVectorSizeInference(unittest.TestCase):

    @patch('urllib.request.urlopen')
    def test_infers_size_for_known_model(self, mock_urlopen):
        mock_urlopen.side_effect = [
            _mock_qdrant_response([]),
            _mock_create_response()
        ]

        ctx = _make_ctx(vector_size=None, model_name='nomic-embed-text')
        result = create_collection.run(ctx)

        self.assertEqual(result, 'created: test_col')

    def test_raises_when_no_size_and_unknown_model(self):
        ctx = _make_ctx(vector_size=None, model_name='not-a-real-model-xyz')
        with self.assertRaises(ValueError) as exc_ctx:
            create_collection.run(ctx)
        self.assertIn('explicit vector_size', str(exc_ctx.exception))

    def test_raises_when_no_size_and_no_model(self):
        ctx = _make_ctx(vector_size=None, model_name='')
        with self.assertRaises(ValueError) as exc_ctx:
            create_collection.run(ctx)
        self.assertIn('no model_name', str(exc_ctx.exception))


# ---------------------------------------------------------------------------
# Tests: connection failure
# ---------------------------------------------------------------------------

class TestConnectionFailure(unittest.TestCase):

    @patch('urllib.request.urlopen')
    def test_propagates_connection_error(self, mock_urlopen):
        import urllib.error
        mock_urlopen.side_effect = urllib.error.URLError('Connection refused')

        ctx = _make_ctx()
        with self.assertRaises((RuntimeError, urllib.error.URLError)) as exc_ctx:
            create_collection.run(ctx)
        self.assertIn('Connection refused', str(exc_ctx.exception))


if __name__ == '__main__':
    unittest.main()
