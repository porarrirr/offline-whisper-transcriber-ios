#!/bin/sh

set -eu

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    echo "error: Usage: $0 target-Info.plist [version-source-Info.plist]"
    exit 1
fi

info_plist="$1"

if [ ! -f "${info_plist}" ]; then
    echo "error: Target Info.plist was not found at ${info_plist}"
    exit 1
fi

if [ "$#" -eq 2 ]; then
    version_source_plist="$2"
    if [ ! -f "${version_source_plist}" ]; then
        echo "error: Version source Info.plist was not found at ${version_source_plist}"
        exit 1
    fi

    build_date="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${version_source_plist}")"
    build_time="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${version_source_plist}")"
else
    build_date="$(date '+%Y.%m.%d')"
    build_time="$(date '+%H.%M')"
fi

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${build_date}" "${info_plist}"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${build_time}" "${info_plist}"

echo "Set ${PRODUCT_NAME} version to ${build_date} (${build_time})"
