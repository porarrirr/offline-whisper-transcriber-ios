#!/usr/bin/env bash
# Sign all framework slices inside whisper.xcframework with the local Apple Development identity.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
XCFRAMEWORK="${1:-$ROOT/Frameworks/whisper.xcframework}"

if [[ ! -d "$XCFRAMEWORK" ]]; then
  echo "error: xcframework not found: $XCFRAMEWORK" >&2
  exit 1
fi

resolve_sign_identity() {
  if [[ -n "${CODE_SIGN_IDENTITY:-}" && "${CODE_SIGN_IDENTITY}" != "-" ]]; then
    echo "$CODE_SIGN_IDENTITY"
    return
  fi

  local line identity
  while IFS= read -r line; do
    [[ "$line" != *\"Apple\ Development* ]] && continue
    identity="${line#*\"}"
    identity="${identity%\"*}"
    echo "$identity"
    return
  done < <(security find-identity -v -p codesigning)

  echo "error: no Apple Development signing identity found in Keychain" >&2
  exit 1
}

verify_team_if_requested() {
  local expected_team="${DEVELOPMENT_TEAM:-}"
  [[ -z "$expected_team" ]] && return

  local sample_framework
  sample_framework="$(find "$XCFRAMEWORK" -name '*.framework' -type d | head -1)"
  [[ -z "$sample_framework" ]] && return

  local actual_team
  actual_team="$(codesign -dvv "$sample_framework" 2>&1 | awk -F= '/TeamIdentifier/ {print $2; exit}')"
  if [[ "$actual_team" != "$expected_team" ]]; then
    echo "error: signed TeamIdentifier ($actual_team) does not match DEVELOPMENT_TEAM ($expected_team)" >&2
    exit 1
  fi
}

IDENTITY="$(resolve_sign_identity)"
echo "Signing whisper.xcframework with: $IDENTITY"

while IFS= read -r -d '' framework; do
  echo "  -> $framework"
  codesign --force \
    --sign "$IDENTITY" \
    --timestamp \
    --generate-entitlement-der \
    "$framework"
  codesign --verify --verbose=2 "$framework"
done < <(find "$XCFRAMEWORK" -name '*.framework' -type d -print0)

verify_team_if_requested
echo "Done: $XCFRAMEWORK"
