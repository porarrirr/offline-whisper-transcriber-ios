#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$APP_ROOT/.." && pwd)"
WHISPER_ROOT="$APP_ROOT/whisper.cpp"
OUTPUT_DIR="$APP_ROOT/build/coreml-encoder-v2026.1"
RELEASE_TAG="coreml-encoder-v2026.1"
REPOSITORY="porarrirr/offline-whisper-transcriber-ios"
PUBLISH=false

if [[ "${1:-}" == "--publish" ]]; then
  PUBLISH=true
fi

command -v xcrun >/dev/null
command -v python3 >/dev/null
if $PUBLISH; then command -v gh >/dev/null; fi

python3 -m venv "$APP_ROOT/build/coreml-python"
source "$APP_ROOT/build/coreml-python/bin/activate"
python -m pip install --upgrade pip==24.2
python -m pip install --requirement "$SCRIPT_DIR/requirements.lock"

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

PATCHED_CONVERTER="$APP_ROOT/build/convert-whisper-to-coreml-ios17.py"
python - "$WHISPER_ROOT/models/convert-whisper-to-coreml.py" "$PATCHED_CONVERTER" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text()
needle = '        convert_to="mlprogram",\n'
replacement = needle + '        minimum_deployment_target=ct.target.iOS17,\n'
if source.count(needle) != 2:
    raise SystemExit("Unexpected whisper.cpp converter shape; review before generating artifacts")
Path(sys.argv[2]).write_text(source.replace(needle, replacement))
PY

export PYTHONPATH="$WHISPER_ROOT/models${PYTHONPATH:+:$PYTHONPATH}"
for model in tiny base small medium large-v3-turbo; do
  (
    cd "$WHISPER_ROOT"
    python "$PATCHED_CONVERTER" --model "$model" --encoder-only True --optimize-ane True
    xcrun coremlc compile "models/coreml-encoder-$model.mlpackage" models/
    rm -rf "models/ggml-$model-encoder.mlmodelc"
    mv "models/coreml-encoder-$model.mlmodelc" "models/ggml-$model-encoder.mlmodelc"
    find "models/ggml-$model-encoder.mlmodelc" -exec touch -t 202601010000 {} +
    (
      cd models
      find "ggml-$model-encoder.mlmodelc" -print | LC_ALL=C sort | \
        COPYFILE_DISABLE=1 /usr/bin/zip -X -q "$OUTPUT_DIR/ggml-$model-encoder.mlmodelc.zip" -@
    )
  )
done

python "$SCRIPT_DIR/write-manifest.py" \
  --assets "$OUTPUT_DIR" \
  --tag "$RELEASE_TAG" \
  --repository "$REPOSITORY" \
  --requirements "$SCRIPT_DIR/requirements.lock" \
  --output "$OUTPUT_DIR/CoreMLEncoderManifest.json"

if $PUBLISH; then
  if gh release view "$RELEASE_TAG" --repo "$REPOSITORY" >/dev/null 2>&1; then
    echo "Release $RELEASE_TAG already exists; immutable Core ML releases are never overwritten" >&2
    exit 1
  fi
  gh release create "$RELEASE_TAG" "$OUTPUT_DIR"/*.zip "$OUTPUT_DIR/CoreMLEncoderManifest.json" \
    --repo "$REPOSITORY" \
    --title "$RELEASE_TAG" \
    --notes "Reproducible Core ML encoder artifacts targeting iOS 17."
fi

echo "Copy $OUTPUT_DIR/CoreMLEncoderManifest.json to $APP_ROOT/Resources after release publication and commit it."
