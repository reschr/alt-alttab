#!/bin/bash
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_dir"

# Keep compiler and package caches inside the project for reproducible local setup.
export CLANG_MODULE_CACHE_PATH="$repo_dir/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$repo_dir/.build/module-cache"
swift build --disable-sandbox --cache-path "$repo_dir/.build/cache" \
    -Xswiftc -module-cache-path -Xswiftc "$repo_dir/.build/module-cache"
bin_dir="$(swift build --disable-sandbox --cache-path "$repo_dir/.build/cache" --show-bin-path)"
app_dir="$repo_dir/.build/AltAltTab.app"

# A bundle gives macOS a stable app identifier before we add Accessibility access.
mkdir -p "$app_dir/Contents/MacOS"
cp "$bin_dir/AltAltTab" "$app_dir/Contents/MacOS/AltAltTab"
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
codesign --force --sign - "$app_dir"
printf 'Built %s\n' "$app_dir"
