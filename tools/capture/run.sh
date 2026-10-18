#!/bin/bash
# UI capture pipeline (PLAN.md §5.4): runs each scenario in the original Electron app and in the native
# app, compares geometry and pixels, and writes tools/capture/out/contact.html.
# Usage: tools/capture/run.sh [--tier wp|checkpoint|wave|final] [--acceptance] [--selftest]
#          [--refresh-original <scenario...>] [scenario...]
#   A scenario is a name from tools/capture/scenarios (without .json), acceptance/<name>, or a path.
#   None means every scenario tagged with the tier (scenarios/ and scenarios/acceptance/).
#   --tier wp (default) and checkpoint only report differences; wave and final also fail on a geometry miss.
#   --tier checkpoint runs the scenarios and acceptance flows tagged checkpoint (README: the checkpoint set).
#   --acceptance runs only the acceptance flows (scenarios/acceptance, PLAN.md §3.4a).
#   --refresh-original <scenario...> runs those scenarios and captures the original app again for them
#   (it takes the names after it, up to the next option).
#   --selftest compares a native capture and an Electron capture each with itself (no difference
#   allowed), and a hand-made pair of geometry dumps with known offsets (report.ts selftest).
#   FILETRAIL_CAPTURE_TIMEOUT (seconds, default 120) kills an app run that takes longer.
# The original's captures are cached per scenario (see capture_electron) and taken once.
# Exit codes: 0 done, 1 geometry miss (wave/final only), 2 usage, 3 pipeline failure.
set -uo pipefail
cd "$(dirname "$0")/../.."
repo="$PWD"

tier=wp
selftest=0
acceptance=0
names=()
refresh=()
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
    --acceptance)
        acceptance=1
        shift
        ;;
    --refresh-original)
        shift
        [ $# -gt 0 ] && [ "${1:0:1}" != - ] || {
            echo "--refresh-original takes one or more scenarios" >&2
            exit 2
        }
        while [ $# -gt 0 ] && [ "${1:0:1}" != - ]; do
            refresh+=("$1")
            names+=("$1")
            shift
        done
        ;;
    -h | --help)
        sed -n '2,17p' "$0"
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
case "$tier" in wp | checkpoint | wave | final) ;; *)
    echo "--tier takes wp, checkpoint, wave or final" >&2
    exit 2
    ;;
esac

cache="${FILETRAIL_PORT_CACHE:-$HOME/Library/Caches/filetrail-port}"
export FILETRAIL_FIXTURES="${FILETRAIL_FIXTURES:-$cache/fixtures}"
commit="$(grep -o '"referenceCommit": *"[^"]*"' docs/port/state/orchestrator.json | sed 's/.*: *"\(.*\)"/\1/')"
out=tools/capture/out
logs=build/logs
mkdir -p "$logs" build/capture
# The element names: elements.json, plus each work package's own in elements.d/*.json (a name given twice is an
# error), merged into one file both sides read.
elements="$repo/build/capture/elements.json"
if ! bun -e '
const fs = require("fs");
const [base, dir, out] = process.argv.slice(1);
const merged = JSON.parse(fs.readFileSync(base, "utf8"));
const files = fs.existsSync(dir) ? fs.readdirSync(dir).filter((f) => f.endsWith(".json")).sort() : [];
for (const file of files) {
  const extra = JSON.parse(fs.readFileSync(`${dir}/${file}`, "utf8")).elements ?? {};
  for (const [name, spec] of Object.entries(extra)) {
    if (name in merged.elements) throw new Error(`elements.d/${file}: "${name}" is already named`);
    merged.elements[name] = spec;
  }
}
fs.writeFileSync(out, JSON.stringify(merged, null, 2) + "\n");
' tools/capture/elements.json tools/capture/elements.d "$elements"; then
    echo "could not merge tools/capture/elements.d into elements.json" >&2
    exit 3
fi

# A value from a scenario file: field <file> <key> (lists print one item per line).
field() {
    bun -e 'const s = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); const v = process.argv[2].split(".").reduce((o, k) => o?.[k], s); if (v !== undefined) console.log(Array.isArray(v) ? v.join("\n") : v)' "$1" "$2"
}

# A scenario name or path as its file.
scenario_file() {
    if [ -f "$1" ]; then echo "$1"; else echo "tools/capture/scenarios/$1.json"; fi
}

scenarios=()
if [ ${#names[@]} -eq 0 ]; then
    candidates=()
    if [ "$acceptance" = 0 ]; then
        for file in tools/capture/scenarios/*.json; do candidates+=("$file"); done
    fi
    for file in tools/capture/scenarios/acceptance/*.json; do [ -f "$file" ] && candidates+=("$file"); done
    for file in "${candidates[@]}"; do
        # The acceptance flows all run with --acceptance; otherwise a scenario runs in the tiers it names.
        if [ "$acceptance" = 1 ] || field "$file" tier | grep -qx "$tier"; then scenarios+=("$file"); fi
    done
else
    for name in "${names[@]}"; do scenarios+=("$(scenario_file "$name")"); done
fi
refresh_files=" "
for name in ${refresh[@]+"${refresh[@]}"}; do refresh_files+="$(scenario_file "$name") "; done
if [ ${#scenarios[@]} -eq 0 ]; then
    echo "no scenario is tagged with tier $tier" >&2
    exit 2
fi
for file in "${scenarios[@]}"; do
    [ -f "$file" ] || {
        echo "no scenario $file" >&2
        exit 2
    }
done
if [ "$selftest" = 1 ]; then scenarios=("${scenarios[0]}"); fi

# Seconds one scenario may take in either app (the longest takes about 20 s); a stuck app is killed after it.
timeout="${FILETRAIL_CAPTURE_TIMEOUT:-120}"

# Runs a command with a time limit (seconds), without coreutils. Exit status 142 means the limit was hit.
limit() {
    local seconds="$1"
    shift
    perl -e 'alarm shift; exec @ARGV or die "exec: $!"' "$seconds" "$@"
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

# A scenario with setup.scratch changes files (fs steps, rename, paste): each side gets a fresh copy of
# its root at the same path, so both start alike and the shared fixtures are never changed.
scratch_for() { # <scenario file> → prints the scratch root, or nothing
    local file="$1" name root base
    [ "$(field "$file" setup.scratch)" = true ] || return 0
    name="$(basename "$file" .json)"
    root="$(field "$file" root)"
    root="${root/#\~/$HOME}"
    [ "${root:0:1}" = / ] || root="$FILETRAIL_FIXTURES/$root"
    base="$(basename "$root")"
    echo "$cache/work/$name/$base"
}

fresh_scratch() { # <scenario file> <scratch root>
    local file="$1" scratch="$2" root
    [ -n "$scratch" ] || return 0
    root="$(field "$file" root)"
    root="${root/#\~/$HOME}"
    [ "${root:0:1}" = / ] || root="$FILETRAIL_FIXTURES/$root"
    # Only one scenario's copy exists at a time: the folder tree shows the copy's neighbours.
    chflags -R nouchg "$cache/work" 2>/dev/null
    rm -rf "$cache/work"
    mkdir -p "$(dirname "$scratch")"
    cp -Rp "$root" "$scratch"
}

capture_swift() { # <scenario> <dir> <now> <scratch>
    rm -rf "$2"
    mkdir -p "$2"
    fresh_scratch "$1" "$4"
    FILETRAIL_NOW="$3" FILETRAIL_SCENARIO_ROOT="$4" limit "$timeout" "$app" --automation "$1" --out "$2" \
        --elements "$elements" >>"$logs/capture-swift.log" 2>&1
}

# The original app's captures are taken once per scenario and cached in
# $cache/captures/<referenceCommit>/<key>/, keyed on what changes its run: the scenario file, preferences.json
# and CAPTURE_FORMAT_VERSION in electron/driver.ts. Not on elements.json or elements.d: a name added later is
# in the original's geometry only after --refresh-original (report.ts shows it as not captured until then).
# A run that failed a step, missed an expectation or ended with a driver error is cached too, with its
# report and exit status; only a run the time limit killed, or one that wrote no report, is not.
format="$(grep -Eo '^const CAPTURE_FORMAT_VERSION = [0-9]+' tools/capture/electron/driver.ts | grep -Eo '[0-9]+$')"
if [ -z "$format" ]; then
    echo "tools/capture/electron/driver.ts has no CAPTURE_FORMAT_VERSION" >&2
    exit 3
fi
launched=0
reused=0

capture_electron() { # <scenario> <dir> <now> <scratch>
    local hash cached tmp result
    hash="$({
        echo "capture-format $format"
        cat "$1" tools/capture/preferences.json
    } | shasum -a 256 | cut -c1-16)"
    cached="$cache/captures/$commit/$hash"
    case "$refresh_files" in *" $1 "*) rm -rf "$cached" ;; esac
    if [ -f "$cached/.complete" ]; then
        reused=$((reused + 1))
        echo "$(basename "$1" .json): original from cache $cached" >>"$logs/capture-electron.log"
    else
        if [ ! -d "$cache/reference/electron/apps/desktop/dist/main" ]; then
            echo "the reference app is not built: run tools/reference/setup.sh" >>"$logs/capture-electron.log"
            return 1
        fi
        tmp="$cache/captures/$commit/.tmp-$hash-$$"
        rm -rf "$tmp"
        mkdir -p "$tmp"
        fresh_scratch "$1" "$4"
        launched=$((launched + 1))
        echo "$(basename "$1" .json): launching the original app" >>"$logs/capture-electron.log"
        FILETRAIL_NOW="$3" FILETRAIL_SCENARIO_ROOT="$4" limit "$timeout" bun tools/capture/electron/driver.ts \
            --scenario "$1" --out "$tmp" --elements "$elements" >>"$logs/capture-electron.log" 2>&1
        result=$?
        if [ "$result" -eq 142 ] || [ ! -f "$tmp/report.json" ]; then
            rm -rf "$2"
            mv "$tmp" "$2"
            return 1
        fi
        echo "$result" >"$tmp/.exit"
        touch "$tmp/.complete"
        rm -rf "$cached"
        mv "$tmp" "$cached"
    fi
    rm -rf "$2"
    cp -R "$cached" "$2"
    [ "$(cat "$cached/.exit" 2>/dev/null || echo 0)" = 0 ]
}

# Whether a compare found no difference at all: compared_clean <summary.json>.
compared_clean() {
    bun -e 'const s = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); const g = s.geometry; process.exit(s.pixels === 0 && g.off === 0 && g.missingA === 0 && g.missingB === 0 && s.problems.length === 0 ? 0 : 1)' "$1"
}

: >"$logs/capture-swift.log"
: >"$logs/capture-electron.log"
for file in "${scenarios[@]}"; do
    name="$(basename "$file" .json)"
    dir="$out/$name"
    now="$(field "$file" now)"
    scratch="$(scratch_for "$file")"
    # Folders the scenario needs that the fixture doesn't have (an empty folder), dated to its clock.
    while IFS= read -r folder; do
        [ -n "$folder" ] || continue
        folder="${folder/#\~/$HOME}"
        mkdir -p "$folder"
        [ -n "$now" ] && touch -t "$(echo "$now" | sed -E 's/^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2}).*/\1\2\3\4\5.\6/')" "$folder"
    done < <(field "$file" setup.emptyFolders)

    capture_swift "$file" "$dir/swift" "$now" "$scratch"
    result=$?
    if [ "$result" -eq 142 ]; then
        echo "$name  PIPELINE: the native app was killed after ${timeout} s (FILETRAIL_CAPTURE_TIMEOUT)"
        status=3
        continue
    elif [ "$result" -ne 0 ]; then
        echo "$name  PIPELINE: the native app did not finish (see $logs/capture-swift.log)"
        status=3
        continue
    fi
    if [ "$selftest" = 1 ]; then
        bun tools/capture/report.ts compare --scenario "$file" --a "$dir/swift" --b "$dir/swift" --out "$dir/diff" \
            --pixeldiff "$pixeldiff" --label-a swift --label-b swift >/dev/null
        result=$?
        if [ "$result" -ne 0 ] || ! compared_clean "$dir/diff/summary.json"; then
            echo "selftest swift: FAILED (a native capture compared with itself must show no difference)"
            status=3
        else
            echo "selftest swift: passed"
        fi
        if ! capture_electron "$file" "$dir/electron" "$now" "$scratch"; then
            echo "selftest electron: FAILED (the Electron driver failed, see $logs/capture-electron.log)"
            status=3
        else
            bun tools/capture/report.ts compare --scenario "$file" --a "$dir/electron" --b "$dir/electron" \
                --out "$dir/diff-electron" --pixeldiff "$pixeldiff" --label-a electron --label-b electron >/dev/null
            result=$?
            if [ "$result" -ne 0 ] || ! compared_clean "$dir/diff-electron/summary.json"; then
                echo "selftest electron: FAILED (an Electron capture compared with itself must show no difference)"
                status=3
            else
                echo "selftest electron: passed"
            fi
        fi
        bun tools/capture/report.ts selftest --out "$out/selftest-known-offsets" || status=3
        continue
    fi
    if ! capture_electron "$file" "$dir/electron" "$now" "$scratch"; then
        echo "$name  PIPELINE: the Electron driver failed (see $logs/capture-electron.log; a cached failure reruns with --refresh-original $name)"
        status=3
        continue
    fi
    bun tools/capture/report.ts compare --scenario "$file" --a "$dir/electron" --b "$dir/swift" --out "$dir/diff" \
        --pixeldiff "$pixeldiff" --elements "$elements"
    case $? in
    0) ;;
    1) if [ "$tier" != wp ] && [ "$status" -eq 0 ]; then status=1; fi ;;
    *) status=3 ;;
    esac
done

bun tools/capture/report.ts contact --out "$out" || status=3
echo "contact sheet: $out/contact.html"
echo "original app: launched $launched times, $reused captures from the cache" | tee -a "$logs/capture-electron.log"
exit "$status"
