"""Unit tests for embed_and_push.py — uses stdlib urllib (no qdrant_client, no openai SDK)."""

import sys
import os
import json
import unittest
from unittest.mock import MagicMock, patch

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


def _mock_openai_response(vectors):
    """Create a mock urllib response for OpenAI embeddings API."""
    body = json.dumps({
        "data": [{"embedding": v} for v in vectors]
    }).encode()
    resp = MagicMock()
    resp.read.return_value = body
    resp.__enter__ = MagicMock(return_value=resp)
    resp.__exit__ = MagicMock(return_value=False)
    return resp


def _mock_qdrant_upsert_response():
    """Create a mock urllib response for Qdrant upsert."""
    body = json.dumps({"result": True, "status": "ok"}).encode()
    resp = MagicMock()
    resp.read.return_value = body
    resp.__enter__ = MagicMock(return_value=resp)
    resp.__exit__ = MagicMock(return_value=False)
    return resp


# ---------------------------------------------------------------------------
# Tests: OpenAI embedding
# ---------------------------------------------------------------------------

class TestEmbedOpenAI(unittest.TestCase):

    @patch('urllib.request.urlopen')
    def test_embed_openai_returns_vectors(self, mock_urlopen):
        mock_urlopen.return_value = _mock_openai_response([[0.1, 0.2], [0.3, 0.4]])

        result = embed_and_push._openai_embed(['hello', 'world'], 'sk-test', 'text-embedding-3-small')

        self.assertEqual(result, [[0.1, 0.2], [0.3, 0.4]])

    @patch('embed_and_push.time.sleep')
    @patch('urllib.request.urlopen')
    def test_embed_openai_retries_on_rate_limit(self, mock_urlopen, mock_sleep):
        import urllib.error

        rate_limit_resp = MagicMock()
        rate_limit_resp.code = 429
        rate_limit_resp.read.return_value = b'rate limited'

        mock_urlopen.side_effect = [
            urllib.error.HTTPError(url='', code=429, msg='', hdrs=None,
                                  fp=MagicMock(read=MagicMock(return_value=b'rate limited'))),
            urllib.error.HTTPError(url='', code=429, msg='', hdrs=None,
                                  fp=MagicMock(read=MagicMock(return_value=b'rate limited'))),
            _mock_openai_response([[0.5]]),
        ]

        result = embed_and_push._openai_embed(['text'], 'sk-test', 'text-embedding-3-small')
        self.assertEqual(result, [[0.5]])
        self.assertEqual(mock_sleep.call_count, 2)

    @patch('urllib.request.urlopen')
    def test_embed_openai_raises_after_max_retries(self, mock_urlopen):
        import urllib.error

        mock_urlopen.side_effect = urllib.error.HTTPError(
            url='', code=429, msg='', hdrs=None,
            fp=MagicMock(read=MagicMock(return_value=b'rate limited'))
        )

        with self.assertRaises(RuntimeError) as ctx:
            embed_and_push._openai_embed(['text'], 'sk-test', 'text-embedding-3-small')

        # On max retries, it raises with the HTTP error (429)
        self.assertIn('429', str(ctx.exception))


# ---------------------------------------------------------------------------
# Tests: UUID generation
# ---------------------------------------------------------------------------

class TestTextToUuid(unittest.TestCase):

    def test_stable_uuid(self):
        uuid1 = embed_and_push._text_to_uuid('doc-1')
        uuid2 = embed_and_push._text_to_uuid('doc-1')
        self.assertEqual(uuid1, uuid2)

    def test_different_ids_different_uuids(self):
        uuid1 = embed_and_push._text_to_uuid('doc-1')
        uuid2 = embed_and_push._text_to_uuid('doc-2')
        self.assertNotEqual(uuid1, uuid2)


# ---------------------------------------------------------------------------
# Tests: run() orchestration
# ---------------------------------------------------------------------------

class TestRun(unittest.TestCase):

    @patch('urllib.request.urlopen')
    def test_run_batches_and_emits(self, mock_urlopen):
        rows = [(f'id-{i}', f'text {i}') for i in range(5)]
        ctx = _make_ctx(rows)

        # First call: OpenAI embed, second call: Qdrant upsert
        mock_urlopen.side_effect = [
            _mock_openai_response([[float(i)] * 3 for i in range(5)]),
            _mock_qdrant_upsert_response(),
        ]

        embed_and_push.run(ctx)

        ctx.emit.assert_called_once()
        _, upserted = ctx.emit.call_args[0]
        self.assertEqual(upserted, 5)

    @patch('urllib.request.urlopen')
    def test_run_splits_into_multiple_batches(self, mock_urlopen):
        rows = [(f'id-{i}', f'text {i}') for i in range(250)]
        ctx = _make_ctx(rows)

        # 3 batches: embed+upsert for each
        responses = []
        for batch_size in [100, 100, 50]:
            responses.append(_mock_openai_response([[0.1] * 3] * batch_size))
            responses.append(_mock_qdrant_upsert_response())
        mock_urlopen.side_effect = responses

        embed_and_push.run(ctx)

        _, upserted = ctx.emit.call_args[0]
        self.assertEqual(upserted, 250)

    @patch('urllib.request.urlopen')
    def test_run_raises_on_qdrant_error(self, mock_urlopen):
        import urllib.error

        rows = [('id-1', 'text')]
        ctx = _make_ctx(rows)

        mock_urlopen.side_effect = [
            _mock_openai_response([[0.1]]),
            urllib.error.HTTPError(url='', code=500, msg='', hdrs=None,
                                  fp=MagicMock(read=MagicMock(return_value=b'server error'))),
        ]

        with self.assertRaises(RuntimeError) as exc_ctx:
            embed_and_push.run(ctx)

        self.assertIn('Qdrant', str(exc_ctx.exception))

    def test_run_rejects_unsupported_provider(self):
        rows = [('id-1', 'text')]
        ctx = _make_ctx(rows, provider='local')

        with self.assertRaises(ValueError) as exc_ctx:
            embed_and_push.run(ctx)

        self.assertIn('Unsupported provider', str(exc_ctx.exception))


if __name__ == '__main__':
    unittest.main()
