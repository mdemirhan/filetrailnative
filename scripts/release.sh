#!/bin/bash
# Port of apps/desktop/scripts/release.ts
# Makes a release: scripts/release.sh <major|minor|patch|X.Y.Z> [--yes] [--dry-run]
#
# From a clean main that is already on GitHub, it checks the commit (scripts/ci.sh with the large-file tests), tags it vX.Y.Z (the version
# comes from the tag, see scripts/version.sh), builds the signed and notarized app, pushes the tag, and makes a draft GitHub
# release with the disk image and the ZIP. The notes start as a list of the commits since the last release: rewrite them,
# then publish the release on GitHub. Nothing is published by this script.
#
# The first release is asked for by exact version: there is no release yet for major, minor or patch to count from.
#
# --dry-run stops after saying what it would release. --yes skips the question before the release starts.
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"
# shellcheck source=lib/release-lib.sh
source scripts/lib/release-lib.sh

OUT_DIR="build/release"
APP_BUNDLE="${OUT_DIR}/File Trail.app"
SHARE_FILES=("${OUT_DIR}/FileTrail-arm64.dmg" "${OUT_DIR}/FileTrail-arm64.zip")
USAGE="Usage: scripts/release.sh <major|minor|patch|X.Y.Z> [--yes] [--dry-run]"

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
YES=0
DRY_RUN=0
for arg in "$@"; do
    case "${arg}" in
        --yes) YES=1 ;;
        --dry-run) DRY_RUN=1 ;;
        --*) die "${USAGE}" ;;
        *) [[ -n "${REQUEST}" ]] || REQUEST="${arg}" ;;
    esac
done
[[ -n "${REQUEST}" ]] || die "${USAGE}"

# What stands in the way of releasing this commit, one a line; nothing when it can be released.
PROBLEMS=""
add_problem() {
    PROBLEMS+="$1"$'\n'
}

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
if ! command -v gh >/dev/null; then
    add_problem "gh isn't installed: the draft release is made with it."
elif ! gh auth status >/dev/null 2>&1; then
    add_problem "gh isn't signed in to GitHub: run gh auth login first."
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
if [[ -n "${LATEST_ON_GITHUB}" ]]; then
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

run "Build, every test including the large-file ones, and format lint" env FILETRAIL_LARGE_FILE_TESTS=1 scripts/ci.sh

# The checks take minutes: what is tagged must still be what was checked.
assert_unchanged_since "${CHECKED_COMMIT}" "the checks"

TAGGED=0
PUSHED=0
DRAFTED=0
NOTES_DIR=""
finish() {
    local status=$?
    [[ -z "${NOTES_DIR}" ]] || rm -rf "${NOTES_DIR}"
    if [[ "${status}" != 0 && "${TAGGED}" == 1 ]]; then
        if [[ "${PUSHED}" == 0 ]]; then
            # Not on GitHub yet: the tag goes, so the release can simply be tried again.
            git tag -d "${TAG}" >/dev/null 2>&1 || true
            printf '\n%s was removed again; nothing reached GitHub.\n' "${TAG}" >&2
        elif [[ "${DRAFTED}" == 0 ]]; then
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

run "Tagging ${TAG}" git tag -a "${TAG}" -m "File Trail ${VERSION}"
TAGGED=1
NOTES_DIR="$(mktemp -d -t filetrail-release)"

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
assert_unchanged_since "${CHECKED_COMMIT}" "the build"
run "Pushing ${TAG} to GitHub" git push origin "${TAG}"
PUSHED=1

draft_release_notes <<<"${SUBJECTS}" >"${NOTES_DIR}/notes.md"
run "Making a draft release on GitHub" gh release create "${TAG}" --draft --verify-tag --title "${TAG}" \
    --notes-file "${NOTES_DIR}/notes.md" "${SHARE_FILES[@]}"
DRAFTED=1

URL="$(gh release view "${TAG}" --json url --jq .url || true)"
printf '\nDraft release %s is ready: %s\n' "${TAG}" "${URL:-see the releases page on GitHub}"
echo "Rewrite the notes for people, then press Publish release."
