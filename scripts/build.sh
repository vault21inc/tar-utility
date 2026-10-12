#!/bin/bash
set -euo pipefail

project_dir=$(cd "$(dirname "$0")/.." && pwd)
app_dir="$project_dir/dist/TarUtility.app"
binary_dir="$app_dir/Contents/MacOS"
module_cache="$project_dir/build/module-cache"
architecture=$(/usr/bin/uname -m)

mkdir -p "$binary_dir" "$module_cache"
/usr/bin/swiftc "$project_dir/Sources/main.swift" \
  -o "$binary_dir/TarUtility" \
  -target "$architecture-apple-macos15.0" \
  -framework AppKit \
  -module-cache-path "$module_cache"
cp "$project_dir/Info.plist" "$app_dir/Contents/Info.plist"
/usr/bin/plutil -lint "$app_dir/Contents/Info.plist"
echo "$app_dir"
