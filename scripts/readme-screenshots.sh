#!/bin/bash
# Takes the README's screenshots, as the original's were taken: a real window with its shadow, showing the Lighthouse
# demo project in /Users/Shared and a home folder called "demo". Nothing of the real home folder or settings shows.
# Usage: scripts/readme-screenshots.sh [scene...]   (no scene: all of tools/capture/readme/*.json)
# The app needs Screen Recording once: macOS asks, or allow "File Trail" in Privacy & Security. Leave the Mac alone
# while it runs (about 2 minutes): the windows have to stay in front. A disk other than the startup disk shows in the
# sidebar, so eject those first.
set -euo pipefail
cd "$(dirname "$0")/.."

project=/Users/Shared/Lighthouse
cache="${FILETRAIL_DEV_CACHE:-$HOME/Library/Caches/filetrail-dev}"
fixture="$cache/fixtures/lighthouse/Lighthouse"
out=build/readme-shots
folder=build/readme-app
app="$PWD/$folder/File Trail.app"
home_root="$cache/readme-home"

others="$(find /Volumes -mindepth 1 -maxdepth 1 ! -lname / 2>/dev/null || true)"
if [ -n "$others" ] && [ -z "${FILETRAIL_SHOTS_ANY_DISK:-}" ]; then
    echo "Eject these first, they would show in the sidebar:" >&2
    echo "$others" >&2
    exit 1
fi
[ -d "$fixture" ] || bun tools/fixtures/generate.ts
if [ -e "$project" ]; then
    echo "$project already exists: move it away first." >&2
    exit 1
fi

scripts/build-app.sh debug --out "$folder"
# The grant in Privacy & Security goes by the signature, so it lasts from one build to the next.
identity="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:.*\)"/\1/p' | head -1)"
codesign --force --sign "$identity" "$app/Contents/Helpers/fd"
codesign --force --sign "$identity" "$app"

cp -cpR "$fixture" "$project"
trap 'rm -rf "$project" "$home_root"' EXIT
swiftc -o "build/readme-photos" tools/capture/readme/photos.swift
build/readme-photos "$project/photos"
# The fixture's big files are sparse, which would show as "on disk" sizes of nothing.
python3 - "$project" <<'PY'
import os, sys
for folder, _, names in os.walk(sys.argv[1]):
    for name in names:
        path = os.path.join(folder, name)
        info = os.stat(path)
        if info.st_blocks * 512 < info.st_size:
            data = open(path, "rb").read()
            open(path, "wb").write(data)
            os.utime(path, ns=(info.st_atime_ns, info.st_mtime_ns))
PY

scenes=("$@")
if [ ${#scenes[@]} -eq 0 ]; then
    for file in tools/capture/readme/*.json; do
        name="$(basename "$file" .json)"
        [ "$name" = visited-folders ] || scenes+=("$name")
    done
fi

mkdir -p "$out" docs/screenshots
status=0
for scene in "${scenes[@]}"; do
    home="$home_root/demo"
    rm -rf "$home_root" "$out/$scene"
    mkdir -p "$out/$scene" "$home/Desktop" "$home/Documents" "$home/Downloads"
    data="$home/Library/Application Support/com.filetrail.native"
    mkdir -p "$data"
    python3 - "$project" "$data/visited-folders.json" tools/capture/readme/visited-folders.json "$scene" <<'PY'
import datetime, json, sys
project, target, source, scene = sys.argv[1:]
now = int(datetime.datetime(2026, 10, 13, 14, 40).timestamp() * 1000)
folders = json.load(open(source))
visits = lambda rank: [[now - (rank + 1) * 3600_000 - i * 60_000, "stay"] for i in range(len(folders) - rank)]
json.dump({"folders": [{"path": f"{project}/{f}", "visits": visits(r)} for r, f in enumerate(folders)]}, open(target, "w"))
prefs = {"treeWidth": 205}
if scene in ("folder-sizes", "dark-mode"):
    prefs["inspectorWidth"] = 233
    prefs["detailColumnWidths"] = {"name": 160, "modified": 150, "size": 90, "kind": 60}
json.dump({"preferences": prefs}, open(target.replace("visited-folders", "app-state"), "w"))
PY
    # By `open`, so that macOS asks about Screen Recording for this app, not for whatever started the script.
    # Launch Services can refuse while the scene before is still going away.
    for attempt in 1 2 3 4 5; do
        open -W -n --env "CFFIXED_USER_HOME=$home" --env "FILETRAIL_NOW=2026-10-13T14:46:00" \
            --stdout "$PWD/$out/$scene/app.log" --stderr "$PWD/$out/$scene/app.log" "$app" --args \
            --automation "$PWD/tools/capture/readme/$scene.json" --out "$PWD/$out/$scene" \
            --elements "$PWD/tools/capture/elements.json" --user-data-dir "$data" && break
        sleep 2
    done
    if [ -f "$out/$scene/$scene.png" ] && ! grep -q '"status" *: *"failed"' "$out/$scene/report.json"; then
        cp "$out/$scene/$scene.png" "docs/screenshots/$scene.png"
        echo "PASS $scene"
    else
        echo "FAIL $scene: see $out/$scene"
        status=1
    fi
done
exit $status
