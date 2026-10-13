#!/usr/bin/env bash
# Blank 256 MB sparse disk images, made once, and copy-on-write clones of them.
#   disk-images.sh                 make any missing blank image
#   disk-images.sh clone <fs> <dest>   clone one (cp -c) to <dest>
# <fs> is one of: fat32 exfat hfs apfs apfs-cs
set -Eeuo pipefail

CACHE="${FILETRAIL_PORT_CACHE:-$HOME/Library/Caches/filetrail-port}"
DIR="$CACHE/fixtures/disks"
SIZE_MB=256

# name|hdiutil -fs value|volume name (FAT and exFAT names are at most 11 characters)
FORMATS=(
  "fat32|MS-DOS FAT32|FTTEST"
  "exfat|ExFAT|FTTEST"
  "hfs|Journaled HFS+|FileTrailTest"
  "apfs|APFS|FileTrailTest"
  "apfs-cs|Case-sensitive APFS|FileTrailTest"
)

retry_hdiutil() {
  local n
  for n in 1 2 3 4 5; do
    if hdiutil "$@" > /dev/null; then return 0; fi
    sleep 1
  done
  return 1
}

make_blank() {
  local name="$1" fs="$2" vol="$3" path="$DIR/$1.sparseimage" partial
  [[ -f "$path" ]] && return 0
  partial="$DIR/.$name.partial.sparseimage"
  rm -f "$partial"
  retry_hdiutil create -quiet -ov -type SPARSE -size "${SIZE_MB}m" -fs "$fs" -volname "$vol" "$partial"
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
for entry in "${FORMATS[@]}"; do
  IFS='|' read -r name fs vol <<< "$entry"
  make_blank "$name" "$fs" "$vol"
done
