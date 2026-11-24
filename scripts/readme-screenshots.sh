#!/bin/bash
# Takes the README's screenshots of a real window with its shadow, showing the Lighthouse demo project in
# /Users/Shared and a home folder called "demo". Nothing of the real home folder or settings shows.
# Usage: scripts/readme-screenshots.sh [scene...]   (no scene: all of tools/capture/readme/*.json)
# The app needs Screen Recording once: macOS asks, or allow "File Trail" in Privacy & Security. A scene with a sheet or a
# popover takes the screen as well, and macOS may ask again over the window: answer Allow and the picture is taken
# again; a window still over it after two minutes fails the scene. Leave the Mac alone otherwise while it runs (about 2
# minutes): the windows have to stay in front. A disk other than the startup disk shows in the
# sidebar, so eject those first.
# A new picture is a new scene: tools/capture/readme/<name>.json ends in a windowShot (or marqueeShot) called <name>,
# and lands in docs/screenshots/<name>.png. When the UI changes, run this again and every picture is taken again; a
# scene whose step no longer works fails by name. At the end it names any picture README.md or docs/features.md shows
# that no scene makes, and any picture in docs/screenshots that neither shows.
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
[ -d "$fixture" ] || bun tools/fixtures/generate.ts lighthouse
if [ -e "$project" ]; then
    echo "$project already exists: move it away first." >&2
    exit 1
fi

# The grant in Privacy & Security goes by the signature, so it lasts from one build to the next.
identity="${MACOS_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:.*\)"/\1/p' | head -1)}"
if [ -z "$identity" ]; then
    echo "No Developer ID Application identity in the keychain to sign the app with: set MACOS_SIGN_IDENTITY to the name or SHA-1 of a code signing identity there." >&2
    exit 1
fi

scripts/build-app.sh debug --out "$folder"
codesign --force --sign "$identity" "$app"

# The demo project and home are taken away however the script ends, a copy cut short too. Neither was there before.
trap 'rm -rf "$project" "$home_root"' EXIT
cp -cpR "$fixture" "$project"
swiftc -o "build/readme-photos" tools/capture/readme/photos.swift
build/readme-photos "$project/photos" tools/capture/readme/photos
# The paste-conflict scene pastes design/screens into mobile, which has a screens folder of its own with two of the
# five pictures. The folder around it keeps its date, which the folder-sizes scene shows.
mkdir "$project/mobile/screens"
cp -p "$project/design/screens/home.png" "$project/design/screens/map.png" "$project/mobile/screens/"
touch -r "$project/design/screens" "$project/mobile/screens"
touch -r "$project/mobile/README.md" "$project/mobile"
mkdir -p "$out"
# The fixture's text files are placeholders; the scenes that show a file's text get real ones, each file and its
# folder keeping their dates.
(cd tools/capture/readme/files && find . -type f) | while read -r file; do
    target="$project/${file#./}"
    touch -r "$target" "$out/file-time"
    touch -r "$(dirname "$target")" "$out/folder-time"
    cp "tools/capture/readme/files/${file#./}" "$target"
    touch -r "$out/file-time" "$target"
    touch -r "$out/folder-time" "$(dirname "$target")"
done
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
if scene == "two-panes":
    prefs["detailColumnWidths"] = {"name": 190, "modified": 150, "size": 90, "kind": 60}
if scene in ("viewer", "markdown-pane"):
    prefs["detailColumnWidths"] = {"name": 200, "modified": 150, "size": 70, "kind": 60}
# A kind the Mac's own apps name (a Zed.app Document) stays out of these pictures.
if scene in ("viewer", "markdown-pane", "folder-view"):
    prefs["detailColumns"] = {"kind": False}
json.dump({"preferences": prefs}, open(target.replace("visited-folders", "app-state"), "w"))
PY
    # The two-panes scene copies three photos into a folder that holds four already. Only that scene has the folder.
    if [ "$scene" = two-panes ]; then
        touch -r "$project" "$out/project-time"
        mkdir "$project/Portfolio"
        for name in "Desert dusk" "Fuji at dawn" "Lake Wanaka" "Milford Sound"; do
            cp -p "$project/photos/$name.jpg" "$project/Portfolio/"
        done
    fi
    # By `open`, so that macOS asks about Screen Recording for this app, not for whatever started the script.
    # Launch Services can refuse while the scene before is still going away.
    # Dates and numbers follow the region; the pictures show US English's formats whatever this Mac is set to.
    for attempt in 1 2 3 4 5; do
        open -W -n --env "CFFIXED_USER_HOME=$home" --env "FILETRAIL_NOW=2026-10-13T14:46:00" \
            --stdout "$PWD/$out/$scene/app.log" --stderr "$PWD/$out/$scene/app.log" "$app" --args \
            --automation "$PWD/tools/capture/readme/$scene.json" --out "$PWD/$out/$scene" \
            --elements "$PWD/tools/capture/elements.json" --user-data-dir "$data" -AppleLocale en_US && break
        sleep 2
    done
    if [ "$scene" = two-panes ]; then
        rm -rf "$project/Portfolio"
        touch -r "$out/project-time" "$project"
    fi
    # A step the app couldn't do as asked (unsupported) leaves a picture that isn't the scene: that fails too.
    if [ -f "$out/$scene/$scene.png" ] && ! grep -qE '"status" *: *"(failed|timeout|unsupported)"' "$out/$scene/report.json"; then
        cp "$out/$scene/$scene.png" "docs/screenshots/$scene.png"
        echo "PASS $scene"
    else
        echo "FAIL $scene: see $out/$scene"
        status=1
    fi
done

# What the pages show against what the scenes make.
shown="$(grep -ohE 'screenshots/[a-z0-9-]+\.png' README.md docs/features.md | sed 's|.*/||; s|\.png$||' | sort -u)"
for name in $shown; do
    if [ ! -f "tools/capture/readme/$name.json" ] || [ ! -f "docs/screenshots/$name.png" ]; then
        echo "FAIL $name is shown in README.md or docs/features.md, and no scene makes it"
        status=1
    fi
done
for file in docs/screenshots/*.png; do
    name="$(basename "$file" .png)"
    if ! echo "$shown" | grep -qx "$name"; then
        echo "FAIL $file is shown in neither README.md nor docs/features.md: remove it and its scene, or show it"
        status=1
    fi
done
exit $status
