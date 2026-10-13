#!/bin/bash
# Builds "build/File Trail.app" from the Swift package.
# Usage: scripts/build-app.sh [release|debug]
set -euo pipefail
cd "$(dirname "$0")/.."

config="${1:-release}"
swift build -c "$config"
binary="$(swift build -c "$config" --show-bin-path)/FileTrail"

app="build/File Trail.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary" "$app/Contents/MacOS/FileTrail"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
if [ "$config" = release ]; then
    strip -rSTx "$app/Contents/MacOS/FileTrail"
fi
codesign --force --sign - "$app" >/dev/null

echo "Built $app ($(du -sh "$app" | cut -f1))"
