#!/bin/sh

set -eu

if [ "$#" -ne 1 ]; then
    echo "error: Usage: $0 output-header"
    exit 1
fi

version_header="$1"
build_date="$(date '+%Y.%m.%d')"
build_time="$(date '+%H.%M')"

mkdir -p "$(dirname "${version_header}")"

{
    echo "#define WT_BUILD_DATE ${build_date}"
    echo "#define WT_BUILD_TIME ${build_time}"
} > "${version_header}"

echo "Generated build version ${build_date} (${build_time})"
