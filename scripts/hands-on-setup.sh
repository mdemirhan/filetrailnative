#!/bin/bash
# Makes the files for the hands-on checks: a folder in your home folder and a small disk image of the same files,
# mounted as a second disk, so copies, moves and the Trash cross a real disk boundary. Nothing else is touched.
# Usage: scripts/hands-on-setup.sh [folder] (default ~/FileTrail-HandsOn), then scripts/hands-on-setup.sh --clean
set -euo pipefail

root="${1:-$HOME/FileTrail-HandsOn}"
disk="FT-HandsOn"

if [ "$root" = --clean ]; then
    hdiutil detach "/Volumes/$disk" -quiet 2>/dev/null || true
    rm -rf "$HOME/FileTrail-HandsOn"
    echo "Removed ~/FileTrail-HandsOn and ejected $disk."
    exit 0
fi

if [ -e "$root" ]; then
    echo "$root already exists. Run scripts/hands-on-setup.sh --clean first." >&2
    exit 1
fi
if [ -e "/Volumes/$disk" ]; then
    echo "$disk is already mounted. Run scripts/hands-on-setup.sh --clean first." >&2
    exit 1
fi

fill() {
    local base="$1"
    mkdir -p "$base/Source/Nested/Deeper" "$base/Destination/Shared/Old" "$base/Destination/Empty" "$base/Rename"
    printf 'from source\n' >"$base/Source/conflict.txt"
    printf 'from destination\n' >"$base/Destination/conflict.txt"
    printf 'new in source\n' >"$base/Source/Shared.txt"
    mkdir -p "$base/Source/Shared/New"
    printf 'source side\n' >"$base/Source/Shared/both.txt"
    printf 'destination side\n' >"$base/Destination/Shared/both.txt"
    printf 'only in destination\n' >"$base/Destination/Shared/Old/keep.txt"
    printf 'deep\n' >"$base/Source/Nested/Deeper/deep.txt"
    for i in 1 2 3 4 5 6; do printf 'file %s\n' "$i" >"$base/Rename/photo $i.txt"; done
    mkfile -n 400m "$base/Source/large-file.bin"
    ln -s "../Source/conflict.txt" "$base/Destination/a-symlink"
    : >"$base/Source/.hidden-file"
}

fill "$root"

image="$root/$disk.dmg"
hdiutil create -quiet -size 1g -fs APFS -volname "$disk" "$image"
hdiutil attach -quiet "$image"
fill "/Volumes/$disk"

echo "Ready: $root and /Volumes/$disk"
