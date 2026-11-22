import os
from pathlib import Path
import unittest
import wave
import numpy as np
from gender_classifier import GenderClassifier, decision

class DecisionChecks(unittest.TestCase):
    def test_confident_and_ambiguous(self):
        self.assertEqual(decision([7, 0, -2])[0], 'female')
        self.assertEqual(decision([0, 7, -2])[0], 'male')
        self.assertIsNone(decision([2, 2, -2])[0])
        self.assertIsNone(decision([0, 0, 7])[0])
        self.assertIsNone(decision([float('nan'), 0, 0])[0])

@unittest.skipUnless(os.environ.get('GENDER_TEST_AUDIO_DIR'), 'Set GENDER_TEST_AUDIO_DIR for real model tests')
class ModelChecks(unittest.TestCase):
    @classmethod
    def setUpClass(cls): cls.model = GenderClassifier(Path(__file__).parent)
    def audio(self, name):
        with wave.open(str(Path(os.environ['GENDER_TEST_AUDIO_DIR']) / (name + '.wav'))) as source:
            self.assertEqual(source.getframerate(), 16000)
            samples = np.frombuffer(source.readframes(source.getnframes()), dtype='<i2').astype(np.float32) / 32768
        return samples[1600:40000]
    def test_different_english_voices(self):
        for name, expected in [('a1', 'female'), ('a2', 'female'), ('b1', 'male')]:
            result = self.model.classify(self.audio(name))
            print(name, result)
            self.assertEqual(result['label'], expected)
    def test_short_speech(self):
        for seconds in [.8, .9]:
            result = self.model.classify(self.audio('b1')[:int(seconds * 16000)])
            self.assertEqual(result['label'], 'male')
            self.assertEqual(result['reason'], 'classified_short')
        for name in ['a1', 'a2']:
            result = self.model.classify(self.audio(name)[:14400])
            self.assertIn(result['label'], [None, 'female'], 'Uncertain female speech must not be forced to male')

    def test_quiet_speech_and_background_noise(self):
        for name, expected in [('a1', 'female'), ('b1', 'male')]:
            result = self.model.classify(self.audio(name) * .01)
            print('quiet', name, result)
            self.assertEqual(result['label'], expected)
        noise = np.random.default_rng(42).normal(0, .0001, 40000).astype(np.float32)
        self.assertIsNone(self.model.classify(noise)['label'])

    def test_mixed_voices(self):
        mixed = np.concatenate([self.audio('a1')[:30400], self.audio('b1')[:30400]])
        result = self.model.classify(mixed)
        print('mixed', result)
        self.assertIsNone(result['label'])

    def test_no_speech_and_invalid(self):
        self.assertEqual(self.model.classify(np.zeros(40000, dtype=np.float32))['reason'], 'silence')
        self.assertIsNone(self.model.classify(self.audio('a1')[:8000])['label'])
        with self.assertRaises(ValueError): self.model.classify(np.full(16000, np.nan, dtype=np.float32))
        with self.assertRaises(ValueError): self.model.classify(np.zeros(80000, dtype=np.float32))

if __name__ == '__main__': unittest.main()
