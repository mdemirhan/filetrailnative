#!/bin/bash
# Quiet CI: one line per step, failures extracted from the log. Full logs are in build/logs/<step>.log.
# Usage: scripts/ci.sh [--scope <test filter>] [--full]
set -uo pipefail
cd "$(dirname "$0")/.."

scope=""
full=0
while [ $# -gt 0 ]; do
    case "$1" in
    --scope)
        scope="${2:-}"
        shift 2
        ;;
    --full)
        full=1
        shift
        ;;
    *)
        echo "usage: scripts/ci.sh [--scope <filter>] [--full]" >&2
        exit 2
        ;;
    esac
done

logs=build/logs
mkdir -p "$logs"
out="$logs/ci-summary.txt"
: >"$out"
failed=0

# step <name> <extract pattern> <command...>; a "warning:" in the log fails the step when WARN_FAILS=1.
step() {
    local name="$1" pattern="$2" log="$logs/$1.log"
    shift 2
    local start=$SECONDS status=0
    "$@" >"$log" 2>&1 || status=$?
    if [ "$status" -eq 0 ] && [ "${WARN_FAILS:-0}" = 1 ] && grep -q 'warning:' "$log"; then
        status=1
    fi
    local elapsed=$((SECONDS - start))
    if [ "$status" -eq 0 ]; then
        echo "PASS $name (${elapsed}s)" >>"$out"
    else
        failed=1
        echo "FAIL $name (${elapsed}s)" >>"$out"
        # Strip ANSI colors, then keep the relevant lines.
        sed $'s/\x1b\\[[0-9;]*m//g' "$log" | grep -E "$pattern" | awk '!seen[$0]++' | cut -c1-300 | head -60 >>"$out"
    fi
}

WARN_FAILS=1 step build 'error:|warning:' swift build

if [ -n "$scope" ]; then
    step test 'error:|✘|failed|Fatal' swift test --filter "$scope"
else
    step test 'error:|✘|failed|Fatal' swift test
fi
# Test counts, from either Swift Testing or XCTest output.
clean_log="$(sed $'s/\x1b\\[[0-9;]*m//g' "$logs/test.log")"
passed="$(echo "$clean_log" | grep -E '^✔ Test run with' | grep -oE 'with [0-9]+' | awk '{s += $2} END {print s + 0}')"
failed_tests="$(echo "$clean_log" | grep -E '^✘ Test run with' | grep -oE 'with [0-9]+' | awk '{s += $2} END {print s + 0}')"
echo "tests: $passed in passing runs, $failed_tests in failing runs" >>"$out"

step format 'error:|warning:' xcrun swift-format lint --strict -r Sources Tests

if [ "$full" = 1 ]; then
    app_check() {
        scripts/build-app.sh release && test -d "build/File Trail.app/Contents/MacOS"
    }
    step app 'error:|warning:|No such file' app_check
fi

head -200 "$out"
exit "$failed"
