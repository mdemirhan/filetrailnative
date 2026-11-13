#!/bin/bash
# Scripts/release.sh <major|minor|patch|X.Y.Z> --notes <file> [--yes] [--dry-run]
#
# From a clean main that is already on GitHub, it checks the commit (scripts/ci.sh --full with the large-file tests, the
# release-only tests and the fuzz tests at more cases from a seed of the day, then the tests of real windows with the frame
# times of scrolling), adds those frame times to docs/frame-timings.json in a commit of their own, tags that commit vX.Y.Z
# (the version comes from the tag, see scripts/version.sh), builds the signed and notarized app, pushes main and the tag,
# and makes a draft GitHub release with the disk image and the ZIP. The frame times are shown against the last release
# made on the same Mac model, and a clear slowdown stops the release (scripts/lib/frame-timing-limits.sh). Nothing is
# published by this script: publish the draft on GitHub.
#
# The notes are written for people before the release starts, in Markdown, in a file outside the checkout (or under
# build/, which git ignores). They are the draft release's text and the tag's message after its "File Trail X.Y.Z" line,
# so the tag keeps them. The file is read when the commit is tagged: an edit made on GitHub later isn't in the tag.
#
# The first release is asked for by exact version: there is no release yet for major, minor or patch to count from.
#
# --dry-run stops after saying what it would release. --yes skips the question before the release starts.
set -Eeuo pipefail

# A relative path to the notes is from where the script was started.
CALLER_DIR="${PWD}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"
# shellcheck source=lib/release-lib.sh
source scripts/lib/release-lib.sh

OUT_DIR="build/release"
APP_BUNDLE="${OUT_DIR}/File Trail.app"
SHARE_FILES=("${OUT_DIR}/FileTrail-arm64.dmg" "${OUT_DIR}/FileTrail-arm64.zip")
USAGE="Usage: scripts/release.sh <major|minor|patch|X.Y.Z> --notes <file> [--yes] [--dry-run]"

die() {
    echo "$1" >&2
    exit 1
}

# Runs a step with its output on screen; stops the release when it fails.
run() {
    local title="$1"
    shift
    printf '\n==> %s\n' "${title}"
    "$@" || die "${title} failed."
}

# Stops the release when the checkout changed while it ran (a commit, or an edit made in the meantime), so the tag, the
# build and what was checked are the same code.
assert_unchanged_since() {
    if [[ "$(git rev-parse HEAD)" != "$1" ]]; then
        die "HEAD moved during $2: run the release again."
    fi
    if [[ -n "$(git status --porcelain)" ]]; then
        die "Files changed during $2: commit or set them aside, then run again."
    fi
}

REQUEST=""
NOTES=""
YES=0
DRY_RUN=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --yes) YES=1 ;;
        --dry-run) DRY_RUN=1 ;;
        --notes)
            [[ $# -ge 2 && -n "$2" ]] || die "${USAGE}"
            NOTES="$2"
            shift
            ;;
        --notes=*) NOTES="${1#--notes=}" ;;
        --*) die "${USAGE}" ;;
        *) [[ -n "${REQUEST}" ]] || REQUEST="$1" ;;
    esac
    shift
done
[[ -n "${REQUEST}" ]] || die "${USAGE}"
[[ -z "${NOTES}" || "${NOTES}" == /* ]] || NOTES="${CALLER_DIR}/${NOTES}"

# What stands in the way of releasing this commit, one a line; nothing when it can be released.
PROBLEMS=""
add_problem() {
    PROBLEMS+="$1"$'\n'
}

# The notes are the draft's text and the tag's message, so they are written before anything is checked or tagged.
if [[ -z "${NOTES}" ]]; then
    add_problem "There are no release notes: write them for people in a file and name it with --notes <file>."
elif [[ ! -f "${NOTES}" || ! -r "${NOTES}" ]]; then
    add_problem "The release notes ${NOTES} can't be read."
elif ! grep -q '[^[:space:]]' "${NOTES}"; then
    add_problem "The release notes ${NOTES} are empty."
fi
if [[ "$(git rev-parse --abbrev-ref HEAD)" != main ]]; then
    add_problem "Releases are made from main: switch to it first."
fi
if [[ -n "$(git status --porcelain)" ]]; then
    add_problem "There are uncommitted changes: commit or set them aside first."
fi
run "Fetching main and the tags from GitHub" git fetch --quiet --tags origin
if [[ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]]; then
    add_problem "This commit isn't main on GitHub: push main (git push origin main) or pull first, so the release is a commit GitHub has."
fi
# Without gh the release would stop only after the tag is on GitHub.
GH_READY=0
if ! command -v gh >/dev/null; then
    add_problem "gh isn't installed: the draft release is made with it."
elif ! gh auth status >/dev/null 2>&1; then
    add_problem "gh isn't signed in to GitHub: run gh auth login first."
else
    GH_READY=1
fi

# The tests that read the fixture trees are skipped without them, which a release mustn't do quietly.
FIXTURES="${FILETRAIL_DEV_CACHE:-${HOME}/Library/Caches/filetrail-dev}/fixtures"
for tree in names lighthouse large; do
    if [[ ! -f "${FIXTURES}/${tree}/.fixture-version" ]]; then
        add_problem "The test fixtures aren't built (${FIXTURES}/${tree} is missing): run bun tools/fixtures/generate.ts first."
        break
    fi
done

# The disk image tests are part of what a release checks.
if [[ -n "${FILETRAIL_NO_DISK_IMAGES:-}" ]]; then
    add_problem "FILETRAIL_NO_DISK_IMAGES is set, which skips the tests on disk images: unset it first."
fi
if ! command -v jq >/dev/null; then
    add_problem "jq isn't installed: the frame times are read with it."
fi

# What is checked, tagged and built: the commit found clean and on GitHub here.
CHECKED_COMMIT="$(git rev-parse HEAD)"
TAGS="$(git tag --list | release_tags)"
LATEST="$(latest_release <<<"${TAGS}")"

# The release tags on GitHub, whether or not they were fetched here.
REMOTE_TAGS="$(git ls-remote --tags --refs origin | sed 's|.*refs/tags/||' | release_tags)" ||
    die "git couldn't read the tags on GitHub."
LATEST_ON_GITHUB="$(latest_release <<<"${REMOTE_TAGS}")"
LATEST_TAG=""
LATEST_STATE=""
# Without gh, whether the last release is out can't be asked: the problem above says why.
if [[ -n "${LATEST_ON_GITHUB}" && "${GH_READY}" == 1 ]]; then
    LATEST_TAG="v${LATEST_ON_GITHUB}"
    if ANSWER="$(gh release view "${LATEST_TAG}" --json isDraft --jq .isDraft 2>&1)"; then
        if [[ "${ANSWER}" == true ]]; then LATEST_STATE=draft; else LATEST_STATE=published; fi
    elif grep -iq "release not found" <<<"${ANSWER}"; then
        LATEST_STATE=missing
    else
        die "gh couldn't tell whether ${LATEST_TAG} is released: ${ANSWER}"
    fi
fi
# A release that didn't finish would be skipped over by the next version: each one is finished, or undone, before another
# is made.
UNFINISHED="$(find_unfinished_releases "${TAGS}" "${REMOTE_TAGS}" "${LATEST_TAG}" "${LATEST_STATE}")"
if [[ -n "${UNFINISHED}" ]]; then
    add_problem "${UNFINISHED}"
fi

if [[ -z "${LATEST}" && "${REQUEST}" =~ ^(major|minor|patch)$ ]]; then
    die "There is no release yet for ${REQUEST} to count from: ask for the first one by exact version, like 0.1.0.
${USAGE}"
fi
VERSION="$(next_version "${LATEST}" "${REQUEST}" 2>&1)" || die "${VERSION}
${USAGE}"
TAG="v${VERSION}"
if [[ -n "$(git tag --list "${TAG}")" ]]; then
    add_problem "${TAG} already exists."
fi
RELEASED_HERE="$(git tag --points-at HEAD | release_tags | paste -s -d , - | sed 's/,/, /g')"
if [[ -n "${RELEASED_HERE}" ]]; then
    add_problem "This commit is already released as ${RELEASED_HERE}."
fi
if [[ -n "${PROBLEMS}" && "${DRY_RUN}" == 0 ]]; then
    die "${PROBLEMS%$'\n'}"
fi

if [[ -n "${LATEST}" ]]; then
    SUBJECTS="$(git log --no-merges --format=%s "v${LATEST}..HEAD")"
    AFTER=" (after ${LATEST})"
else
    SUBJECTS="$(git log --no-merges --format=%s HEAD)"
    AFTER=""
fi
COMMIT_COUNT="$(grep -c . <<<"${SUBJECTS}" || true)"
printf '\nFile Trail %s%s, from %s, %s commits.\n' "${VERSION}" "${AFTER}" "$(git log -1 --format='%h %s')" "${COMMIT_COUNT}"
[[ -z "${NOTES}" ]] || printf 'The notes: %s\n' "${NOTES}"

if [[ "${DRY_RUN}" == 1 ]]; then
    while IFS= read -r problem; do
        [[ -z "${problem}" ]] || echo "Would stop: ${problem}"
    done <<<"${PROBLEMS}"
    printf '\nDry run: the tags were fetched; nothing was checked, tagged, built or pushed.\n'
    exit 0
fi
if [[ "${YES}" == 0 ]]; then
    ANSWER=""
    read -r -p "Check, tag, build and draft ${TAG}? [y/N] " ANSWER || true
    if [[ ! "${ANSWER}" =~ ^[[:space:]]*[yY][[:space:]]*$ ]]; then
        echo "Nothing was done."
        exit 0
    fi
fi

# The fuzz tests draw many more cases than a commit's check, from a seed of the day: a failure names the seed that makes
# it again.
FUZZ_SEED="$(date +%Y%m%d)"
printf '\nThe fuzz tests start at seed %s (UNDO_FUZZ_SEED, BATCH_RENAME_FUZZ_SEED).\n' "${FUZZ_SEED}"
run "Clean build with zero warnings, every test including the large-file and release-only ones, format lint, and the release app" \
    env FILETRAIL_LARGE_FILE_TESTS=1 FILETRAIL_RELEASE_TESTS=1 UNDO_FUZZ_CASES=1000 UNDO_FUZZ_SEED="${FUZZ_SEED}" \
    BATCH_RENAME_FUZZ_CASES=4000 BATCH_RENAME_FUZZ_SEED="${FUZZ_SEED}" scripts/ci.sh --full

# The tests that put windows, menus and a disk on screen: the only tests of real windows, so a release runs them. They
# include the frame times of scrolling (FrameTimeGUITests), written to a file for the comparison after.
FRAME_TIMINGS="build/release-frame-timings.json"
GUI_LOG="build/logs/release-gui-tests.log"
mkdir -p build/logs
rm -f "${FRAME_TIMINGS}"
printf '\n==> %s\n' "The tests that drive real windows"
env FILETRAIL_GUI_TESTS=1 FILETRAIL_FRAME_TIMINGS_OUT="${PWD}/${FRAME_TIMINGS}" swift test --filter GUITests 2>&1 |
    tee "${GUI_LOG}" || die "The tests that drive real windows failed."
ran_some_tests "${GUI_LOG}" || die "The tests that drive real windows ran no test: --filter GUITests matched none."
[[ -f "${FRAME_TIMINGS}" ]] || die "The frame-time tests left no timings in ${FRAME_TIMINGS}."

# The frame times against the last release made on this Mac model, or the ceilings with none.
HISTORY="docs/frame-timings.json"
MACHINE="${FILETRAIL_MACHINE_MODEL:-$(sysctl -n hw.model)}"
MACOS="$(sw_vers -productVersion)"
PREVIOUS="$(frame_timings_previous "${HISTORY}" "${MACHINE}")" || die "${HISTORY} couldn't be read."
printf '\n==> %s\n' "Frame times of scrolling"
frame_timings_report "${FRAME_TIMINGS}" "${PREVIOUS}" "${MACHINE}" ||
    die "Scrolling got slower than the frame-time limits allow (scripts/lib/frame-timing-limits.sh)."

# The checks take minutes: what is tagged must still be what was checked.
assert_unchanged_since "${CHECKED_COMMIT}" "the checks"

COMMITTED=0
TAGGED=0
PUSHED=0
DRAFTED=0
NOTES_DIR=""
finish() {
    local status=$?
    [[ -z "${NOTES_DIR}" ]] || rm -rf "${NOTES_DIR}"
    if [[ "${status}" != 0 && "${PUSHED}" == 0 ]]; then
        # Not on GitHub yet: the tag and the frame times' commit go, so the release can simply be tried again.
        [[ "${TAGGED}" == 0 ]] || git tag -d "${TAG}" >/dev/null 2>&1 || true
        if [[ "${COMMITTED}" == 1 ]]; then
            git reset -q --keep "${CHECKED_COMMIT}" || true
            git checkout -q "${CHECKED_COMMIT}" -- "${HISTORY}" 2>/dev/null || rm -f "${HISTORY}"
        fi
        if [[ "${TAGGED}" == 1 || "${COMMITTED}" == 1 ]]; then
            printf '\n%s and its frame times were taken back; nothing reached GitHub.\n' "${TAG}" >&2
        fi
    elif [[ "${status}" != 0 && "${TAGGED}" == 1 ]]; then
        if [[ "${DRAFTED}" == 0 ]]; then
            printf '\n%s is on GitHub. Finish the release there, or delete the tag (git push origin :%s; git tag -d %s) to start over.\n' \
                "${TAG}" "${TAG}" "${TAG}" >&2
        fi
    fi
    exit "${status}"
}
trap finish EXIT
# Ctrl-C and the like go through finish too, or a stopped release would leave its tag.
trap 'exit 130' INT
trap 'exit 143' TERM HUP

# The frame times join the history in a commit of their own, which is the one tagged: it holds the checked commit and that
# file alone.
RECORD="$(frame_timings_record "${VERSION}" "$(date +%Y-%m-%d)" "${MACHINE}" "${MACOS}" "${FRAME_TIMINGS}")" ||
    die "The frame times couldn't be read."
COMMITTED=1
mkdir -p "$(dirname "${HISTORY}")"
frame_timings_append "${HISTORY}" "${RECORD}" >"${HISTORY}.new" || die "${HISTORY} couldn't be written."
mv "${HISTORY}.new" "${HISTORY}"
git add "${HISTORY}"
run "Recording the frame times in ${HISTORY}" git commit -q -m "The frame times of scrolling in File Trail ${VERSION} are kept"
RELEASE_COMMIT="$(git rev-parse HEAD)"
if [[ "$(git rev-parse HEAD^)" != "${CHECKED_COMMIT}" || "$(git diff --name-only "${CHECKED_COMMIT}" HEAD)" != "${HISTORY}" ]]
then
    die "The commit to tag isn't the checked one with the frame times alone added."
fi

# The tag's message is the release's name and its notes, word for word: a Markdown heading starts with #, which git
# would otherwise take for a comment and drop. The draft gets the same notes, from the same copy.
NOTES_DIR="$(mktemp -d -t filetrail-release)"
cp "${NOTES}" "${NOTES_DIR}/notes.md" || die "The release notes ${NOTES} couldn't be read."
{ printf 'File Trail %s\n\n' "${VERSION}"; cat "${NOTES_DIR}/notes.md"; } >"${NOTES_DIR}/tag-message.txt"
run "Tagging ${TAG} with the release notes" \
    git tag -a --cleanup=verbatim -F "${NOTES_DIR}/tag-message.txt" "${TAG}" "${RELEASE_COMMIT}"
TAGGED=1

run "Building, signing and notarizing the app" scripts/make-release-app.sh --notarize
PLIST="${APP_BUNDLE}/Contents/Info.plist"
BUILT="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${PLIST}")"
RECORDED="$(/usr/libexec/PlistBuddy -c "Print :FTVersion" "${PLIST}")"
if [[ "${BUILT}" != "${VERSION}" || "${RECORDED}" != "${VERSION}" ]]; then
    die "The app was built as ${RECORDED} (bundle ${BUILT}), not ${VERSION}."
fi
for file in "${SHARE_FILES[@]}"; do
    [[ -f "${file}" ]] || die "The build left no ${file}."
done

# The app was built from the working tree: it must still be the tagged commit.
assert_unchanged_since "${RELEASE_COMMIT}" "the build"
# Main and the tag together, or neither.
run "Pushing main and ${TAG} to GitHub" git push --atomic origin main "${TAG}"
PUSHED=1

run "Making a draft release on GitHub" gh release create "${TAG}" --draft --verify-tag --title "${TAG}" \
    --notes-file "${NOTES_DIR}/notes.md" "${SHARE_FILES[@]}"
DRAFTED=1

URL="$(gh release view "${TAG}" --json url --jq .url || true)"
printf '\nDraft release %s is ready: %s\n\n' "${TAG}" "${URL:-see the releases page on GitHub}"
frame_timings_report "${FRAME_TIMINGS}" "${PREVIOUS}" "${MACHINE}" || true
printf '\nRead the draft over, then press Publish release.\n'
