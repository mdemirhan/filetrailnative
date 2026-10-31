#!/usr/bin/env bash
# Blank sparse disk images, made once, and copy-on-write clones of them.
#   disk-images.sh                 make any missing blank image
#   disk-images.sh clone <fs> <dest>   clone one of the parity images (cp -c) to <dest>
#
#   fixtures/disks/<fs>.sparseimage  256 MB, for the write-engine goldens; <fs> is one of
#                                    fat32 exfat hfs apfs apfs-cs
# The Swift tests (DiskImage, ExecDiskImages) clone none of these: several test processes run at once on this Mac,
# so each of their mounts makes a fresh image with a volume name and UUID of its own (formats and sizes in
# DiskImage.Kind), and no volume is mounted as "<name> 1" beside another of the same name.
set -Eeuo pipefail

CACHE="${FILETRAIL_DEV_CACHE:-$HOME/Library/Caches/filetrail-dev}"
DIR="$CACHE/fixtures/disks"

# name|hdiutil -fs value|volume name (FAT and exFAT names are at most 11 characters)|size in MB
PARITY_FORMATS=(
  "fat32|MS-DOS FAT32|FTTEST|256"
  "exfat|ExFAT|FTTEST|256"
  "hfs|Journaled HFS+|FileTrailTest|256"
  "apfs|APFS|FileTrailTest|256"
  "apfs-cs|Case-sensitive APFS|FileTrailTest|256"
)

retry_hdiutil() {
  local n
  for n in 1 2 3 4 5; do
    if hdiutil "$@" > /dev/null; then return 0; fi
    sleep 1
  done
  return 1
}

# make_blank <folder> <name> <fs> <volume name> <size MB>
make_blank() {
  local dir="$1" name="$2" fs="$3" vol="$4" size="$5" path partial
  path="$dir/$name.sparseimage"
  [[ -f "$path" ]] && return 0
  partial="$dir/.$name.partial.sparseimage"
  rm -f "$partial"
  retry_hdiutil create -quiet -ov -type SPARSE -size "${size}m" -fs "$fs" -volname "$vol" "$partial"
  mv "$partial" "$path"
  echo "made $path"
}

if [[ "${1:-}" == "clone" ]]; then
  [[ $# -eq 3 ]] || { echo "usage: $0 clone <fs> <dest>" >&2; exit 2; }
  src="$DIR/$2.sparseimage"
  [[ -f "$src" ]] || { echo "no blank image for '$2' (run $0 first)" >&2; exit 1; }
  cp -c "$src" "$3"
  exit 0
fi

mkdir -p "$DIR"
for entry in "${PARITY_FORMATS[@]}"; do
  IFS='|' read -r name fs vol size <<< "$entry"
  make_blank "$DIR" "$name" "$fs" "$vol" "$size"
done
