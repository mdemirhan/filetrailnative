# tools/fixtures

Shared, deterministic fixtures in `~/Library/Caches/filetrail-dev/fixtures` (override the cache with `FILETRAIL_DEV_CACHE`).

- `bun tools/fixtures/generate.ts [lighthouse|large|names|diskimages ...]` builds the trees. Each has a `.fixture-version` stamp and is skipped when current.
  - `lighthouse/Lighthouse`: the README screenshots' demo project. Recent mtimes are offsets from `FIXTURE_NOW` (2026-10-13 14:38 local); `scripts/readme-screenshots.sh` freezes the app's clock at 14:46. Big files are sparse.
  - `large/files-{300,3000}`: folders of many small files, which the folder-size golden measures.
  - `names/`: edge-case names, packages, links, an alias, a locked file, a custom icon (the last two or three are skipped quietly when macOS refuses).
  - `diskimages/`: one small disk image of each format, compression, partition map and file system hdiutil makes (read/write, UDIF compressed four ways and not, ISO and UDF, sparse images and bundles, encrypted), each named for what it holds, for the Info panel's reader of their headers. About 300 MB. Only this script runs hdiutil; the app reads the images' bytes itself.
