#!/bin/bash
# Quiet CI: one line per step, failures extracted from the log. Full logs are in build/logs/<step>.log.
# Usage: scripts/ci.sh [--scope <test filter> | --affected] [--full]
# --full is the check before a release: it builds from clean, and builds the release app as well.
set -uo pipefail
cd "$(dirname "$0")/.."

scope=""
affected=0
full=0
while [ $# -gt 0 ]; do
    case "$1" in
    --scope)
        if [ $# -lt 2 ] || [ -z "$2" ]; then
            echo "scripts/ci.sh: --scope needs a test filter" >&2
            exit 2
        fi
        scope="$2"
        shift 2
        ;;
    --affected)
        affected=1
        shift
        ;;
    --full)
        full=1
        shift
        ;;
    *)
        echo "usage: scripts/ci.sh [--scope <filter> | --affected] [--full]" >&2
        exit 2
        ;;
    esac
done
if [ -n "$scope" ] && [ "$affected" = 1 ]; then
    echo "scripts/ci.sh: --scope and --affected don't go together" >&2
    exit 2
fi

logs=build/logs
mkdir -p "$logs"
out="$logs/ci-summary.txt"
: >"$out"
# What is newer than this came during the run (the crash reports listed after a failure).
started="$logs/.ci-started"
touch "$started"
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

test_lines() {
    awk '{ gsub(/\033\[[0-9;]*m/, "") }
        after_issue { after_issue = 0; if (/^↳/) { print; fflush(); next } }
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

# The files changed on this branch, committed or not, and in commits not yet on GitHub. A file moved counts at both its
# places: the bundle it left must run too.
changed_files() {
    {
        git diff --name-only --no-renames main...HEAD
        git diff --name-only --no-renames origin/main...HEAD
        git diff --name-only --no-renames HEAD
        git ls-files --others --exclude-standard
    } 2>/dev/null | sort -u
}

# The test bundles that can see the files on stdin, one line of names: "all", or "none". A bundle links only the targets
# below it (FTFoundation, FTFileSystem, FTOperations, FTAppKit), so a change reaches its target's bundle and those above.
# What isn't known to reach only some bundles reaches them all: the Golden files and scripts/ are read by the tests.
affected_bundles() {
    local all=0 foundation=0 fileSystem=0 operations=0 appKit=0 file names=""
    while IFS= read -r file; do
        case "$file" in
        Sources/FTOperations/*) operations=1 appKit=1 ;;
        Sources/FTFileSystem/*) fileSystem=1 operations=1 appKit=1 ;;
        Sources/FTAppKit/* | Sources/FileTrail/*) appKit=1 ;;
        Tests/FTFoundationTests/*) foundation=1 ;;
        Tests/FTFileSystemTests/*) fileSystem=1 ;;
        Tests/FTOperationsTests/*) operations=1 ;;
        Tests/FTAppKitTests/*) appKit=1 ;;
        Sources/* | Tests/*) all=1 ;;
        docs/* | *.md) ;;
        *) all=1 ;;
        esac
    done
    if [ "$all" = 1 ]; then
        echo all
        return
    fi
    [ "$foundation" = 1 ] && names="$names FTFoundationTests"
    [ "$fileSystem" = 1 ] && names="$names FTFileSystemTests"
    [ "$operations" = 1 ] && names="$names FTOperationsTests"
    [ "$appKit" = 1 ] && names="$names FTAppKitTests"
    echo "${names:- none}" | cut -c2-
}

# Empty runs every bundle.
bundles=""
if [ "$affected" = 1 ]; then
    changed="$(changed_files)"
    if ! git rev-parse --verify -q 'main^{commit}' >/dev/null; then
        # No main to compare with: what changed can't be told, so all of it runs, the format lint included.
        bundles=all
        affected=0
        echo "affected: all (no main to compare with)" >>"$out"
    elif [ -z "$changed" ]; then
        # Nothing to go by (on main, everything pushed): a run that checked nothing would pass, so all of it runs,
        # the format lint included.
        bundles=all
        affected=0
        echo "affected: all (no file changed on this branch)" >>"$out"
    else
        bundles="$(echo "$changed" | affected_bundles)"
        echo "affected: $bundles" >>"$out"
    fi
    [ "$bundles" = all ] && bundles=""
fi

# The app and the tests in one build, which fails on a warning. A build reports the warnings only of the files it
# compiles, so one that reuses earlier work can pass with a warning in a file it didn't compile again: --full (the
# release's check) starts from clean.
if [ "$full" = 1 ] && ! swift package clean; then
    echo "FAIL clean (swift package clean failed: the build can't be from clean)" >>"$out"
    cat "$out"
    exit 1
fi
WARN_FAILS=1 step build 'error:|warning:' swift build --build-tests
build_failed="$failed"

# The windowless explorer suites (FTAppKitTests' ExplorerWindowlessTests) spread over this many processes in a full
# run, two for every three performance cores: each runs one test at a time, and is about a core while it does.
default_windowless_processes() {
    local cores
    cores="$(sysctl -n hw.perflevel0.physicalcpu 2>/dev/null || sysctl -n hw.physicalcpu)"
    echo $((cores * 2 / 3 > 3 ? cores * 2 / 3 : 3))
}
windowless_processes="${FILETRAIL_WINDOWLESS_PROCESSES:-$(default_windowless_processes)}"

# Each windowless suite's seconds in the last run that had them, for the next run's groups. In build/, so a clean build
# starts again from the number of tests.
windowless_times="$logs/windowless-times.txt"

# The windowless suites in `windowless_processes` groups of about the same time each, one filter a line. A suite with
# no time yet counts as its tests at the others' average.
windowless_groups() {
    run_bundle FTAppKitTests --list-tests 2>/dev/null |
        awk -F/ -v times="$windowless_times" '
            BEGIN { while ((getline line < times) > 0) { split(line, f, " "); seconds[f[2]] = f[1] } }
            $1 == "FTAppKitTests.ExplorerWindowlessTests" && NF > 2 { count[$2]++ }
            END {
                for (suite in count) if (suite in seconds) { known += seconds[suite]; tests += count[suite] }
                average = tests ? known / tests : 1
                for (suite in count) print (suite in seconds ? seconds[suite] : count[suite] * average), suite
            }' |
        sort -k1,1nr -k2,2 |
        awk -v n="$windowless_processes" '
            { best = 0; for (i = 1; i < n; i++) if (load[i] < load[best]) best = i
              load[best] += $1; names[best] = names[best] (names[best] == "" ? "" : "|") $2 }
            END { for (i = 0; i < n; i++) if (names[i] != "") print "ExplorerWindowlessTests/(" names[i] ")/" }'
}

# record_windowless_times <dir>: each suite's time, from the results file of each windowless process there.
record_windowless_times() {
    awk '/<testcase / {
            split($0, f, "\"")
            split(f[2], names, ".")
            seconds[names[3]] += f[6]
        }
        END { for (name in seconds) print seconds[name], name }' "$1"/FTAppKitTests-windowless-*.xml >"$windowless_times"
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

# A full run, or `bundles` if some are named: the test bundles side by side, each in its own process, and the windowless
# suites over several. Each process writes its log and results under build/logs/bundles/; the logs are put together into
# test.log.
full_tests() {
    local dir="$logs/bundles" names=() pids=() i name status=0 group
    [ "$CI_LIVE" = 1 ] && echo "Building the tests…" >&9
    swift build --build-tests || return 1
    rm -rf "$dir"
    mkdir -p "$dir"
    # Background processes ignore Ctrl-C, so they are stopped here.
    trap 'kill ${pids[*]-} 2>/dev/null; stop_following; exit 130' INT TERM HUP
    selected() { [ -z "$bundles" ] || [[ " $bundles " == *" $1 "* ]]; }
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
    if selected FTAppKitTests; then
        while IFS= read -r group; do
            i=$((i + 1))
            start "FTAppKitTests-windowless-$i" FTAppKitTests --filter "$group"
        done < <(windowless_groups)
        if [ "$i" -eq 0 ]; then
            echo "scripts/ci.sh: no windowless suites found (failed)"
            return 1
        fi
    fi
    # FTFoundationTests first, beside the windowless processes only (about a core each). Its timing tests measure CPU
    # time now, but run beside every bundle at once the run was no faster, and a disk image test of FTOperationsTests
    # failed in one run of two (a resource fork written to a full disk image), so it stays apart.
    if selected FTFoundationTests; then
        start FTFoundationTests FTFoundationTests
        finish $((${#pids[@]} - 1))
    fi
    selected FTAppKitTests && start FTAppKitTests FTAppKitTests --skip 'ExplorerWindowlessTests/'
    selected FTOperationsTests && start FTOperationsTests FTOperationsTests
    for i in "${!pids[@]}"; do finish "$i"; done
    # FTFileSystemTests last, with nothing beside it: its folder watches and disk images wait on the system's own daemons,
    # which fall seconds behind on a Mac kept busy by the others.
    if selected FTFileSystemTests; then
        start FTFileSystemTests FTFileSystemTests
        finish $((${#pids[@]} - 1))
    fi
    stop_following
    selected FTAppKitTests && record_windowless_times "$dir"
    for name in "${names[@]}"; do
        echo "== $name"
        cat "$dir/$name.log"
    done
    return "$status"
}

# What a failed test step reports: not a test that passes with "Fatal" or "error:" in its name, nor the system's
# sandbox_extension_consume lines.
test_failures='^error:|: error: |^✘|Fatal error:|: the test process failed$'

if [ "$build_failed" = 1 ]; then
    : >"$logs/test.log"
    echo "SKIP test (the build failed)" >>"$out"
elif [ -n "$scope" ]; then
    rm -f "$logs/test.log"
    follow_tests "$logs/test.log"
    step test "$test_failures" swift test --filter "$scope"
    stop_following
elif [ "$bundles" = none ]; then
    rm -rf "$logs/bundles"
    : >"$logs/test.log"
    echo "PASS test (nothing affected)" >>"$out"
else
    export logs windowless_processes windowless_times bundles
    export -f full_tests run_bundle windowless_groups record_windowless_times test_lines follow_tests stop_following
    step test "$test_failures" bash -c full_tests
fi
# Test counts, from Swift Testing's summaries.
clean_log="$(sed $'s/\x1b\\[[0-9;]*m//g' "$logs/test.log")"
# A test process that stopped silently exits 0 with no summary: that is a failure, not a pass. A full run has one summary
# per process (the bundle logs), a scoped one a summary from Swift Testing, whichever bundles the filter matched.
summaries="$(echo "$clean_log" | grep -cE '^(✔|✘) Test run with')"
expected_summaries=1
if [ -z "$scope" ] && [ -d "$logs/bundles" ]; then
    expected_summaries="$(find "$logs/bundles" -name '*.log' | wc -l | tr -d ' ')"
fi
[ "$bundles" = none ] && expected_summaries=0
[ "$build_failed" = 1 ] && expected_summaries=0
if [ "$summaries" -lt "$expected_summaries" ] && grep -q '^PASS test ' "$out"; then
    failed=1
    sed -i '' 's/^PASS test /FAIL test /' "$out"
    echo "the test processes ended with $summaries \"Test run with\" summaries, $expected_summaries expected: one stopped silently" >>"$out"
fi
# The next run clears these logs, so a failed run's are kept, and the crash reports of the test processes named.
if grep -q '^FAIL test ' "$out"; then
    kept="$logs/failed-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$kept"
    cp "$logs/test.log" "$kept/" 2>/dev/null
    [ -z "$scope" ] && [ -d "$logs/bundles" ] && cp -R "$logs/bundles" "$kept/"
    echo "logs kept in $kept" >>"$out"
    find "$HOME/Library/Logs/DiagnosticReports" -name 'swiftpm-testing-helper-*.ips' -newer "$started" 2>/dev/null |
        sed 's/^/crash report since the run began: /' >>"$out"
    # The five latest are enough.
    ls -dt "$logs"/failed-* | tail -n +6 | while IFS= read -r old; do rm -rf "$old"; done
fi
passed="$(echo "$clean_log" | grep -E '^✔ Test run with' | grep -oE 'with [0-9]+' | awk '{s += $2} END {print s + 0}')"
failed_tests="$(echo "$clean_log" | grep -E '^✘ Test run with' | grep -oE 'with [0-9]+' | awk '{s += $2} END {print s + 0}')"
echo "tests: $passed in passing runs, $failed_tests in failing runs" >>"$out"
# Without the fixture trees the tests that read them are skipped, which a passing run would not show.
fixtures="${FILETRAIL_DEV_CACHE:-$HOME/Library/Caches/filetrail-dev}/fixtures"
for tree in names lighthouse bench; do
    if [ ! -f "$fixtures/$tree/.fixture-version" ]; then
        echo "note: the fixture trees aren't built ($fixtures/$tree is missing), so the tests that read them were skipped: run bun tools/fixtures/generate.ts" >>"$out"
        break
    fi
done

if [ -n "$scope" ] || [ "$affected" = 1 ]; then
    # A scoped or affected run lints only the Swift files changed on this branch; a full run lints everything.
    changed=()
    while IFS= read -r f; do [ -f "$f" ] && changed+=("$f"); done < <(
        changed_files | grep -E '^((Sources|Tests|tools)/.*\.swift|Package\.swift)$'
    )
    if [ "${#changed[@]}" -gt 0 ]; then
        step format 'error:|warning:' xcrun swift-format lint --strict "${changed[@]}"
    else
        echo "PASS format (no changed files)" >>"$out"
    fi
else
    step format 'error:|warning:' xcrun swift-format lint --strict -r Sources Tests tools Package.swift
fi

if [ "$full" = 1 ]; then
    # The release build's output is in build-app.sh's own log: a warning there fails the step.
    app_check() {
        scripts/build-app.sh release && test -d "build/File Trail.app/Contents/MacOS" || return 1
        if grep -q 'warning:' build/logs/build-app.log; then
            sed $'s/\x1b\\[[0-9;]*m//g' build/logs/build-app.log | grep 'warning:'
            return 1
        fi
    }
    step app 'error:|warning:|No such file' app_check
fi

head -200 "$out"
exit "$failed"
