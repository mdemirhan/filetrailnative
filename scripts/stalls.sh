#!/bin/bash
# Usage: scripts/stalls.sh [--views icons,list,compact] [--runs <n>] [--cold] [--out <file>] [--against <file>] [<folder>[:<views>]...]
#
# Measures on demand how long the main thread is held while large folders are opened, gone back into and filtered: the
# blocks scrolling's frame times never see (docs/decisions/code.md, "Speed is measured on demand, in the worst cases").
# For each folder (the fixture large/files-3000 if none is named) and each view at its smallest size (Icons 32 pt, the
# List with five columns, the Compact List 160 pt; a folder followed by :icons,compact is measured in those alone), in a
# maximized window, each run:
#   - launches into the folder, as a window kept maximized on it opens, and quits after 6 s;
#   - starts on its parent, goes in for the first time, scrolls 8,000 points down and back, flicks 20,000 points down and
#     back in 0.5 s (about 40 a frame, as a trackpad's flick is at its start), goes out and in again, Back, Forward,
#     types a filter a key at a time and five keys faster than the app draws, and clears it.
# The app runs in an optimized build with DEBUG defined, as tools/capture/README.md says to time it, and writes each block
# of 8 ms or more (Sources/FTFoundation/StallLog.swift); it never takes the front, so the keyboard stays with the app
# in use. Runs go behind the test lock, one at a time, as test runs do. --cold empties Quick Look's cache of previews
# (`qlmanage -r cache`) before each run, as a first visit after a while is.
#
# Each number is the median of --runs runs (3 by default), written to --out (build/stalls.json by default) and shown
# against an earlier run's file (--against). Nothing passes or fails: a Mac's numbers move by 10 to 20% with its load, so
# compare with a run made just before on the same Mac (a checkout of the other commit run with --out, then this one with
# --against that file).
set -Eeuo pipefail

CALLER_DIR="${PWD}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"
USAGE="Usage: scripts/stalls.sh [--views icons,list,compact] [--runs <n>] [--cold] [--out <file>] [--against <file>] [<folder>[:<views>]...]"

die() {
    echo "$1" >&2
    exit 1
}

absolute() { [[ "$1" == /* ]] && echo "$1" || echo "${CALLER_DIR}/$1"; }

VIEWS="icons,list,compact"
RUNS=3
COLD=0
MEASURE=0
OUT="${ROOT_DIR}/build/stalls.json"
AGAINST=""
FOLDERS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --views | --runs | --out | --against)
            [[ $# -ge 2 && -n "$2" ]] || die "${USAGE}"
            case "$1" in
                --views) VIEWS="$2" ;;
                --runs) RUNS="$2" ;;
                --out) OUT="$(absolute "$2")" ;;
                --against) AGAINST="$(absolute "$2")" ;;
            esac
            shift
            ;;
        --cold) COLD=1 ;;
        # The runs themselves, behind the test lock, once the app is built.
        --measure) MEASURE=1 ;;
        -*) die "${USAGE}" ;;
        *)
            # A folder's own views follow it after a colon.
            own=""
            path="$1"
            if [[ "$1" =~ ^(.+):((icons|list|compact)(,(icons|list|compact))*)$ ]]; then
                path="${BASH_REMATCH[1]}"
                own="${BASH_REMATCH[2]}"
            fi
            folder="$(cd "$(absolute "${path}")" 2>/dev/null && pwd)" || die "No folder at ${path}."
            FOLDERS+=("${folder}${own:+:${own}}")
            ;;
    esac
    shift
done
[[ "${RUNS}" =~ ^[1-9][0-9]*$ ]] || die "--runs takes a number of runs."
for view in ${VIEWS//,/ }; do
    [[ "${view}" == icons || "${view}" == list || "${view}" == compact ]] || die "No view called ${view}: icons, list or compact."
done
command -v bun >/dev/null || die "Bun isn't installed: the runs are written and read with tools/stalls/stalls.ts (https://bun.sh)."
[[ -z "${AGAINST}" || -r "${AGAINST}" ]] || die "${AGAINST} can't be read."
if [[ ${#FOLDERS[@]} -eq 0 ]]; then
    FIXTURE="${FILETRAIL_DEV_CACHE:-${HOME}/Library/Caches/filetrail-dev}/fixtures/large/files-3000"
    [[ -d "${FIXTURE}" ]] || die "Name the folders to measure, or build the fixture trees (bun tools/fixtures/generate.ts)."
    FOLDERS=("${FIXTURE}")
fi
for folder in "${FOLDERS[@]}"; do [[ -d "${folder%%:*}" ]] || die "No folder at ${folder%%:*}."; done

APP="build/timing-app/File Trail.app"
BINARY="${APP}/Contents/MacOS/FileTrail"
RUNS_DIR="${ROOT_DIR}/build/stalls-runs"

# One run of one folder in one view: a launch into it, then the scenario from its parent.
measure() {
    local folder="$1" view="$2" run="$3"
    local dir="${RUNS_DIR}/$(basename "${folder}").${view}.${run}"
    mkdir -p "${dir}/out"
    bun tools/stalls/stalls.ts profile "${dir}/launch-profile" "${folder}" "${view}"
    cp -R "${dir}/launch-profile" "${dir}/profile"
    bun tools/stalls/stalls.ts scenario "${dir}/scenario.json" "${folder}"
    echo "  $(basename "${folder}"), ${view}, run ${run} of ${RUNS}"
    [[ "${COLD}" == 0 ]] || qlmanage -r cache >/dev/null 2>&1
    # Quit after 6 s; in a shell of its own, which would otherwise say the app was ended.
    (
        FILETRAIL_ALLOW_MULTIPLE=1 FILETRAIL_STALLS_LOG="${dir}/launch.jsonl" \
            "${BINARY}" --user-data-dir "${dir}/launch-profile" >"${dir}/launch.log" 2>&1 &
        pid=$!
        sleep 6
        kill -TERM "${pid}" 2>/dev/null || true
        sleep 1
        kill -KILL "${pid}" 2>/dev/null || true
        wait "${pid}" || true
    ) 2>/dev/null
    [[ "${COLD}" == 0 ]] || qlmanage -r cache >/dev/null 2>&1
    FILETRAIL_STALLS_LOG="${dir}/navigation.jsonl" "${BINARY}" --automation "${dir}/scenario.json" \
        --out "${dir}/out" --elements tools/capture/elements.json --user-data-dir "${dir}/profile" \
        >"${dir}/navigation.log" 2>&1 || echo "    the scenario ended badly: ${dir}/navigation.log" >&2
}

measure_all() {
    local run folder view views
    for run in $(seq 1 "${RUNS}"); do
        for folder in "${FOLDERS[@]}"; do
            views="${VIEWS}"
            [[ "${folder}" != *:* ]] || views="${folder##*:}"
            for view in ${views//,/ }; do measure "${folder%%:*}" "${view}" "${run}"; done
        done
    done
}

if [[ "${MEASURE}" == 1 ]]; then
    # Behind the lock from here: the runs of an earlier measure go, and nothing runs beside another's tests or runs.
    rm -rf "${RUNS_DIR}"
    mkdir -p "${RUNS_DIR}"
    # macOS checks a binary it hasn't seen the first time it starts it, which held a launch for seconds: a run of nothing
    # gets that out of the way.
    warm="$(mktemp -d "${TMPDIR:-/tmp}/filetrail-stalls.XXXXXX")"
    echo '{"name": "warm-up", "steps": []}' >"${warm}/scenario.json"
    FILETRAIL_STALLS_LOG="${warm}/warm.jsonl" "${BINARY}" --automation "${warm}/scenario.json" --out "${warm}" \
        --user-data-dir "${warm}/profile" >/dev/null 2>&1 || true
    rm -rf "${warm}"
    measure_all
    exit 0
fi

# The app, optimized, with DEBUG for its scenarios: a debug app with the optimized binary in it.
echo "Building the timed app..."
scripts/build-app.sh debug --out build/timing-app >/dev/null || die "The app didn't build: build/logs/build-app.log."
swift build -c release -Xswiftc -DDEBUG --scratch-path build/timing --product FileTrail >build/logs/stalls-build.log 2>&1 \
    || die "The optimized build failed: build/logs/stalls-build.log."
cp build/timing/release/FileTrail "${BINARY}"
minimum="$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "${APP}/Contents/Info.plist")"
vtool -set-build-version macos "${minimum}" "$(xcrun --show-sdk-version)" -replace -output "${BINARY}" "${BINARY}" \
    >/dev/null 2>&1 || die "The SDK couldn't be stamped on the timed app."
codesign --force --sign - "${APP}" >/dev/null 2>&1 || die "The timed app couldn't be signed."

mkdir -p "$(dirname "${OUT}")"
echo "Measuring ${#FOLDERS[@]} folder(s), ${VIEWS//,/, }, ${RUNS} run(s) each, behind the test lock..."
args=(--views "${VIEWS}" --runs "${RUNS}")
[[ "${COLD}" == 0 ]] || args+=(--cold)
scripts/with-test-lock.sh scripts/stalls.sh "${args[@]}" "${FOLDERS[@]}" --measure || die "The runs failed."

printf '\nThe main thread on %s, in ms; a frame at 120 Hz is 8.3 ms.\n' "$(sysctl -n hw.model)"
echo "Busy is the sum of its blocks of 8 ms or more; settled is when the last of 16 ms or more ended; drawn is when the"
echo "folder was first drawn (from the process's start for a launch)."
[[ -z "${AGAINST}" ]] || printf 'Against %s.\n' "${AGAINST}"
bun tools/stalls/stalls.ts summarize "${RUNS_DIR}" "${OUT}" ${AGAINST:+"${AGAINST}"}
printf '\nWritten to %s.\n' "${OUT}"
