"""Local acoustic M/F routing. No age, identity or gender identity inference is used."""
from pathlib import Path
import threading
import time
import numpy as np


def decision(scores, threshold=0.80):
    # Official ONNX label order: female, male, child.
    values = np.asarray(scores, dtype=np.float32).reshape(-1)
    if values.shape != (3,) or not np.isfinite(values).all():
        return None, 0.0, 'invalid_scores'
    probabilities = np.exp(values - np.max(values))
    probabilities /= probabilities.sum()
    best = int(np.argmax(probabilities))
    ordered = np.sort(probabilities)
    if best == 2 or probabilities[best] < threshold or ordered[-1] - ordered[-2] < .30:
        return None, float(probabilities[best]), 'uncertain_voice'
    return ['female', 'male'][best], float(probabilities[best]), 'classified'


class GenderClassifier:
    def __init__(self, directory):
        import onnxruntime as ort
        import sherpa_onnx
        directory = Path(directory)
        options = ort.SessionOptions()
        options.intra_op_num_threads = 2
        options.inter_op_num_threads = 1
        self.model = ort.InferenceSession(str(directory / 'gender-model' / 'model.onnx'), sess_options=options, providers=['CPUExecutionProvider'])
        self.input_name = self.model.get_inputs()[0].name
        self.output_name = 'logits_gender'
        if self.output_name not in [o.name for o in self.model.get_outputs()]:
            raise ValueError('Gender model output schema changed')
        self.sherpa = sherpa_onnx
        self.vad_config = sherpa_onnx.VadModelConfig()
        self.vad_config.silero_vad.model = str(directory / 'silero_vad.onnx')
        self.vad_config.silero_vad.threshold = .5
        self.vad_config.silero_vad.min_speech_duration = .2
        self.vad_config.silero_vad.min_silence_duration = .15
        self.vad_config.sample_rate = 16000
        self.vad_config.num_threads = 1
        self.lock = threading.RLock()
        self.enhancer = None
        self.enhancement_error = None
        try:
            from speech_enhancer import SpeechEnhancer
            self.enhancer = SpeechEnhancer(directory)
        except Exception as error:
            self.enhancement_error = str(error)

    def scores(self, speech):
        # Official ONNX export accepts the raw mono waveform (metadata: transform=None).
        return self.model.run([self.output_name], {self.input_name: speech.astype(np.float32)[None, :]})[0].reshape(-1)

    def classify(self, samples):
        started = time.monotonic()
        with self.lock:
            raw = self._classify(samples)
            result = dict(raw)
            result.update(rawLabel=raw['label'], rawReason=raw['reason'], rawScore=raw['score'],
                          rawSpeechSeconds=raw['speechSeconds'], enhancement='unavailable', enhancementMS=0)
            if self.enhancer is not None and raw['reason'] != 'silence':
                try:
                    enhanced_at = time.monotonic()
                    clean_audio = self.enhancer.enhance(samples)
                    result['enhancementMS'] = round((time.monotonic() - enhanced_at) * 1000)
                    clean = self._classify(clean_audio)
                    result.update(cleanLabel=clean['label'], cleanReason=clean['reason'],
                                  cleanScore=clean['score'], cleanSpeechSeconds=clean['speechSeconds'], enhancement='gtcrn')
                    # A confident contradiction is not a licence to pick one voice.
                    if raw['label'] and clean['label'] and raw['label'] != clean['label']:
                        result.update(label=None, reason='enhancement_conflict')
                    elif raw['reason'] == 'mixed_voices' or clean['reason'] == 'mixed_voices':
                        result.update(label=None, reason='mixed_voices')
                    elif clean['label']:
                        result.update({key: clean[key] for key in ('label', 'score', 'reason', 'speechSeconds')})
                    # Keep an existing confident raw decision when enhancement
                    # cannot classify; never manufacture a male/female default.
                except Exception:
                    result['enhancement'] = 'error'
            elif self.enhancer is not None:
                result['enhancement'] = 'skipped_silence'
        result['analysisMS'] = round((time.monotonic() - started) * 1000)
        return result

    def _classify(self, samples):
        started = time.monotonic()
        samples = np.asarray(samples, dtype=np.float32)
        if samples.ndim != 1 or not 8000 <= len(samples) <= 64000 or not np.isfinite(samples).all() or np.max(np.abs(samples)) > 1.1:
            raise ValueError('Invalid mono 16kHz PCM')
        result = {'label': None, 'score': 0.0, 'reason': 'insufficient_speech', 'speechSeconds': 0.0}
        with self.lock:
            rms = float(np.sqrt(np.mean(samples ** 2)))
            result['inputRMS'] = rms
            if rms < .00003:
                result['reason'] = 'silence'
            else:
                # ScreenCaptureKit reflects the player's volume. Quiet speech
                # must pass through VAD instead of being labelled silence by
                # the old absolute 0.002 RMS cutoff.
                gain = min(20.0, .03 / max(rms, 1e-8), .95 / max(float(np.max(np.abs(samples))), 1e-8)) if rms < .015 else 1.0
                samples = samples * gain
                result['analysisGain'] = gain
                vad = self.sherpa.VoiceActivityDetector(self.vad_config, buffer_size_in_seconds=10)
                for offset in range(0, len(samples), 512): vad.accept_waveform(samples[offset:offset + 512])
                vad.flush()
                portions = []
                while not vad.empty():
                    portions.append(np.asarray(vad.front.samples, dtype=np.float32)); vad.pop()
                speech = np.concatenate(portions) if portions else np.empty(0, dtype=np.float32)
                result['speechSeconds'] = len(speech) / 16000
                result['speechSegments'] = len(portions)
                if len(speech) >= 10400:
                    raw = self.scores(speech)
                    short = len(speech) < 16000
                    label, score, reason = decision(raw, .95 if short else .80)
                    if short:
                        reason = 'uncertain_short_voice'
                        if label:
                            # Require agreement on two shifted views of the same
                            # actual speech; never repeat/pad it to invent evidence.
                            span = int(len(speech) * .85)
                            first = decision(self.scores(speech[:span]), .90)[0]
                            last = decision(self.scores(speech[-span:]), .90)[0]
                            if first == last == label:
                                reason = 'classified_short'
                            else:
                                label = None
                    if label and len(speech) >= 32000:
                        # Comparing equal halves can still mix both speakers in
                        # the first half. Inspect separate one-second edges.
                        first = decision(self.scores(speech[:16000]), .80)[0]
                        second = decision(self.scores(speech[-16000:]), .80)[0]
                        if first and second and first != second:
                            label, reason = None, 'mixed_voices'
                    result.update(label=label, score=score, reason=reason)
        result['analysisMS'] = round((time.monotonic() - started) * 1000)
        return result
