"""Authenticated local M/F classification + selected-voice synthesis smoke check."""
import base64
import json
import os
from pathlib import Path
import urllib.error
import urllib.request
import wave
import numpy as np

state = json.loads((Path.home() / 'Library/Containers/com.local.PSSubtitleVoice/Data/Library/Application Support/PSSubtitleVoice/Silero/service.json').read_text())
base = f"http://127.0.0.1:{int(state['port'])}"
def request(path, body=None):
    req = urllib.request.Request(base + path, data=None if body is None else json.dumps(body).encode(),
        headers={'Authorization': 'Bearer ' + state['token'], 'Content-Type': 'application/json'})
    with urllib.request.urlopen(req, timeout=15) as response: return json.load(response)
health = request('/health')
assert health['genderReady'], health.get('genderError')
for name, expected, voice in [('a1', 'female', 'kseniya'), ('a2', 'female', 'kseniya'), ('b1', 'male', 'eugene')]:
    with wave.open(str(Path(os.environ['GENDER_TEST_AUDIO_DIR']) / (name + '.wav'))) as source:
        audio = np.frombuffer(source.readframes(source.getnframes()), dtype='<i2').astype(np.float32) / 32768
    result = request('/classify-voice', {'pcm': base64.b64encode(audio[1600:40000].astype('<f4').tobytes()).decode()})
    print(name, result)
    assert result['label'] == expected, result
    speech = request('/synthesize', {'speaker': voice, 'text': 'Нам нужно добраться до машины.'})
    assert speech['speaker'] == voice and speech['duration'] > 0
silence = base64.b64encode(np.zeros(40000, dtype='<f4').tobytes()).decode()
assert request('/classify-voice', {'pcm': silence})['label'] is None
try:
    request('/classify-voice', {'pcm': 'invalid'})
    raise AssertionError('Invalid audio accepted')
except urllib.error.HTTPError as error: assert error.code == 400
try:
    urllib.request.urlopen(urllib.request.Request(base + '/classify-voice', data=b'{}'))
    raise AssertionError('Unauthenticated request accepted')
except urllib.error.HTTPError as error: assert error.code == 401
print('PASS: M/F decisions, two voice synthesis, silence, malformed audio and authentication')
