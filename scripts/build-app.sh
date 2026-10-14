#!/bin/bash
# Builds "build/File Trail.app" from the Swift package. Quiet: the build log goes to build/logs/build-app.log.
# Usage: scripts/build-app.sh [release|debug]
set -euo pipefail
cd "$(dirname "$0")/.."

config="${1:-release}"
mkdir -p build/logs
log=build/logs/build-app.log
if ! swift build -c "$config" --product FileTrail >"$log" 2>&1; then
    sed $'s/\x1b\\[[0-9;]*m//g' "$log" | grep -E 'error:|warning:' | awk '!seen[$0]++' | cut -c1-300 | head -60
    echo "build failed; full log in $log" >&2
    exit 1
fi
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
# The bundled fd (search): the helper is signed first, then the app seals it.
mkdir -p "$app/Contents/Helpers" "$app/Contents/Resources/fd"
cp Resources/fd/darwin-arm64/fd "$app/Contents/Helpers/fd"
cp Resources/fd/manifest.json "$app/Contents/Resources/fd/manifest.json"
cp -R Resources/fd/licenses "$app/Contents/Resources/fd/licenses"
codesign --force --sign - --options runtime "$app/Contents/Helpers/fd" >/dev/null 2>&1
codesign --force --sign - "$app" >/dev/null 2>&1

echo "Built $app ($(du -sh "$app" | cut -f1))"
