#!/bin/bash
# Builds "build/File Trail.app" from the Swift package, signed ad hoc. Says each step; the build log goes to build/logs/build-app.log.
# Usage: scripts/build-app.sh [release|debug] [--out <folder>] [--verbose]
# --out names the folder the app goes in (scripts/make-release-app.sh).
# --verbose shows the build's output as it comes.
set -euo pipefail
cd "$(dirname "$0")/.."

config=release
out=build
verbose=0
while [ $# -gt 0 ]; do
    case "$1" in
        release | debug) config="$1" ;;
        --out)
            out="$2"
            shift
            ;;
        --verbose) verbose=1 ;;
        *)
            echo "Unknown argument '$1'." >&2
            exit 1
            ;;
    esac
    shift
done
# The bundled fd is built for Apple silicon, and so is the app.
if [ "$(uname -m)" != arm64 ]; then
    echo "File Trail builds on Apple silicon only; this Mac is $(uname -m)." >&2
    exit 1
fi
mkdir -p build/logs "$out"
log=build/logs/build-app.log
# With --verbose, SwiftPM's output as it comes. Otherwise, in a terminal, its latest [done/total] line, rewritten in
# place. A release build shows a module only when it's finished, and FTAppKit alone takes most of the time.
show_progress() {
    if [ "$verbose" = 1 ]; then
        cat
    elif [ -t 1 ]; then
        awk '/^\[[0-9]+\/[0-9]+\] / { printf "\r\033[K  %s %s %s", $1, $2, $3; fflush() } END { printf "\r\033[K" }'
    else
        cat >/dev/null
    fi
}
echo "Compiling ($config)..."
if ! swift build -c "$config" --product FileTrail 2>&1 | tee "$log" | show_progress; then
    sed $'s/\x1b\\[[0-9;]*m//g' "$log" | grep -E 'error:|warning:' | awk '!seen[$0]++' | cut -c1-300 | head -60
    echo "build failed; full log in $log" >&2
    exit 1
fi
echo "Compiled in ${SECONDS}s. Assembling and signing..."
binary="$(swift build -c "$config" --show-bin-path)/FileTrail"

app="$out/File Trail.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary" "$app/Contents/MacOS/FileTrail"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cp -R Resources/Acknowledgements "$app/Contents/Resources/Acknowledgements"
/usr/libexec/PlistBuddy -c "Delete :FTCommit" "$app/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :FTCommit string $(git rev-parse --short HEAD)" "$app/Contents/Info.plist"
# The version comes from git. macOS shows numbers only, so a build past a release shows that release's number; the About
# window reads the full version from FTVersion.
if ! version="$(scripts/version.sh)"; then
    echo "git gives no version: build from a git checkout of the repository." >&2
    exit 1
fi
bundle_version="$(scripts/version.sh --bundle)"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $bundle_version" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $bundle_version" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :FTVersion string $version" "$app/Contents/Info.plist"
if [ "$config" = release ]; then
    strip -rSTx "$app/Contents/MacOS/FileTrail"
fi
# SwiftPM stamps the deployment target as the SDK too, and macOS gives an app built for an old SDK the old look. Stamp
# the SDK the app was built with (Liquid Glass); the minimum stays Info.plist's. The app is signed again below.
minimum="$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$app/Contents/Info.plist")"
if ! stamped="$(vtool -set-build-version macos "$minimum" "$(xcrun --show-sdk-version)" -replace \
    -output "$app/Contents/MacOS/FileTrail" "$app/Contents/MacOS/FileTrail" 2>&1)"; then
    echo "$stamped" >&2
    echo "vtool couldn't stamp the SDK on the app's binary" >&2
    exit 1
fi
# The bundled fd (search): the helper is signed first, then the app seals it. Its licences are shown from
# Resources/Acknowledgements/fd.txt.
mkdir -p "$app/Contents/Helpers"
cp Resources/fd/darwin-arm64/fd "$app/Contents/Helpers/fd"
# codesign says "replacing existing signature" each time: its output is shown only when it fails.
sign() {
    local output
    if ! output="$(codesign --force --sign - "$@" 2>&1)"; then
        echo "$output" >&2
        echo "codesign failed on ${*: -1}" >&2
        exit 1
    fi
}
sign --options runtime "$app/Contents/Helpers/fd"
sign "$app"

echo "Built $app, version $version ($(du -sh "$app" | cut -f1)) in ${SECONDS}s"
