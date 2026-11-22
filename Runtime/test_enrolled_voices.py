import tempfile
from pathlib import Path
import unittest
import numpy as np
from enrolled_voices import EnrolledVoices

class EnrollmentChecks(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.path = Path(self.temp.name) / 'characters.json'
        self.store = EnrolledVoices(self.path)
        self.a = np.eye(256, dtype=np.float32)[0]
        self.b = np.eye(256, dtype=np.float32)[1]
    def tearDown(self): self.temp.cleanup()
    def add(self, name, vector):
        key = self.store.edit('add', name=name, voice='aidar')
        self.store.enroll(key, vector, 2)
        self.store.enroll(key, vector, 2)
        return key
    def test_no_automatic_profiles(self):
        self.assertIsNone(self.store.match(self.a)[0])
        self.assertEqual(self.store.rows, [])
        key = self.store.edit('add', name='Майкл', voice='eugene')
        self.store.enroll(key, self.a, 3)
        self.assertIsNone(self.store.match(self.a)[0])
    def test_persistence_matching_and_ambiguity(self):
        first = self.add('Майкл', self.a)
        second = self.add('Тревор', self.b)
        restored = EnrolledVoices(self.path)
        self.assertEqual(restored.match(self.a)[0], first)
        self.assertEqual(restored.match(self.b)[0], second)
        self.assertIsNone(restored.match(self.a + self.b)[0])
        self.assertEqual(restored.public()[0]['name'], 'Майкл')
        self.assertEqual(self.path.stat().st_mode & 0o777, 0o600)
        restored.edit('clear', first)
        self.assertIsNone(restored.match(self.a)[0])
        restored.edit('delete', second)
        self.assertEqual(len(EnrolledVoices(self.path).rows), 1)
    def test_wrong_speaker_cannot_contaminate_training(self):
        key = self.add('Майкл', self.a)
        with self.assertRaises(ValueError): self.store.enroll(key, self.b, 2)
        self.assertEqual(len(self.store.rows[0]['samples']), 2)
    def test_similar_enrolled_characters_are_ambiguous(self):
        self.add('Один', self.a)
        self.add('Другой', self.a + self.b * .1)
        self.assertIsNone(self.store.match(self.a)[0])
    def test_invalid_metadata_and_embedding(self):
        with self.assertRaises(ValueError): self.store.edit('add', name='', voice='aidar')
        self.assertEqual(self.store.rows, [])
        with self.assertRaises(ValueError): self.store.match([float('nan')] * 256)

if __name__ == '__main__': unittest.main()
