# Port of apps/desktop/scripts/lib/releaseNotes.ts, releaseState.ts, and nextVersion and readReleaseTags of version.ts
# What scripts/release.sh decides, apart from what it does. Sourced; each function prints its answer.

# The tags on stdin that are releases (vX.Y.Z; a tag with a suffix isn't one).
release_tags() {
    { grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' || true; }
}

# The highest release among the tags on stdin, as X.Y.Z; nothing when there is none.
latest_release() {
    release_tags | sed 's/^v//' | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1
}

# next_version <latest or ""> <request>: the version a release asked for as "major", "minor", "patch" or "X.Y.Z" gets. An
# exact version must come after the last release. Fails with the reason on stderr.
next_version() {
    local latest="$1" request="$2" major=0 minor=0 patch=0
    if [[ -n "${latest}" ]]; then
        IFS=. read -r major minor patch <<<"${latest}"
    fi
    major=$((10#${major}))
    minor=$((10#${minor}))
    patch=$((10#${patch}))
    case "${request}" in
        major)
            echo "$((major + 1)).0.0"
            return 0
            ;;
        minor)
            echo "${major}.$((minor + 1)).0"
            return 0
            ;;
        patch)
            echo "${major}.${minor}.$((patch + 1))"
            return 0
            ;;
    esac
    if [[ ! "${request}" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
        echo "\"${request}\" is not major, minor, patch or a version like 0.2.0." >&2
        return 1
    fi
    local exact_major=$((10#${BASH_REMATCH[1]})) exact_minor=$((10#${BASH_REMATCH[2]})) exact_patch=$((10#${BASH_REMATCH[3]}))
    local exact="${exact_major}.${exact_minor}.${exact_patch}"
    if [[ -n "${latest}" ]] && {
        ((exact_major < major)) ||
            { ((exact_major == major)) && ((exact_minor < minor)); } ||
            { ((exact_major == major)) && ((exact_minor == minor)) && ((exact_patch <= patch)); }
    }; then
        echo "${exact} is not after the last release, ${latest}." >&2
        return 1
    fi
    echo "${exact}"
}

# find_unfinished_releases <local tags> <remote tags> <latest tag on GitHub or ""> <its state: published, draft, missing>
# What a release left unfinished, one problem a line, so the next one doesn't take a version past it: the next version
# comes from the release tags, so a tag whose release never came out would be skipped over. The tags are one a line.
find_unfinished_releases() {
    local local_tags="$1" remote_tags="$2" latest_tag="$3" latest_state="$4" tag
    while IFS= read -r tag; do
        [[ -n "${tag}" ]] || continue
        if ! grep -Fxq -- "${tag}" <<<"${remote_tags}"; then
            echo "${tag} is only on this Mac, left by a release that stopped before pushing it: delete it (git tag -d ${tag}) and run again."
        fi
    done <<<"${local_tags}"
    if [[ "${latest_state}" == draft ]]; then
        echo "${latest_tag}'s release is still a draft: publish it on GitHub, or delete it and its tag (git push origin :${latest_tag}; git tag -d ${latest_tag}), before making another."
    elif [[ "${latest_state}" == missing ]]; then
        echo "${latest_tag} is on GitHub without a release, left by a release that stopped after pushing it: make its release on GitHub, or delete the tag (git push origin :${latest_tag}; git tag -d ${latest_tag}) to start over."
    fi
}

# draft_release_notes: a first draft of a release's notes from the commit subjects on stdin: a "What's new" list with one
# line per commit since the last release, to be rewritten for people before the release is published.
draft_release_notes() {
    local items
    items="$(sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' |
        { grep -Ev '^$|^Merge (branch|pull request)([^[:alnum:]_]|$)' || true; } |
        sed 's/^/- /')"
    echo "<!-- Draft: one line per commit since the last release. Rewrite it for people, then publish. -->"
    echo "### What's new"
    echo "${items:-- }"
}
