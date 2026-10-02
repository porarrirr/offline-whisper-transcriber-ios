#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <device-udid> <pre-iCloud-app-data-directory>" >&2
  exit 2
fi

device_udid=$1
fixture_dir=$2
project_dir=$(cd "$(dirname "$0")/.." && pwd)
bundle_id=com.porarrirr.offlinewhispertranscriber
test_container=iCloud.com.porarrirr.offlinewhispertranscriber.migrationtest
derived_data="$project_dir/build/HistoryMigrationTest"
app_path="$derived_data/Build/Products/HistoryMigrationTest-iphoneos/WhisperTranscriptionApp.app"

python3 - "$fixture_dir" <<'PY'
import plistlib
import sqlite3
import sys
from pathlib import Path
from urllib.parse import quote

fixture = Path(sys.argv[1]).resolve()
store = fixture / "Library/Application Support/default.store"
preferences = fixture / "Library/Preferences/com.porarrirr.offlinewhispertranscriber.plist"
recordings = fixture / "Documents/Recordings"
if not store.is_file() or not preferences.is_file() or not recordings.is_dir():
    raise SystemExit("The pre-iCloud fixture is missing its database, preferences, or recordings.")
with sqlite3.connect(f"file:{quote(str(store))}?mode=ro&immutable=1", uri=True) as db:
    count = db.execute("SELECT COUNT(*) FROM ZTRANSCRIPTIONRECORD").fetchone()[0]
if count == 0:
    raise SystemExit("The pre-iCloud fixture has no history records.")
with preferences.open("rb") as file:
    settings = plistlib.load(file)
if any(key in settings for key in ("iCloudSyncEnabled", "historyCloudIDMigrationCompleted", "historyCloudSyncEngineState")):
    raise SystemExit("The fixture has already been used by the iCloud sync version.")
print(f"Pre-iCloud fixture: {count} history records in {fixture}")
PY

cd "$project_dir"
xcodegen generate
xcodebuild build \
  -project WhisperTranscriptionApp.xcodeproj \
  -scheme HistoryMigrationTest \
  -configuration HistoryMigrationTest \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$derived_data" \
  -allowProvisioningUpdates \
  -quiet

python3 - "$app_path" "$bundle_id" "$test_container" <<'PY'
import plistlib
import subprocess
import sys
from pathlib import Path

app = Path(sys.argv[1])
bundle_id, container_id = sys.argv[2:]
info = plistlib.loads((app / "Info.plist").read_bytes())
entitlements = plistlib.loads(subprocess.run(
    ["codesign", "-d", "--entitlements", "-", "--xml", str(app)],
    check=True, capture_output=True
).stdout)
if info.get("CFBundleIdentifier") != bundle_id:
    raise SystemExit("The built app has the wrong bundle ID.")
if info.get("HistoryCloudKitContainerIdentifier") != container_id:
    raise SystemExit("The built app points to the wrong CloudKit container.")
if entitlements.get("com.apple.developer.icloud-container-identifiers") != [container_id]:
    raise SystemExit("The signed app lacks the dedicated CloudKit container entitlement.")
if entitlements.get("com.apple.developer.icloud-container-environment") != "Development":
    raise SystemExit("The signed app is not configured for CloudKit Development.")
print("Signed test app: dedicated CloudKit Development container verified")
PY

# Reinstallation clears cached UserDefaults and the previous SwiftData store.
# The source fixture is only read; it is never modified.
xcrun devicectl device uninstall app --device "$device_udid" "$bundle_id"
xcrun devicectl device install app --device "$device_udid" "$app_path"

for relative_path in Documents 'Library/Application Support' Library/Preferences; do
  xcrun devicectl device copy to \
    --device "$device_udid" \
    --source "$fixture_dir/$relative_path" \
    --destination "$relative_path" \
    --domain-type appDataContainer \
    --domain-identifier "$bundle_id" \
    --remove-existing-content true \
    --timeout 900
done

echo "Pre-iCloud data restored. Launch the app and enable iCloud history sync in Settings."
