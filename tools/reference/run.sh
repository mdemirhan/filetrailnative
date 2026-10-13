#!/usr/bin/env bash
# Launches the built reference app without rebuilding. Usage: run.sh [--user-data-dir DIR] [FOLDER]
set -Eeuo pipefail
CACHE="${FILETRAIL_PORT_CACHE:-$HOME/Library/Caches/filetrail-port}"
DEST="$CACHE/reference/electron"
ARGS=()
while (($# > 0)); do
  case "$1" in
    --user-data-dir) ARGS+=("--user-data-dir=$2"); shift ;;
    --user-data-dir=*) ARGS+=("$1") ;;
    -h|--help) echo "Usage: run.sh [--user-data-dir DIR] [FOLDER]"; exit 0 ;;
    *) ARGS+=(--folder "$1") ;;
  esac
  shift
done
[[ -d "$DEST/apps/desktop/dist/main" ]] || { echo "not built: run tools/reference/setup.sh" >&2; exit 1; }
cd "$DEST/apps/desktop"
ELECTRON="$(bun -e "console.log(require('electron'))")"
exec "$ELECTRON" . ${ARGS[@]+"${ARGS[@]}"}
