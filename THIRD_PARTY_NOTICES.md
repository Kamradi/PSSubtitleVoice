# Third-party components / Сторонние компоненты

The MIT license in this repository covers original application code and documentation. It does not replace licenses of model weights, Python, packages, Apple frameworks or other third-party material.

MIT в этом репозитории распространяется на собственный код приложения и документацию. Модели и сторонние компоненты сохраняют собственные лицензии.

| Component | Purpose | Upstream / license |
| --- | --- | --- |
| Silero TTS `v5_5_ru.pt`, `v3_en.pt` | Russian and English synthesis | [Silero Models](https://github.com/snakers4/silero-models), [CC BY-NC-SA 4.0](Licenses/Silero-TTS.txt) |
| audEERING `wav2vec2-large-robust-6-ft-age-gender` / ONNX export | Source-audio voice classification | [Model card](https://huggingface.co/audeering/wav2vec2-large-robust-6-ft-age-gender), [CC BY-NC-SA 4.0](Licenses/audEERING.txt); [ONNX archive](https://zenodo.org/records/7761387) |
| WeSpeaker ResNet34 / sherpa-onnx export | Character speaker embeddings | [WeSpeaker](https://github.com/wenet-e2e/wespeaker), [Apache 2.0](Licenses/WeSpeaker.txt); model from [sherpa-onnx releases](https://github.com/k2-fsa/sherpa-onnx/releases/tag/speaker-recongition-models) |
| Silero VAD / ONNX export | Speech activity detection | [Silero VAD](https://github.com/snakers4/silero-vad), [MIT](Licenses/Silero-VAD.txt) |
| GTCRN / sherpa-onnx ONNX export | Source speech enhancement | [GTCRN](https://github.com/Xiaobin-Rong/gtcrn), [MIT](Licenses/GTCRN.txt) |
| Python 3.12 | Bundled interpreter | [PSF license](https://docs.python.org/3/license.html), also included in the Python runtime |
| PyTorch | Model execution | [PyTorch](https://github.com/pytorch/pytorch), BSD-style license in bundled package metadata |
| NumPy | Audio/numerical operations | [NumPy](https://github.com/numpy/numpy), BSD-3-Clause, included package license |
| ONNX Runtime | ONNX model execution | [ONNX Runtime](https://github.com/microsoft/onnxruntime), MIT, included package license |
| sherpa-onnx | VAD and speaker runtime | [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx), Apache 2.0, included package license |
| Apple Vision, AVFoundation, ScreenCaptureKit, Translation | Native capture/OCR/translation | Apple system frameworks, supplied by macOS |

**Noncommercial model weights / Некоммерческие веса.** Silero TTS and audEERING models are distributed with their attribution and CC BY-NC-SA 4.0 notices. Their noncommercial/share-alike terms remain applicable; the MIT application license does not grant commercial rights to those weights. No changes to these upstream weights are made in this release.

The ready-to-use app retains third-party package metadata and license files in `Contents/Resources/Python`. Source distributions include model download scripts and checksum manifests, not model binaries. Consult upstream terms for any replacement models.

В готовом приложении сохранены метаданные и лицензии зависимостей в `Contents/Resources/Python`. Репозиторий содержит скрипты загрузки и контрольные суммы, а не бинарные веса моделей. Модели работают локально; OpenAI APIs в приложении не используются.

PlayStation, PS5 and game names are trademarks of their respective owners. No game assets or recordings are included in the public release. The included profile contains only user-configurable subtitle and voice settings.
