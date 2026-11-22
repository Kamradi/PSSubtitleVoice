"""HTTP enrollment check. Removes only the temporary characters it creates."""
import base64
import json
import os
from pathlib import Path
import urllib.error
import urllib.request
import uuid
import wave
import numpy as np

state = json.loads((Path.home() / 'Library/Containers/com.local.PSSubtitleVoice/Data/Library/Application Support/PSSubtitleVoice/Silero/service.json').read_text())
base = f"http://127.0.0.1:{int(state['port'])}"
def request(path, body=None):
    req = urllib.request.Request(base + path, data=None if body is None else json.dumps(body).encode(),
        headers={'Authorization': 'Bearer ' + state['token'], 'Content-Type': 'application/json'})
    with urllib.request.urlopen(req, timeout=10) as response: return json.load(response)
def audio(name):
    with wave.open(str(Path(os.environ['SPEAKER_TEST_AUDIO_DIR']) / (name + '.wav'))) as source:
        samples = np.frombuffer(source.readframes(source.getnframes()), dtype='<i2').astype(np.float32) / 32768
    return base64.b64encode(samples[1600:49600].astype('<f4').tobytes()).decode()
health = request('/health')
assert health['protocolVersion'] >= 5 and health['speakerIdentificationReady'], health
created = []
session = uuid.uuid4().hex
try:
    for name, fixture, voice in [('Test A', 'a1', 'eugene'), ('Test B', 'b1', 'aidar')]:
        before = {p['id'] for p in request('/characters')['profiles']}
        profiles = request('/characters', {'action': 'add', 'name': name, 'voice': voice})['profiles']
        key = next(p['id'] for p in profiles if p['id'] not in before)
        created.append(key)
        for _ in range(2): result = request('/enroll-speaker', {'id': key, 'session': session, 'pcm': audio(fixture)})
        assert next(p for p in result['profiles'] if p['id'] == key)['ready']
    for fixture, expected in [('a1', created[0]), ('a2', created[0]), ('b1', created[1])]:
        result = request('/identify-speaker', {'session': session, 'pcm': audio(fixture)})
        print(fixture, result['reason'], round(result['score'], 3))
        assert result['profileID'] == expected, result
    silence = base64.b64encode(np.zeros(48000, dtype='<f4').tobytes()).decode()
    count = len(request('/characters')['profiles'])
    assert request('/identify-speaker', {'session': session, 'pcm': silence})['profileID'] is None
    assert len(request('/characters')['profiles']) == count
    try:
        request('/enroll-speaker', {'id': created[0], 'session': session, 'pcm': silence})
        raise AssertionError('Silence accepted')
    except urllib.error.HTTPError as error: assert error.code == 400
    try:
        urllib.request.urlopen(base + '/characters')
        raise AssertionError('Unauthenticated profiles exposed')
    except urllib.error.HTTPError as error: assert error.code == 401
    print('PASS: enrollment, readiness, recognition, silence rejection, no automatic profiles, auth')
finally:
    for key in created: request('/characters', {'action': 'delete', 'id': key})
    assert not any(p['id'] in created for p in request('/characters')['profiles'])
