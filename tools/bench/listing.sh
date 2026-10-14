#!/bin/bash
# Listing benchmark: reads and sorts fixtures/bench/files-3000 and files-100000 through DirectoryService in a
# release build, prints the medians next to their budgets (25 ms and 400 ms) and fails over budget. It opens
# no window and launches no app.
# Usage: tools/bench/listing.sh
set -uo pipefail
cd "$(dirname "$0")/../.."

fixtures="$HOME/Library/Caches/filetrail-port/fixtures/bench"
if [ ! -d "$fixtures/files-3000" ] || [ ! -d "$fixtures/files-100000" ]; then
    echo "missing fixtures in $fixtures (see tools/fixtures/README.md)" >&2
    exit 2
fi
mkdir -p build/logs build/bench
FILETRAIL_BENCH=1 swift test -c release -Xswiftc -enable-testing --filter ListingBenchTests >build/logs/bench-listing.log 2>&1
status=$?
grep '^BENCH ' build/logs/bench-listing.log | sed 's/^BENCH //' | tee build/bench/listing.json
if [ "$status" -ne 0 ]; then
    grep -E 'error:|✘|↳' build/logs/bench-listing.log | cut -c1-300 | head -20
fi
exit "$status"
