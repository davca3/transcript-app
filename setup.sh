#!/usr/bin/env bash
# Setup script for Skribent.
# - Installs xcodegen if missing
# - Generates Xcode project from project.yml
# Models (WhisperKit + FluidAudio) are downloaded by the app on first launch.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "▸ Skribent setup"

# 1. xcodegen
if ! command -v xcodegen >/dev/null 2>&1; then
  if ! command -v brew >/dev/null 2>&1; then
    echo "✗ Homebrew not found. Install from https://brew.sh and re-run."
    exit 1
  fi
  echo "▸ Installing xcodegen via brew..."
  brew install xcodegen
fi

# 2. Generate Xcode project
echo "▸ Generating Skribent.xcodeproj"
xcodegen generate

# 2b. Install shared debug breakpoints (xcodegen wipes the .xcodeproj, so we re-install).
if [ -f "debug/Breakpoints_v2.xcbkptlist" ]; then
  BPT_DIR="Skribent.xcodeproj/xcshareddata/xcdebugger"
  mkdir -p "$BPT_DIR"
  cp debug/Breakpoints_v2.xcbkptlist "$BPT_DIR/"
  echo "▸ Installed shared breakpoints (catches Swift runtime warnings)"
fi

cat <<EOF

✓ Setup complete.

Next steps:
  1. open Skribent.xcodeproj
  2. Select the Skribent scheme and press ⌘R.
  3. On first run the app downloads:
       - WhisperKit Whisper Turbo (~600 MB)
       - FluidAudio pyannote diarization model (~50 MB)
     A banner shows progress. Subsequent launches are instant.

EOF
