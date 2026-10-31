#!/bin/bash
# Benchmark run for phase gates (PLAN.md section 4): builds the release app, runs each scenario against
# the bench fixtures, writes build/bench/latest.json and compares it with budgets.json and baseline.json.
# Usage: tools/bench/run.sh [--quick] [--report-only] [--update-baseline]
set -uo pipefail
cd "$(dirname "$0")/../.."

quick=0
report_only=0
update_baseline=0
for arg in "$@"; do
    case "$arg" in
    --quick) quick=1 ;;
    --report-only) report_only=1 ;;
    --update-baseline) update_baseline=1 ;;
    *)
        echo "usage: tools/bench/run.sh [--quick] [--report-only] [--update-baseline]" >&2
        exit 2
        ;;
    esac
done

fixtures="$HOME/Library/Caches/filetrail-dev/fixtures/bench"
if [ ! -d "$fixtures/files-3000" ]; then
    echo "missing fixtures in $fixtures (see tools/fixtures/README.md)" >&2
    exit 2
fi

out=build/bench
raw="$out/raw"
rm -rf "$raw"
mkdir -p "$raw" build/logs
scripts/build-app.sh release >build/logs/bench-build.log 2>&1 || {
    cat build/logs/bench-build.log >&2
    exit 1
}
app="build/File Trail.app"
bin="$app/Contents/MacOS/FileTrail"

if [ "$quick" = 1 ]; then
    launches=3
    folders="files-3000"
    scroll_folder="files-3000"
else
    launches=5
    folders="files-300 files-3000 files-30000 files-100000"
    scroll_folder="files-30000"
fi

# Runs the app with the given arguments (hard stop after 120 s) and keeps its output in $raw/<name>.txt.
bench() {
    local name="$1"
    shift
    # A fresh state and its own instance: not the user's folders and tabs, and not handed over to a running copy.
    FILETRAIL_ALLOW_MULTIPLE=1 "$bin" --user-data-dir "$(mktemp -d)" "$@" >"$raw/$name.txt" 2>>build/logs/bench-app.log &
    local pid=$!
    (
        sleep 120
        kill "$pid" 2>/dev/null
    ) &
    local watchdog=$!
    wait "$pid" 2>/dev/null
    kill "$watchdog" 2>/dev/null
    wait "$watchdog" 2>/dev/null
    return 0
}

: >build/logs/bench-app.log
for i in $(seq 1 "$launches"); do
    bench "launch-$i" --bench-launch "$fixtures/files-3000"
done
for name in $folders; do
    FILETRAIL_BENCH_ONLY="$name" bench "open-$name" --bench "$fixtures"
done
bench scroll --bench-scroll "$fixtures/$scroll_folder"

# Listing read and sort: runs in a release test build, opens no window; its failure shows in the report.
rm -f build/bench/listing.json
tools/bench/listing.sh >/dev/null 2>&1

# Idle memory: one window in Home, physical footprint after 3 s.
"$bin" >/dev/null 2>&1 &
pid=$!
sleep 3
footprint "$pid" >"$raw/footprint.txt" 2>&1
kill "$pid" 2>/dev/null
wait "$pid" 2>/dev/null
du -sk "$app" | cut -f1 >"$raw/bundle-kb.txt"

python3 "$(dirname "$0")/report.py" "$quick" "$report_only" "$update_baseline"
