#!/bin/zsh
set -e
TASK_RUNTIME_DIR="${0:A:h}"
TASK_PYTHON="${PS_SUBTITLE_PYTHON:-python3.12}"
"$TASK_PYTHON" -c 'import sys; assert sys.version_info[:2] == (3,12), "Python 3.12 is required for the bundled runtime"'
"$TASK_PYTHON" -m venv "$TASK_RUNTIME_DIR/.venv"
"$TASK_RUNTIME_DIR/.venv/bin/python" -m pip install -r "$TASK_RUNTIME_DIR/requirements.txt"
if [[ ! -f "$TASK_RUNTIME_DIR/v5_5_ru.pt" ]]; then
    curl --fail --location --output "$TASK_RUNTIME_DIR/v5_5_ru.pt.partial" https://models.silero.ai/models/tts/ru/v5_5_ru.pt
    mv "$TASK_RUNTIME_DIR/v5_5_ru.pt.partial" "$TASK_RUNTIME_DIR/v5_5_ru.pt"
fi
curl --fail --location --output "$TASK_RUNTIME_DIR/SILERO_LICENSE.txt" https://raw.githubusercontent.com/snakers4/silero-models/master/LICENSE
shasum -a 256 "$TASK_RUNTIME_DIR/v5_5_ru.pt"
echo "Silero dependencies are ready. Run Launch.command."
if [[ ! -f "$TASK_RUNTIME_DIR/wespeaker_en_voxceleb_resnet34.onnx" ]]; then
    curl --fail --location --output "$TASK_RUNTIME_DIR/wespeaker_en_voxceleb_resnet34.onnx.partial" https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/wespeaker_en_voxceleb_resnet34.onnx
    mv "$TASK_RUNTIME_DIR/wespeaker_en_voxceleb_resnet34.onnx.partial" "$TASK_RUNTIME_DIR/wespeaker_en_voxceleb_resnet34.onnx"
fi
if [[ ! -f "$TASK_RUNTIME_DIR/silero_vad.onnx" ]]; then
    curl --fail --location --output "$TASK_RUNTIME_DIR/silero_vad.onnx.partial" https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx
    mv "$TASK_RUNTIME_DIR/silero_vad.onnx.partial" "$TASK_RUNTIME_DIR/silero_vad.onnx"
fi
"$TASK_RUNTIME_DIR/.venv/bin/python" "$TASK_RUNTIME_DIR/install_gender_model.py"
"$TASK_RUNTIME_DIR/.venv/bin/python" "$TASK_RUNTIME_DIR/install_speech_enhancer.py"
"$TASK_RUNTIME_DIR/.venv/bin/python" "$TASK_RUNTIME_DIR/install_english_model.py"
