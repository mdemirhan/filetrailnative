#!/bin/bash
# A release is a commit tagged vX.Y.Z, and that tag is its version. Any other build is named after the last release
# before it, with how many commits it is past it ("0.1.0+dev.4"); with no release at all, "0.0.0+dev.N". Tags with a
# suffix ("v0.3.0-beta") are not releases. Prints the version of the commit checked out in the current folder, and fails
# with no output outside a repository. Usage: scripts/version.sh [--bundle]   --bundle: numbers only, what macOS shows
# (CFBundleShortVersionString).
set -euo pipefail
# latest_release: what a release tag is, as scripts/release.sh reads it.
# shellcheck source=lib/release-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/release-lib.sh"

tags_at_commit="$(git tag --points-at HEAD 2>/dev/null)"
tagged="$(latest_release <<<"$tags_at_commit")"
if [ -n "$tagged" ]; then
    version="$tagged"
else
    tags_before="$(git tag --merged HEAD --list 'v*' 2>/dev/null)"
    last_release="$(latest_release <<<"$tags_before")"
    if [ -n "$last_release" ]; then
        commits="$(git rev-list --count "v$last_release..HEAD" 2>/dev/null)"
    else
        commits="$(git rev-list --count HEAD 2>/dev/null)"
    fi
    version="${last_release:-0.0.0}+dev.$commits"
fi

if [ "${1:-}" = --bundle ]; then
    echo "${version%%[+-]*}"
else
    echo "$version"
fi
