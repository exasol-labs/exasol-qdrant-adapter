"""Unit tests for embed_text.py — scalar UDF that returns JSON-encoded vectors.

The real `sentence_transformers.SentenceTransformer` is replaced with a stub
before `embed_text` is imported, so the test does not require the SLC, the
BucketFS model, or any HuggingFace download.
"""

import importlib
import json
import math
import os
import sys
import types
import unittest
from unittest.mock import MagicMock


def _install_fake_sentence_transformers():
    """Inject a stub `sentence_transformers` module into sys.modules.

    The stub records each call and returns a deterministic 768-dim L2-normalised
    vector — enough to exercise the scalar UDF without the real ~250 MB model.
    """
    fake_module = types.ModuleType("sentence_transformers")

    class FakeSentenceTransformer:
        instances_created = 0

        def __init__(self, path, device="cpu", trust_remote_code=False):
            FakeSentenceTransformer.instances_created += 1
            self.path = path
            self.device = device
            self.encode_calls = []

        def encode(self, text, normalize_embeddings=True, convert_to_numpy=True):
            self.encode_calls.append((text, normalize_embeddings))
            # Build a 768-dim vector with L2 norm = 1.0. Place 1.0 in slot
            # `len(text) % 768` so different inputs produce different vectors.
            n = 768
            slot = len(text) % n
            vec = [0.0] * n
            vec[slot] = 1.0
            return _FakeNumpyArray(vec)

    fake_module.SentenceTransformer = FakeSentenceTransformer
    sys.modules["sentence_transformers"] = fake_module
    return FakeSentenceTransformer


class _FakeNumpyArray:
    """Minimal stand-in for numpy.ndarray with .tolist()."""
    def __init__(self, values):
        self._values = list(values)

    def tolist(self):
        return list(self._values)


def _import_embed_text_fresh():
    """Re-import embed_text against the current sys.modules."""
    sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'exasol_udfs'))
    if "embed_text" in sys.modules:
        del sys.modules["embed_text"]
    return importlib.import_module("embed_text")


class TestEmbedText(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        cls.fake_st = _install_fake_sentence_transformers()
        # Reset counter — the module-level constructor call below should be
        # the only one we count for the "loaded once" assertion.
        cls.fake_st.instances_created = 0
        cls.embed_text = _import_embed_text_fresh()

    def _ctx(self, text):
        ctx = MagicMock()
        ctx.text = text
        return ctx

    def test_null_input_returns_none(self):
        self.assertIsNone(self.embed_text.run(self._ctx(None)))

    def test_empty_string_returns_none(self):
        self.assertIsNone(self.embed_text.run(self._ctx("")))

    def test_normal_text_returns_768_float_json_array(self):
        result = self.embed_text.run(self._ctx("banks acquired by JP Morgan"))
        self.assertIsInstance(result, str)
        parsed = json.loads(result)
        self.assertIsInstance(parsed, list)
        self.assertEqual(len(parsed), 768)
        for v in parsed:
            self.assertIsInstance(v, float)

    def test_returned_vector_is_l2_normalised(self):
        result = self.embed_text.run(self._ctx("hello world"))
        vec = json.loads(result)
        norm = math.sqrt(sum(v * v for v in vec))
        self.assertAlmostEqual(norm, 1.0, places=6)

    def test_long_input_truncated_to_max_chars(self):
        long_text = "x" * (self.embed_text.MAX_CHARS + 5000)
        self.embed_text.run(self._ctx(long_text))
        # Last call must be at most MAX_CHARS in length.
        encoded_text, _ = self.embed_text._model.encode_calls[-1]
        self.assertLessEqual(len(encoded_text), self.embed_text.MAX_CHARS)
        self.assertEqual(len(encoded_text), self.embed_text.MAX_CHARS)

    def test_normalize_embeddings_flag_is_true(self):
        self.embed_text.run(self._ctx("normalisation flag"))
        _, normalize_flag = self.embed_text._model.encode_calls[-1]
        self.assertTrue(normalize_flag)

    def test_model_loaded_exactly_once(self):
        # Run multiple invocations and verify the constructor was called once
        # at module import — no further constructions per row.
        for text in ("first", "second", "third", "fourth"):
            self.embed_text.run(self._ctx(text))
        self.assertEqual(self.fake_st.instances_created, 1)


if __name__ == "__main__":
    unittest.main()
