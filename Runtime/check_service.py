import base64
import io
import json
from pathlib import Path
import urllib.error
import urllib.request
import wave

state = json.loads((Path.home() / "Library/Containers/com.local.PSSubtitleVoice/Data/Library/Application Support/PSSubtitleVoice/Silero/service.json").read_text())
base = f"http://127.0.0.1:{int(state['port'])}"


def request(path, body=None, authenticated=True):
    headers = {"Content-Type": "application/json"}
    if authenticated:
        headers["Authorization"] = "Bearer " + state["token"]
    payload = None if body is None else json.dumps(body).encode()
    with urllib.request.urlopen(urllib.request.Request(base + path, data=payload, headers=headers), timeout=90) as response:
        return json.load(response)


initial = request("/health")
assert initial["ready"]
for speaker in ["aidar", "kseniya"]:
    result = request("/synthesize", {"text": "Нам нужно добраться до машины. Подожди меня возле старого моста, я вернусь через несколько минут.", "speaker": speaker})
    data = base64.b64decode(result["wav"])
    with wave.open(io.BytesIO(data)) as audio:
        assert audio.getnchannels() == 1 and audio.getframerate() == 48000
        duration = audio.getnframes() / audio.getframerate()
        assert duration > 3
    assert result["pid"] == initial["pid"]
    print(json.dumps({"speaker": speaker, "duration": round(duration, 3), "synthesisMS": round(result["synthesisSeconds"] * 1000), "pid": result["pid"]}))
try:
    request("/health", authenticated=False)
    raise AssertionError("Missing authentication accepted")
except urllib.error.HTTPError as error:
    assert error.code == 401
try:
    request("/synthesize", {"text": "Тест", "speaker": "not-a-voice"})
    raise AssertionError("Invalid speaker accepted")
except urllib.error.HTTPError as error:
    assert error.code == 400
print("PASS: two real voices, WAV format, model reuse, authentication, invalid request handling")
