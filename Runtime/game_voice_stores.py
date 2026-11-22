"""Explicit per-game stores. Legacy samples stay in their original file."""
from pathlib import Path
import uuid
from enrolled_voices import EnrolledVoices

class GameVoiceStores:
    def __init__(self, legacy_path=None):
        self.legacy_path = Path(legacy_path) if legacy_path else None
        self.cache = {'legacy': EnrolledVoices(legacy_path)}

    @staticmethod
    def key(game):
        if game == 'legacy': return game
        if not isinstance(game, str): raise ValueError('Invalid game id')
        try: return str(uuid.UUID(game))
        except (ValueError, AttributeError): raise ValueError('Invalid game id') from None

    def get(self, game):
        key = self.key(game)
        if key not in self.cache:
            path = self.legacy_path.parent / 'games' / (key + '.json') if self.legacy_path else None
            if len(self.cache) >= 64:
                oldest = next(k for k in self.cache if k != 'legacy')
                del self.cache[oldest]
            self.cache[key] = EnrolledVoices(path)
        return self.cache[key]
