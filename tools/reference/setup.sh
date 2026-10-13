#!/usr/bin/env bash
# Builds the original Electron app at the pinned commit into the shared cache.
set -Eeuo pipefail

SRC=/Users/tcmudemirhan/src/tsproj/filetrail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CACHE="${FILETRAIL_PORT_CACHE:-$HOME/Library/Caches/filetrail-port}"
DEST="$CACHE/reference/electron"
STAMP="$CACHE/reference/electron.stamp"
COMMIT="$(grep -o '"referenceCommit": *"[^"]*"' "$REPO/docs/port/state/orchestrator.json" | sed 's/.*: *"\(.*\)"/\1/')"
[[ -n "$COMMIT" ]] || { echo "no referenceCommit in orchestrator.json" >&2; exit 1; }

if [[ -f "$STAMP" && "$(cat "$STAMP")" == "ok $COMMIT" && -d "$DEST/apps/desktop/dist/main" ]]; then
  echo "up to date ($COMMIT)"
  exit 0
fi

mkdir -p "$CACHE/reference"
rm -f "$STAMP"
if [[ ! -d "$DEST/.git" ]]; then
  rm -rf "$DEST"
  git clone --quiet "$SRC" "$DEST"
fi
git -C "$DEST" checkout --quiet --detach "$COMMIT"

# bun.lock is gitignored in the original; copy it read-only.
rm -f "$DEST/bun.lock"
cp "$SRC/bun.lock" "$DEST/bun.lock"
chmod a-w "$DEST/bun.lock"
cd "$DEST"
if ! bun install --frozen-lockfile; then
  echo "warning: frozen install failed, falling back to plain bun install" >&2
  chmod u+w bun.lock
  bun install
fi

# bun skips dependency postinstall scripts, so Electron's binary has to be fetched here.
ELECTRON_PKG="$(cd apps/desktop && bun -e "console.log(require.resolve('electron/package.json'))")"
if [[ ! -d "$(dirname "$ELECTRON_PKG")/dist/Electron.app" ]]; then
  (cd "$(dirname "$ELECTRON_PKG")" && node install.js)
fi

bun run --cwd apps/desktop build:native
bun run desktop:build

if [[ ! -d apps/desktop/dist/main ]]; then
  echo "build produced no apps/desktop/dist/main" >&2
  exit 1
fi

if bun run --cwd apps/desktop test:smoke -- smoke.spec.ts > "$CACHE/reference/smoke.log" 2>&1; then
  echo "smoke: passed"
else
  echo "smoke: could not pass here (see $CACHE/reference/smoke.log)"
fi

echo "ok $COMMIT" > "$STAMP"
echo "built $COMMIT at $DEST"
