"""Local GTCRN speech enhancement. Short independent clips; no audio is saved."""
from pathlib import Path
import numpy as np
import sherpa_onnx


class SpeechEnhancer:
    def __init__(self, directory):
        path = Path(directory) / 'gtcrn_simple.onnx'
        if not path.is_file():
            raise FileNotFoundError('GTCRN model missing; run Runtime/setup.command')
        config = sherpa_onnx.OfflineSpeechDenoiserConfig(
            model=sherpa_onnx.OfflineSpeechDenoiserModelConfig(
                gtcrn=sherpa_onnx.OfflineSpeechDenoiserGtcrnModelConfig(model=str(path)),
                num_threads=1, provider='cpu'))
        if not config.validate():
            raise ValueError('Invalid GTCRN model configuration')
        self.model = sherpa_onnx.OfflineSpeechDenoiser(config)

    def enhance(self, samples):
        output = self.model(np.ascontiguousarray(samples, dtype=np.float32), 16000)
        result = np.asarray(output.samples, dtype=np.float32)
        # Offline STFT can drop less than one hop at the end. Never pad/repeat
        # audio to create extra evidence for the classifier.
        if output.sample_rate != 16000 or result.ndim != 1 or not 0 < len(result) <= len(samples) + 512 or not np.isfinite(result).all():
            raise ValueError('Invalid GTCRN output')
        return np.clip(result, -1, 1)
