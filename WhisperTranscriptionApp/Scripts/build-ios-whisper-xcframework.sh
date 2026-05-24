#!/usr/bin/env bash
# Build whisper.xcframework with iOS device + simulator slices (iPhone/iPad).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WHISPER_DIR="$ROOT/whisper.cpp"
OUTPUT="$ROOT/Frameworks/whisper.xcframework"

cd "$WHISPER_DIR"
WHISPER_IOS_ONLY=ON ./build-xcframework.sh

rm -rf "$OUTPUT"
cp -R "$WHISPER_DIR/build-apple/whisper.xcframework" "$OUTPUT"
"$ROOT/Scripts/sign-whisper-xcframework.sh" "$OUTPUT"

echo "Installed: $OUTPUT"
