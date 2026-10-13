# tools/reference

A build of the original Electron app (pinned commit in `docs/port/state/orchestrator.json`) to compare against. It lives in `~/Library/Caches/filetrail-port/reference/electron` (override the cache with `FILETRAIL_PORT_CACHE`), never in a checkout.

- `setup.sh` clones the original locally, checks out the pinned commit, installs with the original's `bun.lock`, fetches Electron's binary, builds the native addon and the app, and runs the Playwright smoke spec (a failure there is reported, not fatal). A second run prints `up to date`.
- `run.sh [--user-data-dir DIR] [FOLDER]` starts the built app without rebuilding.
