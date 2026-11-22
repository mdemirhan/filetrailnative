# One test run at a time on this Mac, for scripts/ci.sh, scripts/release.sh and scripts/with-test-lock.sh: two runs at
# once stall each other's test processes, and their tests then fail on waits that ran out.
#
# The lock is a file in the repository's own git folder, which every checkout and worktree of it shares, so a run in
# any of them, by anyone, waits for the one going on. A lock of each session's own (a file in its scratch folder)
# kept only that session's runs apart. The file is kept between runs (lockf -k): one removed as a run ends could be
# locked again by a run that opened it before, while a newer one locks the new file, and both would run.
#
# FILETRAIL_TEST_LOCK names the lock a process runs under: a run started by one that holds it (the release's
# scripts/ci.sh) goes on without waiting for itself.

# The lock file of the checkout the shell is in.
test_lock_path() {
    local dir
    dir="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
    echo "${dir}/filetrail-tests.lock"
}

# test_lock_held <lock>: whether this process runs under that lock already.
test_lock_held() {
    [ "${FILETRAIL_TEST_LOCK-}" = "$1" ]
}

# test_lock_wait_note <lock>: says on stderr, before waiting, whose run holds the lock.
test_lock_wait_note() {
    if ! /usr/bin/lockf -k -s -t 0 "$1" /usr/bin/true; then
        echo "Waiting for the test run going on to end: $(cat "$1" 2>/dev/null || echo "lock $1")" >&2
    fi
}

# with_test_lock <name> <command...>: runs the command once the lock is free, holding it until the command ends, and
# returns its status. <name> says whose run it is, for a run that waits.
with_test_lock() {
    local name="$1" lock
    shift
    lock="$(test_lock_path)" || {
        echo "The test lock needs a git checkout: $PWD isn't one." >&2
        return 2
    }
    if test_lock_held "$lock"; then
        "$@"
        return
    fi
    test_lock_wait_note "$lock"
    # The holder writes who it is into the lock file, for the note of a run that waits.
    /usr/bin/lockf -k "$lock" /bin/bash -c '
        printf "%s in %s (process %s, since %s)\n" "$1" "$PWD" "$$" "$(date +%H:%M:%S)" >"$2"
        export FILETRAIL_TEST_LOCK="$2"
        shift 2
        exec "$@"' with-test-lock "$name" "$lock" "$@"
}
