#!/usr/bin/env bash
# Build whisper.xcframework with iOS device + simulator slices (iPhone/iPad).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WHISPER_DIR="$ROOT/whisper.cpp"
OUTPUT="$ROOT/Frameworks/whisper.xcframework"

cd "$WHISPER_DIR"
WHISPER_IOS_ONLY=ON ./build-xcframework.sh

rm -rf "$OUTPUT"
xcodebuild -create-xcframework \
  -framework "$WHISPER_DIR/build-ios-sim/framework/whisper.framework" \
  -debug-symbols "$WHISPER_DIR/build-ios-sim/dSYMs/whisper.dSYM" \
  -framework "$WHISPER_DIR/build-ios-device/framework/whisper.framework" \
  -debug-symbols "$WHISPER_DIR/build-ios-device/dSYMs/whisper.dSYM" \
  -output "$OUTPUT"
"$ROOT/Scripts/sign-whisper-xcframework.sh" "$OUTPUT"

echo "Installed: $OUTPUT"
