from pathlib import Path
import tempfile
import unittest
import uuid
import numpy as np
from game_voice_stores import GameVoiceStores

class GameChecks(unittest.TestCase):
    def test_isolation_persistence_and_legacy(self):
        with tempfile.TemporaryDirectory() as directory:
            legacy = Path(directory) / 'characters.json'
            stores = GameVoiceStores(legacy)
            old = stores.get('legacy')
            key = old.edit('add', name='Старый персонаж', voice='aidar')
            old.enroll(key, np.eye(256)[0], 2)
            original = legacy.read_bytes()
            a, b = str(uuid.uuid4()), str(uuid.uuid4())
            first = stores.get(a)
            key = first.edit('add', name='Герой', voice='eugene')
            first.enroll(key, np.eye(256)[1], 2)
            first.enroll(key, np.eye(256)[1], 2)
            self.assertEqual(stores.get(b).public(), [])
            self.assertEqual(legacy.read_bytes(), original)
            restored = GameVoiceStores(legacy)
            self.assertEqual(restored.get(a.upper()).public()[0]['voice'], 'eugene')
            self.assertTrue(restored.get(a).public()[0]['ready'])
            self.assertEqual(restored.get(b).public(), [])
            self.assertEqual(restored.get('legacy').public()[0]['name'], 'Старый персонаж')
            restored.get(a).edit('clear', key)
            self.assertEqual(restored.get('legacy').public()[0]['observations'], 1)
            for invalid in ['../characters', '/tmp/x', '', None, 'new-game']:
                with self.assertRaises(ValueError): restored.get(invalid)

if __name__ == '__main__': unittest.main()
