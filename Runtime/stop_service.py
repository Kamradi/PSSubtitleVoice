import json
from pathlib import Path
import urllib.request
state_path = Path.home() / "Library/Containers/com.local.PSSubtitleVoice/Data/Library/Application Support/PSSubtitleVoice/Silero/service.json"
try:
    state = json.loads(state_path.read_text())
    request = urllib.request.Request(f"http://127.0.0.1:{int(state['port'])}/shutdown", data=b"{}",
                                     headers={"Authorization": "Bearer " + state["token"]})
    with urllib.request.urlopen(request, timeout=5) as response:
        response.read()
    print("Silero stopped.")
except FileNotFoundError:
    print("Silero is not running.")
