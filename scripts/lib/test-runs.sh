# What a swift test run's log says, for scripts/ci.sh and scripts/release.sh.

# ran_some_tests <log>: whether the swift test run that wrote the log ran any test: a filter that matches none passes
# with nothing checked.
ran_some_tests() {
    ! grep -q "No matching test cases were run" "$1" &&
        grep -Eq "Test run with [1-9][0-9]* tests?" "$1"
}
