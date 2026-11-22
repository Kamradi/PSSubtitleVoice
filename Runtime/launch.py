import json
import fcntl
import os
from pathlib import Path
import subprocess
import sys
import time
import urllib.request

ROOT = Path(__file__).resolve().parent
STATE = Path.home() / "Library/Containers/com.local.PSSubtitleVoice/Data/Library/Application Support/PSSubtitleVoice/Silero/service.json"


def ready():
    try:
        state = json.loads(STATE.read_text())
        request = urllib.request.Request(f"http://127.0.0.1:{int(state['port'])}/health",
                                         headers={"Authorization": "Bearer " + state["token"]})
        with urllib.request.urlopen(request, timeout=1) as response:
            health = json.load(response)
            return health.get("ready", False) and health.get("protocolVersion", 1) >= 14
    except Exception:
        return False


lockfile = (ROOT / ".launch.lock").open("a")
fcntl.flock(lockfile, fcntl.LOCK_EX)
if not ready():
    try:
        previous = json.loads(STATE.read_text())
        request = urllib.request.Request(f"http://127.0.0.1:{int(previous['port'])}/shutdown", data=b"{}",
                                         headers={"Authorization": "Bearer " + previous["token"]})
        with urllib.request.urlopen(request, timeout=2) as response:
            response.read()
        time.sleep(0.6)
    except Exception:
        pass
    if not (ROOT / "v5_5_ru.pt").exists():
        raise SystemExit("Missing model. Run Runtime/setup.command first.")
    with (ROOT / "service.log").open("ab") as log:
        child = subprocess.Popen([sys.executable, "-u", str(ROOT / "silero_service.py"), "--model", str(ROOT / "v5_5_ru.pt"),
                          "--state", str(STATE)], stdin=subprocess.DEVNULL, stdout=log, stderr=log,
                         start_new_session=True, cwd=ROOT)
    print("Loading local Silero model...", flush=True)
    for _ in range(240):
        if child.poll() is not None:
            raise SystemExit("Silero exited during startup. See Runtime/service.log.")
        if ready():
            break
        time.sleep(0.5)
    else:
        raise SystemExit("Silero could not start. See Runtime/service.log.")
fcntl.flock(lockfile, fcntl.LOCK_UN)
lockfile.close()
print("Silero v5_5_ru ready. Local processing only.")
if "--service-only" not in sys.argv:
    app = ROOT.parent / "build/Build/Products/Debug/PSSubtitleVoice.app"
    if not app.exists():
        raise SystemExit("Build PSSubtitleVoice in Xcode first.")
    subprocess.run(["/usr/bin/open", str(app)], check=True)
