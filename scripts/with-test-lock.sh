#!/bin/bash
# Usage: scripts/with-test-lock.sh <command...>
# Runs a test command of your own (a swift test, say) behind the lock scripts/ci.sh takes, so it doesn't run beside
# another test run on this Mac (scripts/lib/test-lock.sh). It runs in the directory it was started from.
set -uo pipefail
if [ $# -eq 0 ]; then
    echo "usage: scripts/with-test-lock.sh <command...>" >&2
    exit 2
fi
# shellcheck source=lib/test-lock.sh
source "$(dirname "$0")/lib/test-lock.sh"
with_test_lock "$*" "$@"
