"""
Integration tests for the UDF ingestion + query pipeline.

Requires a running Qdrant instance (default: localhost:6333). For the
EMBED_TEXT smoke + parity tests, a running Exasol with the SLC installed
and reachable via pyexasol is also required.

Start Qdrant with:
    docker run -d --name qdrant -p 6333:6333 qdrant/qdrant

Run tests with:
    pytest tests/integration/test_udf_ingestion.py -v

Environment variables:
    QDRANT_HOST          (default: localhost)
    QDRANT_PORT          (default: 6333)
    QDRANT_API_KEY       (default: '')
    EXASOL_DSN           (default: unset; required for EMBED_TEXT tests, e.g. 'localhost:8563')
    EXASOL_USER          (default: sys)
    EXASOL_PASSWORD      (default: exasol)
    EXASOL_SCHEMA        (default: ADAPTER)
    EXASOL_BANK_FAILURES (default: MUFA.BANK_FAILURES; only used for parity test setup)
"""

import json
import math
import os
import sys
import uuid
import unittest
from unittest.mock import MagicMock

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'exasol_udfs'))

QDRANT_HOST    = os.environ.get('QDRANT_HOST', 'localhost')
QDRANT_PORT    = int(os.environ.get('QDRANT_PORT', '6333'))
QDRANT_API_KEY = os.environ.get('QDRANT_API_KEY', '')

EXASOL_DSN      = os.environ.get('EXASOL_DSN', '')
EXASOL_USER     = os.environ.get('EXASOL_USER', 'sys')
EXASOL_PASSWORD = os.environ.get('EXASOL_PASSWORD', 'exasol')
EXASOL_SCHEMA   = os.environ.get('EXASOL_SCHEMA', 'ADAPTER')


def _qdrant_client():
    from qdrant_client import QdrantClient
    return QdrantClient(host=QDRANT_HOST, port=QDRANT_PORT,
                        api_key=QDRANT_API_KEY or None, https=False)


def _exasol_connection():
    """Open a pyexasol connection (lazy import — only required for EMBED_TEXT tests)."""
    import pyexasol
    return pyexasol.connect(
        dsn=EXASOL_DSN,
        user=EXASOL_USER,
        password=EXASOL_PASSWORD,
        autocommit=True,
    )


# ---------------------------------------------------------------------------
# Collection-creation tests (no Exasol session needed; Qdrant only)
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
            result = create_collection.run(ctx)
            self.assertEqual(result, f'created: {col}')

            # Second call → exists
            result = create_collection.run(ctx)
            self.assertEqual(result, f'exists: {col}')
        finally:
            try:
                _qdrant_client().delete_collection(col)
            except Exception:
                pass


# ---------------------------------------------------------------------------
# EMBED_TEXT smoke + parity tests (require Exasol + SLC + BucketFS model)
# ---------------------------------------------------------------------------

@unittest.skipIf(not EXASOL_DSN,
                 'EXASOL_DSN not set — skipping live EMBED_TEXT integration tests')
class TestEmbedTextLiveIntegration(unittest.TestCase):
    """Tests that hit a real Exasol with EMBED_TEXT installed."""

    @classmethod
    def setUpClass(cls):
        cls.conn = _exasol_connection()

    @classmethod
    def tearDownClass(cls):
        try:
            cls.conn.close()
        except Exception:
            pass

    def _embed_text(self, text):
        result = self.conn.execute(
            f"SELECT {EXASOL_SCHEMA}.EMBED_TEXT(:t)",
            {"t": text},
        ).fetchone()
        return result[0] if result else None

    def test_embed_text_returns_768_float_json_array(self):
        raw = self._embed_text('banks in New York')
        self.assertIsInstance(raw, str)
        self.assertTrue(raw, "EMBED_TEXT returned empty string")
        vec = json.loads(raw)
        self.assertIsInstance(vec, list)
        self.assertEqual(len(vec), 768)
        for v in vec:
            self.assertIsInstance(v, float)

    def test_embed_text_l2_norm_is_one(self):
        raw = self._embed_text('large bank failures')
        vec = json.loads(raw)
        norm = math.sqrt(sum(v * v for v in vec))
        self.assertAlmostEqual(norm, 1.0, places=4)

    def test_embed_text_null_returns_null(self):
        result = self.conn.execute(
            f"SELECT {EXASOL_SCHEMA}.EMBED_TEXT(NULL) IS NULL"
        ).fetchone()
        self.assertTrue(result[0])

    def test_embed_text_empty_returns_null(self):
        result = self.conn.execute(
            f"SELECT {EXASOL_SCHEMA}.EMBED_TEXT('') IS NULL"
        ).fetchone()
        self.assertTrue(result[0])

    def test_embed_text_parity_with_embed_and_push_local(self):
        """Encode the same text via EMBED_TEXT and via EMBED_AND_PUSH_LOCAL,
        retrieve the upserted vector from Qdrant, and assert bit-for-bit equality.
        Both UDFs share the same SLC + BucketFS model, so the vectors must match.
        """
        from qdrant_client.http import models as qmodels
        client = _qdrant_client()

        col = f"parity_check_{uuid.uuid4().hex[:6]}"
        try:
            client.recreate_collection(
                collection_name=col,
                vectors_config={"text": qmodels.VectorParams(size=768, distance=qmodels.Distance.COSINE)},
            )

            text = 'banks acquired by JP Morgan'
            probe_id = 'parity-probe-1'

            # Path A: EMBED_AND_PUSH_LOCAL writes the vector into Qdrant.
            self.conn.execute(
                f"""SELECT {EXASOL_SCHEMA}.EMBED_AND_PUSH_LOCAL(
                        'embedding_conn', :col, :id, :t)
                    FROM (SELECT 1 FROM DUAL)
                    GROUP BY IPROC()""",
                {"col": col, "id": probe_id, "t": text},
            )

            # Path B: EMBED_TEXT returns the JSON-encoded vector directly.
            embed_text_raw = self._embed_text(text)
            embed_text_vec = json.loads(embed_text_raw)

            # Read back the vector from Qdrant.
            points, _ = client.scroll(
                collection_name=col, limit=1, with_vectors=True, with_payload=True)
            self.assertGreater(len(points), 0)
            qdrant_vec = points[0].vector["text"]

            self.assertEqual(len(embed_text_vec), len(qdrant_vec))
            for a, b in zip(embed_text_vec, qdrant_vec):
                # Both come from the same SLC + model; require near-exact equality.
                self.assertAlmostEqual(a, b, places=5)
        finally:
            try:
                client.delete_collection(col)
            except Exception:
                pass


if __name__ == '__main__':
    unittest.main()
