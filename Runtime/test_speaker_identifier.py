import os
from pathlib import Path
import unittest
import wave
import numpy as np
from speaker_identifier import SpeakerIdentifier, VoiceRegistry


class RegistryChecks(unittest.TestCase):
    def test_same_and_new_voice(self):
        registry = VoiceRegistry()
        self.assertEqual(registry.match([1, 0, 0])[0], "speaker-1")
        self.assertEqual(registry.match([1, 0, 0])[0], "speaker-1")
        self.assertEqual(registry.match([0, 1, 0])[2], "learning_new_voice")
        self.assertEqual(registry.match([0, 1, 0])[0], "speaker-2")
        self.assertIsNone(registry.match([1, 1, 0])[0])
        self.assertEqual(len(registry.profiles), 2)

    def test_invalid_vector(self):
        self.assertIsNone(VoiceRegistry().match([0, 0, 0])[0])


@unittest.skipUnless(os.environ.get("SPEAKER_TEST_AUDIO_DIR"), "Set SPEAKER_TEST_AUDIO_DIR to English a1.wav/a2.wav/b1.wav test fixtures")
class ModelChecks(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.identifier = SpeakerIdentifier(Path(__file__).parent)

    def audio(self, name):
        with wave.open(str(Path(os.environ["SPEAKER_TEST_AUDIO_DIR"]) / (name + ".wav"))) as source:
            self.assertEqual(source.getframerate(), 16000)
            self.assertEqual(source.getnchannels(), 1)
            samples = np.frombuffer(source.readframes(source.getnframes()), dtype="<i2").astype(np.float32) / 32768
        return samples[1600:28800]

    def test_real_english_voices(self):
        # Identification never invents a profile from unlabelled audio.
        self.identifier.enrolled.rows = []
        self.assertIsNone(self.identifier.identify(self.audio("a1"), "test-english")["profileID"])
        store = self.identifier.enrolled
        a = store.edit("add", name="Test A", voice="eugene")
        b = store.edit("add", name="Test B", voice="aidar")
        for key, name in [(a, "a1"), (a, "a2"), (b, "b1"), (b, "b1")]:
            # Enroll held reference embeddings; public endpoint separately verifies VAD.
            store.enroll(key, self.identifier.embedding(self.audio(name)), 2)
        results = [self.identifier.identify(self.audio(name), "test-english") for name in ["a1", "a2", "b1"]]
        self.assertEqual([r["profileID"] for r in results], [a, a, b])

    def test_silence_short_and_isolated_session(self):
        self.assertEqual(self.identifier.identify(np.zeros(27200, dtype=np.float32), "silent")["reason"], "silence")
        self.assertIsNone(self.identifier.identify(self.audio("a1")[:7000], "short")["profileID"])


if __name__ == "__main__":
    unittest.main()
