# File Trail

A native macOS file browser in Swift and AppKit. It's a Swift package with no Xcode project.

## Commands

- Check changes: `scripts/ci.sh --scope <filter>`, `scripts/ci.sh --affected` for the test bundles the changed files can reach, or `scripts/ci.sh` for everything (the app and the tests built with zero warnings, the tests, format lint). `--full` also builds from clean and builds the release app, as `scripts/release.sh` does. Logs are in `build/logs/`.
- Tests that drive real windows: `FILETRAIL_GUI_TESTS=1 swift test --filter GUITests`.
- Large-file tests: set `FILETRAIL_LARGE_FILE_TESTS=1`. A release runs them.
- App: `scripts/build-app.sh`, then `open "build/File Trail.app"`.
- Release: `scripts/release.sh <version>` makes a draft GitHub release; publishing stays manual.
- README screenshots: `scripts/readme-screenshots.sh`.

## Test data

- `Tests/Golden/*.json` were recorded from the Electron app and are now frozen expected results. When behavior changes on purpose, update them by hand.
- Fixtures are built by `bun tools/fixtures/generate.ts` (it needs [Bun](https://bun.sh)) into `~/Library/Caches/filetrail-dev`. The tests that read them are skipped without them; `scripts/release.sh` refuses to start.
- Comments describe this app on its own terms: no record IDs (`B-…`, `F-…`, `T-…`), "Port of …" headers, Electron file or function names, or comparisons with "the original".

## Design

- Prefer the system's look on current macOS: Liquid Glass for tabs and toolbars, Finder's symbols, font sizes and row heights.
- A window holds at most 25 tabs.

Open issues are in `docs/known-issues.md` and `docs/battery.md`.
