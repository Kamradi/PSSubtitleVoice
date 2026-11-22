"""Session-only anonymous speaker clustering; no real names, gender inference or audio persistence."""
from pathlib import Path
import threading
import time
import uuid
import numpy as np


class VoiceRegistry:
    def __init__(self):
        self.profiles = []
        self.candidates = []

    def match(self, vector):
        vector = np.asarray(vector, dtype=np.float32)
        norm = np.linalg.norm(vector)
        if not np.isfinite(norm) or norm < 1e-6:
            return None, 0.0, "invalid_embedding"
        vector = vector / norm
        scores = [float(np.dot(vector, profile["embedding"])) for profile in self.profiles]
        order = sorted(range(len(scores)), key=lambda i: scores[i], reverse=True)
        best = scores[order[0]] if order else -1.0
        runner = scores[order[1]] if len(order) > 1 else -1.0
        if order and best >= 0.65 and best - runner >= 0.08:
            profile = self.profiles[order[0]]
            profile["observations"] += 1
            if best >= 0.80:
                updated = profile["embedding"] * 0.98 + vector * 0.02
                profile["embedding"] = updated / np.linalg.norm(updated)
            return profile["id"], best, "matched"
        if order and best > 0.60:
            return None, best, "ambiguous_match"
        if order:
            now = time.monotonic()
            self.candidates = [p for p in self.candidates if now - p["created"] < 60]
            candidate = next((p for p in self.candidates if float(np.dot(p["embedding"], vector)) >= 0.75), None)
            if candidate is None:
                if len(self.candidates) >= 4:
                    self.candidates.pop(0)
                self.candidates.append({"embedding": vector, "created": now})
                return None, best, "learning_new_voice"
            self.candidates = [p for p in self.candidates if p is not candidate]
        if len(self.profiles) >= 8:
            return None, best, "profile_limit"
        profile_id = "speaker-" + str(len(self.profiles) + 1)
        self.profiles.append({"id": profile_id, "embedding": vector, "observations": 1})
        return profile_id, 1.0, "new_profile"

    def public(self):
        return [{"id": p["id"], "observations": p["observations"]} for p in self.profiles]


class SpeakerIdentifier:
    def __init__(self, directory, profiles_path=None):
        import sherpa_onnx
        self.sherpa = sherpa_onnx
        directory = Path(directory)
        configuration = sherpa_onnx.SpeakerEmbeddingExtractorConfig(
            model=str(directory / "wespeaker_en_voxceleb_resnet34.onnx"), num_threads=2, provider="cpu")
        if not configuration.validate():
            raise ValueError("Speaker embedding model is unavailable")
        self.extractor = sherpa_onnx.SpeakerEmbeddingExtractor(configuration)
        self.vad_config = sherpa_onnx.VadModelConfig()
        self.vad_config.silero_vad.model = str(directory / "silero_vad.onnx")
        self.vad_config.silero_vad.threshold = 0.6
        self.vad_config.silero_vad.min_speech_duration = 0.20
        self.vad_config.silero_vad.min_silence_duration = 0.15
        self.vad_config.sample_rate = 16000
        self.vad_config.num_threads = 1
        self.lock = threading.Lock()
        self.sessions = {}
        from game_voice_stores import GameVoiceStores
        self.stores = GameVoiceStores(profiles_path)
        self.enrolled = self.stores.get("legacy")

    def embedding(self, samples):
        stream = self.extractor.create_stream()
        stream.accept_waveform(sample_rate=16000, waveform=np.ascontiguousarray(samples, dtype=np.float32))
        stream.input_finished()
        if not self.extractor.is_ready(stream):
            raise ValueError("Insufficient speech for an embedding")
        vector = np.asarray(self.extractor.compute(stream), dtype=np.float32)
        return vector / max(np.linalg.norm(vector), 1e-8)

    def identify(self, samples, session, game="legacy"):
        before = time.monotonic()
        with self.lock:
            enrolled = self.stores.get(game)
            now = time.monotonic()
            self.sessions = {key: value for key, value in self.sessions.items() if now - value["touched"] < 1800}
            if session not in self.sessions:
                if len(self.sessions) >= 4:
                    oldest = min(self.sessions, key=lambda key: self.sessions[key]["touched"])
                    del self.sessions[oldest]
                self.sessions[session] = {"touched": now, "registry": VoiceRegistry(), "registryID": uuid.uuid4().hex}
            self.sessions[session]["touched"] = now
            registry = self.sessions[session]["registry"]
            result = {"profileID": None, "score": 0.0, "reason": "insufficient_speech", "speechSeconds": 0.0}
            if not np.isfinite(samples).all() or np.max(np.abs(samples), initial=0) > 1.1:
                raise ValueError("Invalid PCM samples")
            if np.sqrt(np.mean(samples ** 2)) < 0.002:
                result["reason"] = "silence"
            else:
                vad = self.sherpa.VoiceActivityDetector(self.vad_config, buffer_size_in_seconds=10)
                for offset in range(0, len(samples), 512):
                    vad.accept_waveform(samples[offset:offset + 512])
                vad.flush()
                portions = []
                while not vad.empty():
                    portions.append(np.asarray(vad.front.samples, dtype=np.float32))
                    vad.pop()
                speech = np.concatenate(portions) if portions else np.empty(0, dtype=np.float32)
                result["speechSeconds"] = len(speech) / 16000
                if len(speech) >= 16000:
                    full = self.embedding(speech)
                    # A turn spanning two characters should fall back rather than invent a mixed profile.
                    # Sub-second halves have unstable embeddings even for one
                    # speaker. Use the whole utterance; only compare halves when
                    # each contains at least one second of detected speech.
                    coherence = None
                    if len(speech) >= 32000:
                        middle = len(speech) // 2
                        coherence = float(np.dot(self.embedding(speech[:middle]), self.embedding(speech[middle:])))
                        result["coherence"] = coherence
                    if coherence is not None and coherence < 0.60:
                        result["reason"] = "mixed_or_unstable_voice"
                    else:
                        identity, score, reason = enrolled.match(full)
                        result.update(profileID=identity, score=score, reason=reason)
                        scores = enrolled.scores(full)
                        result["profileScores"] = {profile_id: value for value, profile_id in scores}
                        result["margin"] = scores[0][0] - scores[1][0] if len(scores) > 1 else (scores[0][0] if scores else 0.0)
            result["registryID"] = enrolled.registry_id
            result["profiles"] = enrolled.public()
            result["analysisMS"] = round((time.monotonic() - before) * 1000)
            return result

    def manage(self, request):
        with self.lock:
            enrolled = self.stores.get(request.get("game", "legacy"))
            enrolled.edit(request.get("action"), request.get("id", ""), request.get("name", ""), request.get("voice", "eugene"))
            return {"profiles": enrolled.public()}

    def enroll(self, samples, profile_id, game="legacy"):
        # identify performs PCM validation and VAD without changing any profiles.
        checked = self.identify(samples, "enrollment", game)
        if checked["speechSeconds"] < 1.5 or checked["reason"] == "mixed_or_unstable_voice":
            raise ValueError("Мало чистой речи. Запишите фрагмент без пауз, музыки и других персонажей.")
        vad = self.sherpa.VoiceActivityDetector(self.vad_config, buffer_size_in_seconds=10)
        for offset in range(0, len(samples), 512): vad.accept_waveform(samples[offset:offset + 512])
        vad.flush()
        portions = []
        while not vad.empty():
            portions.append(np.asarray(vad.front.samples, dtype=np.float32)); vad.pop()
        speech = np.concatenate(portions)
        with self.lock:
            enrolled = self.stores.get(game)
            enrolled.enroll(profile_id, self.embedding(speech), len(speech) / 16000)
            return {"profiles": enrolled.public()}
