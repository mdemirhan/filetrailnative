#!/bin/bash
# Usage: scripts/frame-times.sh [--out <file>] [--against <file>]
#
# Measures the frame times of scrolling on demand: FrameTimeGUITests puts a window on a folder of 3,000 files on screen
# and scrolls the List, the Icons view and the Compact List, each at its default size and at its largest, three times.
# It runs behind the test lock, needs the fixture trees (bun tools/fixtures/generate.ts) and jq, and writes the numbers
# to --out (build/frame-timings.json by default).
#
# The table compares them with the file of an earlier run (--against), or else with the last release measured on this
# Mac model in docs/frame-timings.json, which holds the releases that kept them, up to 1.7.0. Nothing passes or fails:
# what is measured on one Mac moves with its load and its power, so a comparison is worth most against a run made just
# before, on the same Mac (a checkout of the other commit, run with --out, then this one with --against that file).
set -Eeuo pipefail

CALLER_DIR="${PWD}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"
# shellcheck source=lib/frame-times-lib.sh
source scripts/lib/frame-times-lib.sh
USAGE="Usage: scripts/frame-times.sh [--out <file>] [--against <file>]"

die() {
    echo "$1" >&2
    exit 1
}

OUT="build/frame-timings.json"
AGAINST=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --out | --against)
            [[ $# -ge 2 && -n "$2" ]] || die "${USAGE}"
            if [[ "$1" == --out ]]; then OUT="$2"; else AGAINST="$2"; fi
            shift
            ;;
        *) die "${USAGE}" ;;
    esac
    shift
done
# A relative path is from where the script was started; the default is the checkout's.
[[ "${OUT}" == /* || "${OUT}" == build/frame-timings.json ]] || OUT="${CALLER_DIR}/${OUT}"
[[ -z "${AGAINST}" || "${AGAINST}" == /* ]] || AGAINST="${CALLER_DIR}/${AGAINST}"
command -v jq >/dev/null || die "jq isn't installed: the frame times are read with it."
[[ -z "${AGAINST}" || -r "${AGAINST}" ]] || die "${AGAINST} can't be read."

mkdir -p "$(dirname "${OUT}")"
rm -f "${OUT}"
FILETRAIL_GUI_TESTS=1 FILETRAIL_FRAME_TIMES=1 FILETRAIL_FRAME_TIMINGS_OUT="$(cd "$(dirname "${OUT}")" && pwd)/$(basename "${OUT}")" \
    scripts/with-test-lock.sh swift test --filter FrameTimeGUITests || die "The frame-time test failed."
[[ -f "${OUT}" ]] || die "The frame-time test left no timings in ${OUT}."

MACHINE="$(sysctl -n hw.model)"
if [[ -n "${AGAINST}" ]]; then
    PREVIOUS="$(jq -c . "${AGAINST}")" || die "${AGAINST} couldn't be read."
    printf '\nFrame times of scrolling on %s, against %s.\n' "${MACHINE}" "${AGAINST}"
else
    PREVIOUS="$(frame_timings_previous docs/frame-timings.json "${MACHINE}")" || die "docs/frame-timings.json couldn't be read."
    if [[ -n "${PREVIOUS}" ]]; then
        printf '\nFrame times of scrolling on %s, against %s (%s).\n' "${MACHINE}" \
            "$(jq -r .version <<<"${PREVIOUS}")" "$(jq -r .date <<<"${PREVIOUS}")"
    else
        printf '\nFrame times of scrolling on %s; no release was measured on this Mac model.\n' "${MACHINE}"
    fi
fi
echo "Each is the median of three scrolls; late is over 8.3 ms, a frame at 120 Hz."
frame_timings_table "${OUT}" "${PREVIOUS}"
printf 'Written to %s.\n' "${OUT}"
