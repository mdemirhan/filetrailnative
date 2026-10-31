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

# In a terminal, each test is shown as it starts and ends, with how long it took; a run with no terminal stays quiet. Ctrl-C
# stops the whole run.
if [ -t 1 ]; then
    CI_LIVE=1
    exec 9>&1
else
    CI_LIVE=0
fi
export CI_LIVE
trap 'echo "stopped" >&2; exit 130' INT

# A test in a slot reports its own time on a ⏱ line (`WindowlessSlots`), the sum of its cases: Swift Testing's counts the
# wait for the slot, so that time takes its place.
test_lines() {
    awk '{ gsub(/\033\[[0-9;]*m/, "") }
        /^⏱ Test / {
            name = $0
            sub(/^⏱ Test /, "", name)
            sub(/ took [0-9.]+ seconds\.$/, "", name)
            match($0, / took [0-9.]+ /)
            slot[name] += substr($0, RSTART + 6, RLENGTH - 7)
            next
        }
        after_issue { after_issue = 0; if (/^↳/) { print; fflush(); next } }
        /^(✔|✘) Test .* (passed|failed) after / {
            name = $0
            sub(/^(✔|✘) Test /, "", name)
            sub(/ (passed|failed) after .*$/, "", name)
            sub(/ with [0-9]+ test cases?$/, "", name)
            if (name in slot) {
                match($0, / after [0-9.]+ /)
                $0 = substr($0, 1, RSTART + 6) sprintf("%.3f", slot[name]) substr($0, RSTART + RLENGTH - 1)
                delete slot[name]
            }
        }
        /^(◇|✔|✘|➜) Test / && !/Test run started/ { print; fflush(); after_issue = /recorded an issue/ }'
}

# follow_tests <log>: shows the tests of a log while it is written. The log itself is left to the process writing it.
follow_tests() {
    [ "$CI_LIVE" = 1 ] || return 0
    : >>"$1"
    tail -n +1 -f "$1" > >(test_lines >&9) &
    followers+=($!)
    # No "Terminated" line when it is stopped.
    disown $!
}

stop_following() {
    [ "$CI_LIVE" = 1 ] || return 0
    # tail's last look, and then the lines on their way.
    sleep 1
    [ -n "${followers[*]-}" ] && kill "${followers[@]}" 2>/dev/null
    followers=()
    sleep 0.2
}
followers=()

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

# The windowless explorer suites (FTAppKitTests' ExplorerWindowlessTests) spread over this many processes in a full
# run: they all wait on their process's main thread, so one process is most of the run's time.
windowless_processes="${FILETRAIL_WINDOWLESS_PROCESSES:-3}"

# The windowless suites in `windowless_processes` groups of about as many tests each, one filter a line.
windowless_groups() {
    run_bundle FTAppKitTests --list-tests 2>/dev/null |
        awk -F/ '$1 == "FTAppKitTests.ExplorerWindowlessTests" && NF > 2 { count[$2]++ }
            END { for (suite in count) print count[suite], suite }' |
        sort -k1,1nr -k2,2 |
        awk -v n="$windowless_processes" '
            { best = 0; for (i = 1; i < n; i++) if (load[i] < load[best]) best = i
              load[best] += $1; names[best] = names[best] (names[best] == "" ? "" : "|") $2 }
            END { for (i = 0; i < n; i++) if (names[i] != "") print "ExplorerWindowlessTests/(" names[i] ")/" }'
}

# run_bundle <test target> <testing helper options...>: one test bundle in a process of its own, as `swift test` runs
# it (Swift Testing; the package has no XCTest tests).
run_bundle() {
    local target="$1" platform
    shift
    platform="$(xcrun --show-sdk-platform-path)/Developer"
    DYLD_LIBRARY_PATH="$PWD/.build/debug:$platform/usr/lib" \
        DYLD_FRAMEWORK_PATH="$platform/Library/Frameworks:$platform/Library/PrivateFrameworks" \
        "$(dirname "$(xcrun --find swift)")/../libexec/swift/pm/swiftpm-testing-helper" \
        --test-bundle-path ".build/debug/$target.xctest/Contents/MacOS/$target" --testing-library swift-testing "$@"
}

# A full run: the test bundles side by side, each in its own process, and the windowless suites over several. Each
# process writes its log and results under build/logs/bundles/; they are put together into test.log and the xunit
# files the parity sync reads. Known failures are skipped in every process.
full_tests() {
    local dir="$logs/bundles" names=() pids=() i name status=0 group
    [ "$CI_LIVE" = 1 ] && echo "Building the tests…" >&9
    swift build --build-tests || return 1
    rm -rf "$dir"
    mkdir -p "$dir"
    # Background processes ignore Ctrl-C, so they are stopped here.
    trap 'kill ${pids[*]-} 2>/dev/null; stop_following; exit 130' INT TERM HUP
    # start <log name> <test target> <testing helper options...>
    start() {
        local name="$1"
        shift
        names+=("$name")
        follow_tests "$dir/$name.log"
        run_bundle "$@" --xunit-output "$dir/$name.xml" >"$dir/$name.log" 2>&1 &
        pids+=($!)
    }
    # finish <index>: waits for that process once; a failed one fails the run.
    finish() {
        [ -z "${pids[$1]}" ] && return
        if ! wait "${pids[$1]}"; then
            status=1
            echo "${names[$1]}: the test process failed" >>"$dir/${names[$1]}.log"
        fi
        pids[$1]=""
    }
    i=0
    # Two windowless tests at a time in each of these processes (`WindowlessSlots`).
    export FILETRAIL_WINDOWLESS_SLOTS="${FILETRAIL_WINDOWLESS_SLOTS:-2}"
    while IFS= read -r group; do
        i=$((i + 1))
        start "FTAppKitTests-windowless-$i" FTAppKitTests --filter "$group"
    done < <(windowless_groups)
    if [ "$i" -eq 0 ]; then
        echo "scripts/ci.sh: no windowless suites found (failed)"
        return 1
    fi
    # FTFoundationTests first, beside the windowless processes only (about a core each): its timing tests (a filter of
    # 50,000 names within 400 ms) miss their bound on a Mac kept busy by every bundle at once.
    start FTFoundationTests FTFoundationTests
    finish $((${#pids[@]} - 1))
    start FTAppKitTests FTAppKitTests --skip 'ExplorerWindowlessTests/'
    start FTOperationsTests FTOperationsTests
    start FTFileSystemTests FTFileSystemTests
    for i in "${!pids[@]}"; do finish "$i"; done
    stop_following
    for name in "${names[@]}"; do
        echo "== $name"
        cat "$dir/$name.log"
    done
    # One results file, as `swift test` writes it: each process's suite of results in it.
    {
        echo '<?xml version="1.0" encoding="UTF-8"?>'
        echo '<testsuites>'
        for name in "${names[@]}"; do
            [ -f "$dir/$name.xml" ] && sed -n '/<testsuite[ >]/,/<\/testsuite>/p' "$dir/$name.xml"
        done
        echo '</testsuites>'
    } >build/logs/parity-xunit-swift-testing.xml
    cp build/logs/parity-xunit-swift-testing.xml build/logs/parity-xunit.xml
    return "$status"
}

# What a failed test step reports: not a test that passes with "Fatal" or "error:" in its name, nor the system's
# sandbox_extension_consume lines.
test_failures='^error:|: error: |^✘|Fatal error:|: the test process failed$'

if [ -n "$scope" ]; then
    rm -f "$logs/test.log"
    follow_tests "$logs/test.log"
    step test "$test_failures" swift test --filter "$scope"
    stop_following
else
    export logs windowless_processes
    export -f full_tests run_bundle windowless_groups test_lines follow_tests stop_following
    step test "$test_failures" bash -c full_tests
fi
# Test counts, from either Swift Testing or XCTest output.
clean_log="$(sed $'s/\x1b\\[[0-9;]*m//g' "$logs/test.log")"
# A test process that stopped silently exits 0 with no summary: that is a failure, not a pass. A full run has one summary
# per process (the bundle logs), a scoped one a summary from Swift Testing, whichever bundles the filter matched.
summaries="$(echo "$clean_log" | grep -cE '^(✔|✘) Test run with')"
expected_summaries=1
if [ -z "$scope" ] && [ -d "$logs/bundles" ]; then
    expected_summaries="$(find "$logs/bundles" -name '*.log' | wc -l | tr -d ' ')"
fi
if [ "$summaries" -lt "$expected_summaries" ] && grep -q '^PASS test ' "$out"; then
    failed=1
    sed -i '' 's/^PASS test /FAIL test /' "$out"
    echo "the test processes ended with $summaries \"Test run with\" summaries, $expected_summaries expected: one stopped silently" >>"$out"
fi
passed="$(echo "$clean_log" | grep -E '^✔ Test run with' | grep -oE 'with [0-9]+' | awk '{s += $2} END {print s + 0}')"
failed_tests="$(echo "$clean_log" | grep -E '^✘ Test run with' | grep -oE 'with [0-9]+' | awk '{s += $2} END {print s + 0}')"
echo "tests: $passed in passing runs, $failed_tests in failing runs" >>"$out"

if [ -n "$scope" ]; then
    # A scoped run lints only the Swift files changed on this branch (committed or not); a full run lints everything.
    changed=()
    while IFS= read -r f; do [ -f "$f" ] && changed+=("$f"); done < <(
        { git diff --name-only main...HEAD; git diff --name-only HEAD; git ls-files --others --exclude-standard; } 2>/dev/null |
            grep -E '^(Sources|Tests)/.*\.swift$' | sort -u
    )
    if [ "${#changed[@]}" -gt 0 ]; then
        step format 'error:|warning:' xcrun swift-format lint --strict "${changed[@]}"
    else
        echo "PASS format (no changed files)" >>"$out"
    fi
else
    step format 'error:|warning:' xcrun swift-format lint --strict -r Sources Tests
fi

if [ "$full" = 1 ]; then
    app_check() {
        scripts/build-app.sh release && test -d "build/File Trail.app/Contents/MacOS"
    }
    step app 'error:|warning:|No such file' app_check
fi

head -200 "$out"
exit "$failed"
