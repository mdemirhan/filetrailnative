#!/bin/bash
# UI capture pipeline (PLAN.md §5.4): runs each scenario in the original Electron app and in the native
# app, compares geometry and pixels, and writes tools/capture/out/contact.html.
# Usage: tools/capture/run.sh [--tier wp|wave|final] [--selftest] [scenario...]
#   A scenario is a name from tools/capture/scenarios (without .json) or a path. None means all.
#   --tier wp (default) only reports differences; wave and final also fail on a geometry miss.
#   --selftest captures the first scenario natively and compares it with itself: both diffs must be zero.
# Exit codes: 0 done, 1 geometry miss (wave/final only), 2 usage, 3 pipeline failure.
set -uo pipefail
cd "$(dirname "$0")/../.."
repo="$PWD"

tier=wp
selftest=0
names=()
while [ $# -gt 0 ]; do
    case "$1" in
    --tier)
        tier="${2:-}"
        shift 2
        ;;
    --selftest)
        selftest=1
        shift
        ;;
    -h | --help)
        sed -n '2,8p' "$0"
        exit 0
        ;;
    -*)
        echo "unknown option $1" >&2
        exit 2
        ;;
    *)
        names+=("$1")
        shift
        ;;
    esac
done
case "$tier" in wp | wave | final) ;; *)
    echo "--tier takes wp, wave or final" >&2
    exit 2
    ;;
esac

cache="${FILETRAIL_PORT_CACHE:-$HOME/Library/Caches/filetrail-port}"
export FILETRAIL_FIXTURES="${FILETRAIL_FIXTURES:-$cache/fixtures}"
commit="$(grep -o '"referenceCommit": *"[^"]*"' docs/port/state/orchestrator.json | sed 's/.*: *"\(.*\)"/\1/')"
out=tools/capture/out
logs=build/logs
mkdir -p "$logs"

scenarios=()
if [ ${#names[@]} -eq 0 ]; then
    for file in tools/capture/scenarios/*.json; do scenarios+=("$file"); done
else
    for name in "${names[@]}"; do
        if [ -f "$name" ]; then scenarios+=("$name"); else scenarios+=("tools/capture/scenarios/$name.json"); fi
    done
fi
for file in "${scenarios[@]}"; do
    [ -f "$file" ] || {
        echo "no scenario $file" >&2
        exit 2
    }
done
if [ "$selftest" = 1 ]; then scenarios=("${scenarios[0]}"); fi

# Runs a command with a time limit (seconds), without coreutils.
limit() {
    local seconds="$1"
    shift
    perl -e 'alarm shift; exec @ARGV or die "exec: $!"' "$seconds" "$@"
}

# A value from a scenario file: field <file> <key>.
field() {
    bun -e 'const s = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); const v = process.argv[2].split(".").reduce((o, k) => o?.[k], s); if (v !== undefined) console.log(Array.isArray(v) ? v.join("\n") : v)' "$1" "$2"
}

# Builds: the debug app (automation mode is debug only), copied aside so a release build can't replace it.
if ! scripts/build-app.sh debug >"$logs/capture-build.log" 2>&1; then
    cat "$logs/capture-build.log" >&2
    exit 3
fi
mkdir -p build/capture
rm -rf "build/capture/File Trail.app"
cp -R "build/File Trail.app" "build/capture/File Trail.app"
app="$repo/build/capture/File Trail.app/Contents/MacOS/FileTrail"
pixeldiff="$(tools/pixeldiff/build.sh)" || exit 3

rm -rf "$out"
mkdir -p "$out"
status=0

capture_swift() { # <scenario> <dir> <now>
    rm -rf "$2"
    mkdir -p "$2"
    if [ -n "$3" ]; then
        FILETRAIL_NOW="$3" limit 600 "$app" --automation "$1" --out "$2" >>"$logs/capture-swift.log" 2>&1
    else
        limit 600 "$app" --automation "$1" --out "$2" >>"$logs/capture-swift.log" 2>&1
    fi
}

capture_electron() { # <scenario> <dir> <now>
    local hash cached tmp
    hash="$(cat "$1" tools/capture/elements.json tools/capture/electron/driver.ts | shasum -a 256 | cut -c1-16)"
    cached="$cache/captures/$commit/$hash"
    if [ ! -f "$cached/.complete" ]; then
        if [ ! -d "$cache/reference/electron/apps/desktop/dist/main" ]; then
            echo "the reference app is not built: run tools/reference/setup.sh" >"$logs/capture-electron.log"
            return 1
        fi
        tmp="$cache/captures/$commit/.tmp-$hash-$$"
        rm -rf "$tmp"
        mkdir -p "$tmp"
        if ! FILETRAIL_NOW="$3" limit 600 bun tools/capture/electron/driver.ts --scenario "$1" --out "$tmp" \
            >>"$logs/capture-electron.log" 2>&1; then
            rm -rf "$2"
            mv "$tmp" "$2"
            return 1
        fi
        # Only a run where every step worked is reused.
        if grep -qE '"status": "(failed|timeout)"' "$tmp/report.json"; then
            rm -rf "$2"
            mv "$tmp" "$2"
            return 0
        fi
        touch "$tmp/.complete"
        rm -rf "$cached"
        mv "$tmp" "$cached"
    fi
    rm -rf "$2"
    cp -R "$cached" "$2"
}

: >"$logs/capture-swift.log"
: >"$logs/capture-electron.log"
for file in "${scenarios[@]}"; do
    name="$(basename "$file" .json)"
    dir="$out/$name"
    now="$(field "$file" now)"
    # Folders the scenario needs that the fixture doesn't have (an empty folder), dated to its clock.
    while IFS= read -r folder; do
        [ -n "$folder" ] || continue
        folder="${folder/#\~/$HOME}"
        mkdir -p "$folder"
        [ -n "$now" ] && touch -t "$(echo "$now" | sed -E 's/^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2}).*/\1\2\3\4\5.\6/')" "$folder"
    done < <(field "$file" setup.emptyFolders)

    if ! capture_swift "$file" "$dir/swift" "$now"; then
        echo "$name  PIPELINE: the native app did not finish (see $logs/capture-swift.log)"
        status=3
        continue
    fi
    if [ "$selftest" = 1 ]; then
        bun tools/capture/report.ts compare --scenario "$file" --a "$dir/swift" --b "$dir/swift" --out "$dir/diff" \
            --pixeldiff "$pixeldiff" --label-a swift --label-b swift
        result=$?
        summary="$dir/diff/summary.json"
        if [ "$result" -ne 0 ] || ! grep -q '"pixels": 0,' "$summary" || ! grep -q '"off": 0,' "$summary"; then
            echo "selftest: FAILED (a capture compared with itself must show no difference)"
            status=3
        else
            echo "selftest: passed"
        fi
        continue
    fi
    if ! capture_electron "$file" "$dir/electron" "$now"; then
        echo "$name  PIPELINE: the Electron driver failed (see $logs/capture-electron.log)"
        status=3
        continue
    fi
    bun tools/capture/report.ts compare --scenario "$file" --a "$dir/electron" --b "$dir/swift" --out "$dir/diff" \
        --pixeldiff "$pixeldiff"
    case $? in
    0) ;;
    1) if [ "$tier" != wp ] && [ "$status" -eq 0 ]; then status=1; fi ;;
    *) status=3 ;;
    esac
done

bun tools/capture/report.ts contact --out "$out" || status=3
echo "contact sheet: $out/contact.html"
exit "$status"
