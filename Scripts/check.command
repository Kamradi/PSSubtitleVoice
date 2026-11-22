#!/bin/zsh
set -euo pipefail
SSV_ROOT="${0:A:h:h}"
SSV_CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ssv-checks.XXXXXX")"
cd "$SSV_ROOT"
for SSV_CHECK in RepeatRegression PlateFilter CaptureWorker; do
  SSV_SOURCES=(PSSubtitleVoice/DiagnosticLog.swift PSSubtitleVoice/SubtitleRecognition.swift PSSubtitleVoice/GameProfile.swift)
  if [[ "$SSV_CHECK" == CaptureWorker ]]; then SSV_SOURCES+=(PSSubtitleVoice/CaptureFrameWorker.swift); fi
  xcrun swiftc -module-cache-path "$SSV_CHECK_DIR/modules" "${SSV_SOURCES[@]}" \
    "Checks/$SSV_CHECK/main.swift" -o "$SSV_CHECK_DIR/$SSV_CHECK"
  "$SSV_CHECK_DIR/$SSV_CHECK"
done
xcrun swiftc -module-cache-path "$SSV_CHECK_DIR/modules" PSSubtitleVoice/GameProfile.swift Checks/Games/main.swift -o "$SSV_CHECK_DIR/Games"
"$SSV_CHECK_DIR/Games"
xcrun swiftc -module-cache-path "$SSV_CHECK_DIR/modules" PSSubtitleVoice/GameProfile.swift Checks/Preset/main.swift -o "$SSV_CHECK_DIR/Preset"
"$SSV_CHECK_DIR/Preset"
"Runtime/.venv/bin/python" -m unittest discover -s Runtime -p 'test_*.py'
echo "Checks passed. Temporary outputs: $SSV_CHECK_DIR"
