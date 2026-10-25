#!/bin/bash
set -euo pipefail
source_dir="$(cd "$(dirname "$0")" && pwd)"
output_dir="${BICKRIPASS_OUTPUT_DIR:-$source_dir/build}"
build_dir="$source_dir/.build"
app_dir="$output_dir/BickRipassRingtones.app"
mkdir -p "$build_dir/module-cache" "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
/usr/bin/xcrun swiftc -swift-version 5 -O -module-cache-path "$build_dir/module-cache" -target "$(uname -m)-apple-macosx14.0" "$source_dir"/Sources/*.swift -o "$build_dir/BickRipassRingtones" -lsqlite3
/bin/cp "$build_dir/BickRipassRingtones" "$app_dir/Contents/MacOS/BickRipassRingtones.new"
/bin/mv -f "$app_dir/Contents/MacOS/BickRipassRingtones.new" "$app_dir/Contents/MacOS/BickRipassRingtones"
/bin/cp "$source_dir/Resources/Info.plist" "$app_dir/Contents/Info.plist"
/bin/cp "$source_dir/Resources/BickRipassRingtones.icns" "$app_dir/Contents/Resources/"
if [ -n "${BICKRIPASS_DATA_DIR:-}" ]; then
  /usr/bin/plutil -replace BickRipassRingtonesDataDirectory -string "$BICKRIPASS_DATA_DIR" "$app_dir/Contents/Info.plist"
fi
/usr/bin/codesign --force --sign - "$app_dir"
printf '\nNative BickRipassRingtones built: %s\n' "$app_dir"
