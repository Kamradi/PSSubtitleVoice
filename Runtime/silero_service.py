"""Local-only Silero service: one model, serialized inference, authenticated loopback HTTP."""
import argparse
import base64
import contextlib
import hashlib
import io
import json
import os
from pathlib import Path
import re
import secrets
import threading
import time
import wave
from bilingual_text import split_languages, english_for_tts, russian_for_tts
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SPEAKERS = ["aidar", "baya", "kseniya", "xenia", "eugene"]


def synthesize(model, torch, text, speaker, english_model=None):
    # Keep sentence punctuation, splitting only unusually long text at whitespace.
    pieces = [(language, piece) for language, part in split_languages(text)
              for piece in re.findall(r".{1,500}(?:\s+|$)|\S+", part, flags=re.DOTALL)]
    if not pieces:
        raise ValueError("Empty text")
    audio = []
    with torch.inference_mode(), contextlib.redirect_stdout(__import__("sys").stderr):
        for language, piece in pieces:
            if language == 'en':
                if english_model is None:
                    raise ValueError('Английская модель не загружена. Откройте обновлённую сборку приложения.')
                audio.append(english_model.apply_tts(text=english_for_tts(piece), speaker='en_0', sample_rate=48000))
            else:
                audio.append(model.apply_tts(text=russian_for_tts(piece), speaker=speaker, sample_rate=48000,
                                             put_accent=True, put_yo=True))
    waveform = torch.cat(audio).detach().cpu().clamp(-1, 1)
    pcm = (waveform.numpy() * 32767).astype("<i2").tobytes()
    output = io.BytesIO()
    with wave.open(output, "wb") as target:
        target.setnchannels(1)
        target.setsampwidth(2)
        target.setframerate(48000)
        target.writeframes(pcm)
    return output.getvalue(), waveform.numel() / 48000


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--state", type=Path, required=True)
    args = parser.parse_args()
    import torch
    torch.set_num_threads(4)
    torch.set_num_interop_threads(1)
    started = time.monotonic()
    model = torch.package.PackageImporter(str(args.model)).load_pickle("tts_models", "model")
    model.to(torch.device("cpu"))
    english_model = None
    english_error = None
    try:
        english_model = torch.package.PackageImporter(str(args.model.parent / 'v3_en.pt')).load_pickle('tts_models', 'model')
        english_model.to(torch.device('cpu'))
    except Exception as error:
        english_error = str(error)
    identifier = None
    identification_error = None
    try:
        from speaker_identifier import SpeakerIdentifier
        identifier = SpeakerIdentifier(args.model.parent, args.state.parent / "characters.json")
    except Exception as error:
        identification_error = str(error)
    gender_classifier = None
    gender_error = None
    try:
        from gender_classifier import GenderClassifier
        gender_classifier = GenderClassifier(args.model.parent)
    except Exception as error:
        gender_error = str(error) or type(error).__name__
    token = secrets.token_urlsafe(32)
    lock = threading.Lock()

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, fmt, *values):
            pass  # No subtitle text or credentials in HTTP logs.

        def reply(self, status, value):
            data = json.dumps(value, ensure_ascii=False).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Connection", "close")
            self.end_headers()
            try:
                self.wfile.write(data)
            except (BrokenPipeError, ConnectionResetError):
                pass

        def authorized(self):
            return secrets.compare_digest(self.headers.get("Authorization", ""), "Bearer " + token)

        def do_GET(self):
            if not self.authorized():
                return self.reply(401, {"error": "Unauthorized"})
            from urllib.parse import urlsplit, parse_qs
            parsed = urlsplit(self.path)
            if parsed.path == "/characters" and identifier is not None:
                try:
                    game = parse_qs(parsed.query).get("game", ["legacy"])[0]
                    with identifier.lock:
                        return self.reply(200, {"profiles": identifier.stores.get(game).public()})
                except ValueError as error: return self.reply(400, {"error": str(error)})
            if self.path != "/health":
                return self.reply(404, {"error": "Not found"})
            self.reply(200, {"ready": True, "model": "v5_5_ru", "speakers": SPEAKERS,
                             "protocolVersion": 14, "englishReady": english_model is not None, "englishError": english_error,
                             "genderReady": gender_classifier is not None, "genderError": gender_error,
                             "speechEnhancementReady": gender_classifier is not None and gender_classifier.enhancer is not None,
                             "speechEnhancementError": gender_classifier.enhancement_error if gender_classifier else gender_error,
                             "speakerIdentificationReady": identifier is not None, "speakerIdentificationError": identification_error,
                             "pid": os.getpid(), "uptimeSeconds": time.monotonic() - started})

        def do_POST(self):
            if not self.authorized():
                return self.reply(401, {"error": "Unauthorized"})
            if self.path == "/shutdown":
                self.reply(200, {"stopping": True})
                threading.Thread(target=self.server.shutdown, daemon=True).start()
                return
            if self.path == "/classify-voice":
                if gender_classifier is None: return self.reply(503, {"error": gender_error or "Gender model unavailable"})
                try:
                    length = int(self.headers.get("Content-Length", "0"))
                    if not 0 < length <= 500000: raise ValueError("Invalid audio request size")
                    request = json.loads(self.rfile.read(length))
                    samples = __import__("numpy").frombuffer(base64.b64decode(request["pcm"], validate=True), dtype="<f4")
                    self.reply(200, gender_classifier.classify(samples))
                except Exception as error: self.reply(400, {"error": str(error) or type(error).__name__})
                return
            if self.path == "/characters":
                if identifier is None: return self.reply(503, {"error": "Speaker model unavailable"})
                try:
                    length = int(self.headers.get("Content-Length", "0"))
                    if not 0 < length <= 4096: raise ValueError("Invalid request size")
                    self.reply(200, identifier.manage(json.loads(self.rfile.read(length))))
                except Exception as error: self.reply(400, {"error": str(error) or type(error).__name__})
                return
            if self.path in ("/identify-speaker", "/enroll-speaker"):
                if identifier is None:
                    return self.reply(503, {"error": identification_error or "Speaker model is unavailable"})
                try:
                    length = int(self.headers.get("Content-Length", "0"))
                    if not 0 < length <= 500000:
                        return self.reply(400, {"error": "Invalid audio request size"})
                    request = json.loads(self.rfile.read(length))
                    session = request.get("session", "")
                    if not isinstance(session, str) or not 1 <= len(session) <= 64:
                        return self.reply(400, {"error": "Invalid session"})
                    samples = __import__("numpy").frombuffer(base64.b64decode(request["pcm"], validate=True), dtype="<f4")
                    if not 8000 <= len(samples) <= 64000:
                        return self.reply(400, {"error": "Expected 0.5 to 4 seconds of mono 16kHz float PCM"})
                    result = identifier.enroll(samples, request.get("id", ""), request.get("game", "legacy")) if self.path == "/enroll-speaker" else identifier.identify(samples, session, request.get("game", "legacy"))
                    self.reply(200, result)
                except Exception as error:
                    self.reply(400, {"error": str(error)})
                return
            if self.path != "/synthesize":
                return self.reply(404, {"error": "Not found"})
            try:
                length = int(self.headers.get("Content-Length", "0"))
                if not 0 < length <= 20000:
                    return self.reply(400, {"error": "Invalid request size"})
                request = json.loads(self.rfile.read(length))
                text = request.get("text", "")
                speaker = request.get("speaker", "")
                if not isinstance(text, str) or not text.strip() or len(text) > 3000 or speaker not in SPEAKERS:
                    return self.reply(400, {"error": "Invalid text or speaker"})
                if not lock.acquire(timeout=60):
                    return self.reply(503, {"error": "Synthesis is busy"})
                try:
                    before = time.monotonic()
                    wav, duration = synthesize(model, torch, text, speaker, english_model)
                    elapsed = time.monotonic() - before
                finally:
                    lock.release()
                self.reply(200, {"wav": base64.b64encode(wav).decode("ascii"), "duration": duration,
                                 "synthesisSeconds": elapsed, "speaker": speaker, "pid": os.getpid()})
            except Exception as error:
                self.reply(500, {"error": str(error)})

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    args.state.parent.mkdir(parents=True, exist_ok=True)
    state = {"port": server.server_port, "token": token, "pid": os.getpid(), "model": "v5_5_ru"}
    temporary = args.state.with_suffix(".tmp")
    temporary.write_text(json.dumps(state), encoding="utf-8")
    temporary.chmod(0o600)
    temporary.replace(args.state)
    print(json.dumps({"event": "ready", "pid": os.getpid(), "loadSeconds": time.monotonic() - started,
                      "modelSHA256": hashlib.sha256(args.model.read_bytes()).hexdigest()}), flush=True)
    try:
        server.serve_forever()
    finally:
        try:
            if json.loads(args.state.read_text())["pid"] == os.getpid():
                args.state.unlink()
        except (FileNotFoundError, KeyError, ValueError):
            pass
        server.server_close()


if __name__ == "__main__":
    main()
