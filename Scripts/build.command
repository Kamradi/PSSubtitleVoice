#!/bin/zsh
set -euo pipefail
SSV_ROOT="${0:A:h:h}"
cd "$SSV_ROOT"
: "${SSV_SIGNING_IDENTITY:=-}"
export SSV_SIGNING_IDENTITY
xcodebuild -project PSSubtitleVoice.xcodeproj -scheme PSSubtitleVoice \
  -configuration Release -derivedDataPath build \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$SSV_SIGNING_IDENTITY" DEVELOPMENT_TEAM= build
"$SSV_ROOT/Runtime/.venv/bin/python" "$SSV_ROOT/Distribution/BuildRelease.py"
echo "Ready: Distribution/PS Subtitle Voice.app"
