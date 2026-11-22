"""Routing safeguards and actual GTCRN clip isolation/latency checks."""
from pathlib import Path
import threading
import time
import unittest
import numpy as np
from gender_classifier import GenderClassifier
from speech_enhancer import SpeechEnhancer


def verdict(label=None, reason='uncertain_voice'):
    return dict(label=label, reason=reason, score=.99 if label else .5, speechSeconds=1.5, analysisMS=0)


class RoutingChecks(unittest.TestCase):
    def route(self, raw, clean, fail=False):
        class Enhancer:
            def enhance(self, samples):
                if fail: raise RuntimeError('Model failed')
                return samples
        classifier = GenderClassifier.__new__(GenderClassifier)
        classifier.lock = threading.RLock()
        classifier.enhancer = Enhancer()
        outcomes = iter([raw, clean])
        classifier._classify = lambda samples: next(outcomes)
        return classifier.classify(np.zeros(24000, dtype=np.float32))

    def test_recovers_only_from_new_evidence(self):
        result = self.route(verdict(), verdict('male', 'classified'))
        self.assertEqual(result['label'], 'male')
        self.assertIsNone(result['rawLabel'])
        self.assertEqual(result['cleanLabel'], 'male')

    def test_conflict_and_mixed_are_unknown(self):
        for raw, clean, reason in [(verdict('male'), verdict('female'), 'enhancement_conflict'),
                                   (verdict(None, 'mixed_voices'), verdict('male'), 'mixed_voices'),
                                   (verdict('male'), verdict(None, 'mixed_voices'), 'mixed_voices')]:
            result = self.route(raw, clean)
            self.assertIsNone(result['label'])
            self.assertEqual(result['reason'], reason)

    def test_enhancement_does_not_drop_existing_decision(self):
        self.assertEqual(self.route(verdict('female'), verdict())['label'], 'female')
        self.assertIsNone(self.route(verdict(), verdict())['label'])
        failed = self.route(verdict('male'), verdict(), fail=True)
        self.assertEqual(failed['label'], 'male')
        self.assertEqual(failed['enhancement'], 'error')

    def test_silence_skips_enhancement(self):
        self.assertEqual(self.route(verdict(None, 'silence'), verdict('male'))['enhancement'], 'skipped_silence')


class ModelChecks(unittest.TestCase):
    @unittest.skipUnless((Path(__file__).parent / 'gtcrn_simple.onnx').exists(), 'GTCRN model not installed')
    def test_independent_clips_are_finite_and_repeatable(self):
        model = SpeechEnhancer(Path(__file__).parent)
        signal = np.random.default_rng(42).normal(0, .01, 40000).astype(np.float32)
        started = time.monotonic()
        first = model.enhance(signal)
        model.enhance(np.zeros_like(signal))
        second = model.enhance(signal)
        np.testing.assert_allclose(first, second, atol=1e-6)
        self.assertTrue(np.isfinite(first).all())
        self.assertLessEqual(abs(len(first) - len(signal)), 512)
        print('GTCRN: three 2.5s clips in %.3fs' % (time.monotonic() - started))


if __name__ == '__main__': unittest.main()
