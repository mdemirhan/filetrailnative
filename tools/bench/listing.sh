#!/bin/bash
# Listing and search benchmark: reads and sorts fixtures/bench/files-3000 and files-100000 through
# DirectoryService in a release build, and times the first results of an fd search of Home (ListingBenchTests,
# SearchBenchTests). Fails over budget (25 ms, 400 ms, 150 ms). It opens no window and launches no app.
# Usage: tools/bench/listing.sh
set -uo pipefail
cd "$(dirname "$0")/../.."

fixtures="$HOME/Library/Caches/filetrail-dev/fixtures/bench"
if [ ! -d "$fixtures/files-3000" ] || [ ! -d "$fixtures/files-100000" ]; then
    echo "missing fixtures in $fixtures (see tools/fixtures/README.md)" >&2
    exit 2
fi
mkdir -p build/logs build/bench
FILETRAIL_BENCH=1 swift test -c release -Xswiftc -enable-testing --filter 'BenchTests|PasteThroughputTests' >build/logs/bench-listing.log 2>&1
status=$?
grep '^BENCH ' build/logs/bench-listing.log | sed 's/^BENCH //' | tee build/bench/listing.json
if [ "$status" -ne 0 ]; then
    grep -E 'error:|✘|↳' build/logs/bench-listing.log | cut -c1-300 | head -20
fi
exit "$status"
