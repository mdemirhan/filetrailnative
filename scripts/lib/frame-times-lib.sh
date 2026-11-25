# The frame times of scrolling, read by scripts/frame-times.sh. A run's file (FrameTimeGUITests'): {"timings": [{"view",
# "size", "medianMs", "lateShare", "slowestMs"}]}. The record of the releases that kept them, 0.20.1 to 1.7.0
# (docs/frame-timings.json): {"releases": [{"version", "date", "machine", "macOS", "timings": [...]}]}, the oldest first.

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
