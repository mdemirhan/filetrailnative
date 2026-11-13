# shellcheck source=frame-timing-limits.sh
source "$(dirname "${BASH_SOURCE[0]}")/frame-timing-limits.sh"
# shellcheck source=test-runs.sh
source "$(dirname "${BASH_SOURCE[0]}")/test-runs.sh"

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


# MARK: Frame times of scrolling
#
# A release's frame times (FrameTimeGUITests' file): {"timings": [{"view", "size", "medianMs", "lateShare",
# "slowestMs"}]}. The history (docs/frame-timings.json): {"releases": [{"version", "date", "machine", "macOS",
# "timings": [...]}]}, the oldest first.

# frame_timings_record <version> <date> <machine model> <macOS version> <timings file>: the release's record.
frame_timings_record() {
    jq -c --arg version "$1" --arg date "$2" --arg machine "$3" --arg macos "$4" \
        '{version: $version, date: $date, machine: $machine, macOS: $macos, timings: .timings}' "$5"
}

# frame_timings_append <history file> <record>: the history with the record added at its end; a history that isn't there
# yet starts with it.
frame_timings_append() {
    if [[ -f "$1" ]]; then
        jq --argjson record "$2" '.releases += [$record]' "$1"
    else
        jq -n --argjson record "$2" '{releases: [$record]}'
    fi
}

# frame_timings_previous <history file> <machine model>: the last record made on that Mac model; nothing without one.
frame_timings_previous() {
    [[ -f "$1" ]] || return 0
    jq -c --arg machine "$2" '[.releases[] | select(.machine == $machine)] | last // empty' "$1"
}

# frame_timings_table <timings file> <previous record or "">: each view and size, now and before, as a table.
frame_timings_table() {
    local previous="${2:-null}"
    printf '%-8s %-8s %8s %8s %8s   %7s %7s %8s   %8s %8s\n' View Size "Median" before change "Late" before change \
        "Slowest" before
    jq -r --argjson previous "${previous}" '
        .timings[] as $now
        | ($previous // {timings: []} | .timings | map(select(.view == $now.view and .size == $now.size)) | first)
            as $was
        | [$now.view, $now.size, $now.medianMs, ($was.medianMs // ""), $now.lateShare, ($was.lateShare // ""),
            $now.slowestMs, ($was.slowestMs // "")]
        | map(tostring) | join("|")' "$1" |
        while IFS='|' read -r view size median median_before late late_before slowest slowest_before; do
            local median_change="" late_change=""
            if [[ -n "${median_before}" ]]; then
                median_change="$(awk -v now="${median}" -v was="${median_before}" \
                    'BEGIN { printf "%+.0f%%", (was > 0 ? (now - was) / was * 100 : 0) }')"
                late_change="$(awk -v now="${late}" -v was="${late_before}" 'BEGIN { printf "%+.1f pt", (now - was) * 100 }')"
                median_before="$(printf '%.2f ms' "${median_before}")"
                late_before="$(awk -v was="${late_before}" 'BEGIN { printf "%.1f%%", was * 100 }')"
                slowest_before="$(printf '%.1f ms' "${slowest_before}")"
            fi
            printf '%-8s %-8s %8s %8s %8s   %7s %7s %8s   %8s %8s\n' "${view}" "${size}" \
                "$(printf '%.2f ms' "${median}")" "${median_before}" "${median_change}" \
                "$(awk -v now="${late}" 'BEGIN { printf "%.1f%%", now * 100 }')" "${late_before}" "${late_change}" \
                "$(printf '%.1f ms' "${slowest}")" "${slowest_before}"
        done
}

# frame_timings_report <timings file> <previous record or ""> <machine model>: says what the timings are compared with,
# the table, and what is too slow, one a line; fails when anything is. Against a record from the same Mac model, a
# median more than FRAME_MEDIAN_SLOWER_SHARE slower or a share of late frames more than FRAME_LATE_SHARE_RISE above it
# fails; with none, only the ceilings apply. The slowest frame is shown, and fails nothing.
frame_timings_report() {
    local timings="$1" previous="$2" machine="$3" failures
    if [[ -n "${previous}" ]]; then
        printf 'Frame times of scrolling, against %s (%s) on the same Mac model (%s).\n' \
            "$(jq -r .version <<<"${previous}")" "$(jq -r .date <<<"${previous}")" "${machine}"
        printf 'Too slow: a median over %.0f%% slower, or late frames up more than %.0f points.\n' \
            "$(awk -v s="${FRAME_MEDIAN_SLOWER_SHARE}" 'BEGIN { print s * 100 }')" \
            "$(awk -v s="${FRAME_LATE_SHARE_RISE}" 'BEGIN { print s * 100 }')"
    else
        printf 'Frame times of scrolling. No earlier release was measured on this Mac model (%s): only the ceilings apply.\n' \
            "${machine}"
        printf 'Too slow: a median over %s ms, or over %.0f%% of frames late.\n' "${FRAME_MEDIAN_CEILING_MS}" \
            "$(awk -v s="${FRAME_LATE_SHARE_CEILING}" 'BEGIN { print s * 100 }')"
    fi
    echo "Each is the median of three scrolls; late is over 8.3 ms, a frame at 120 Hz."
    frame_timings_table "${timings}" "${previous}"
    failures="$(jq -r --argjson previous "${previous:-null}" \
        --argjson share "${FRAME_MEDIAN_SLOWER_SHARE}" --argjson rise "${FRAME_LATE_SHARE_RISE}" \
        --argjson ceiling "${FRAME_MEDIAN_CEILING_MS}" --argjson lateCeiling "${FRAME_LATE_SHARE_CEILING}" '
        .timings[] as $now
        | "\($now.view) at the \($now.size) size" as $name
        | if $previous == null then
            (if $now.medianMs > $ceiling then "\($name): the median frame took \($now.medianMs) ms" else empty end),
            (if $now.lateShare > $lateCeiling then "\($name): \($now.lateShare * 100) % of frames were late"
             else empty end)
          else
            ($previous.timings | map(select(.view == $now.view and .size == $now.size)) | first) as $was
            | if $was == null then empty else
                (if $now.medianMs > $was.medianMs * (1 + $share)
                 then "\($name): the median frame took \($now.medianMs) ms, \($was.medianMs) ms before" else empty end),
                (if $now.lateShare > $was.lateShare + $rise
                 then "\($name): \($now.lateShare * 100) % of frames were late, \($was.lateShare * 100) % before"
                 else empty end)
              end
          end' "${timings}")"
    if [[ -n "${failures}" ]]; then
        echo "Scrolling got slower:"
        sed 's/^/  /' <<<"${failures}"
        return 1
    fi
}
