"""Explicitly enrolled local voice embeddings. Never stores waveform audio."""
import json
from pathlib import Path
import uuid
import numpy as np

VOICES = {'aidar', 'eugene', 'kseniya', 'xenia', 'baya'}

class EnrolledVoices:
    def __init__(self, path=None):
        self.path = Path(path) if path else None
        self.rows = []
        self.registry_id = uuid.uuid4().hex
        if self.path and self.path.exists():
            data = json.loads(self.path.read_text())
            if data.get('version') != 1 or len(data['characters']) > 32:
                raise ValueError('Unsupported character file')
            self.rows = data['characters']
            ids = set()
            for row in self.rows:
                if row['id'] in ids or row['voice'] not in VOICES or len(row['samples']) > 20:
                    raise ValueError('Invalid character file')
                ids.add(row['id'])
                for sample in row['samples']:
                    self.vector(sample['vector'])

    @staticmethod
    def vector(value):
        v = np.asarray(value, dtype=np.float32)
        if v.shape != (256,) or not np.isfinite(v).all() or np.linalg.norm(v) < 1e-6:
            raise ValueError('Invalid voice embedding')
        return v / np.linalg.norm(v)

    def save(self):
        if self.path:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            temporary = self.path.with_suffix('.tmp')
            temporary.write_text(json.dumps({'version': 1, 'characters': self.rows}), encoding='utf-8')
            temporary.chmod(0o600)
            temporary.replace(self.path)

    def public(self):
        return [{'id': r['id'], 'name': r['name'], 'voice': r['voice'],
                 'observations': len(r['samples']), 'speechSeconds': sum(s['seconds'] for s in r['samples']),
                 'ready': len(r['samples']) >= 2 and sum(s['seconds'] for s in r['samples']) >= 4}
                for r in self.rows]

    def edit(self, action, profile_id='', name='', voice='eugene'):
        if action == 'add':
            if len(self.rows) >= 32: raise ValueError('Maximum 32 characters')
            profile_id = uuid.uuid4().hex
            self.rows.append({'id': profile_id, 'name': 'Персонаж', 'voice': voice, 'samples': []})
        row = next((r for r in self.rows if r['id'] == profile_id), None)
        if row is None: raise ValueError('Character not found')
        if action in ('add', 'update'):
            if not isinstance(name, str) or not 1 <= len(name.strip()) <= 80 or voice not in VOICES:
                if action == 'add': self.rows.remove(row)
                raise ValueError('Укажите имя персонажа и доступный голос.')
            row.update(name=name.strip(), voice=voice)
        elif action == 'clear': row['samples'] = []
        elif action == 'delete': self.rows.remove(row)
        else: raise ValueError('Invalid character action')
        self.save()
        return profile_id

    def enroll(self, profile_id, vector, seconds):
        row = next((r for r in self.rows if r['id'] == profile_id), None)
        if row is None: raise ValueError('Character not found')
        v = self.vector(vector)
        if row['samples'] and max(float(np.dot(v, self.vector(s['vector']))) for s in row['samples']) < 0.60:
            raise ValueError('Образец сильно отличается от сохранённых. Проверьте, что говорит тот же персонаж.')
        if len(row['samples']) >= 20: raise ValueError('Достигнут предел образцов. Очистите обучение для новой записи.')
        row['samples'].append({'vector': v.tolist(), 'seconds': float(seconds)})
        self.save()

    def scores(self, vector):
        v = self.vector(vector)
        scores = []
        for row, info in zip(self.rows, self.public()):
            if not info['ready']: continue
            values = sorted((float(np.dot(v, self.vector(s['vector']))) for s in row['samples']), reverse=True)
            # Two independent samples must agree; a single lucky match is insufficient.
            scores.append((sum(values[:2]) / 2, row['id']))
        scores.sort(reverse=True)
        return scores

    def match(self, vector):
        scores = self.scores(vector)
        if not scores: return None, 0.0, 'no_trained_characters' 
        best, profile_id = scores[0]
        margin = best - scores[1][0] if len(scores) > 1 else best
        if best >= 0.75 and margin >= 0.12: return profile_id, best, 'enrolled_match'
        return None, best, 'uncertain_enrolled_match'
