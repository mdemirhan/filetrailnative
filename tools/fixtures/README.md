# tools/fixtures

Shared, deterministic fixtures in `~/Library/Caches/filetrail-dev/fixtures` (override the cache with `FILETRAIL_DEV_CACHE`).

- `bun tools/fixtures/generate.ts [lighthouse|bench|names ...]` builds the trees. Each has a `.fixture-version` stamp and is skipped when current.
  - `lighthouse/Lighthouse`: the README screenshots' demo project. Every mtime is an offset from `FIXTURE_NOW` (2026-10-13 14:38 local), the time captures freeze their clocks to. Big files are sparse.
  - `bench/files-{300,3000,30000,100000}` and `bench/deep` (200,000 files in 20,000 folders).
  - `names/`: edge-case names, packages, links, an alias, a locked file, a custom icon (the last two or three are skipped quietly when macOS refuses).
