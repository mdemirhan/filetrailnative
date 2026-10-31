# File Trail

A native macOS file browser in Swift and AppKit. It's a Swift package with no Xcode project.

## Commands

- Check changes: `scripts/ci.sh --scope <filter>`, or `scripts/ci.sh` for everything (build with zero warnings, tests, format lint). Logs are in `build/logs/`.
- Tests that drive real windows: `FILETRAIL_GUI_TESTS=1 swift test --filter GUITests`.
- Large-file tests: set `FILETRAIL_LARGE_FILE_TESTS=1`. A release runs them.
- App: `scripts/build-app.sh`, then `open "build/File Trail.app"`.
- Release: `scripts/release.sh <version>` makes a draft GitHub release; publishing stays manual.
- README screenshots: `scripts/readme-screenshots.sh`.

## Test data

- `Tests/Golden/*.json` were recorded from the Electron app and are now frozen expected results. When behavior changes on purpose, update them by hand.
- Fixtures are built by `tools/fixtures/` into `~/Library/Caches/filetrail-dev`.
- Comments citing `T-`, `F-`, `B-` and `D-` IDs or "Port of …" point at the port's records, kept in a private archive. `D-` IDs are in `docs/differences-from-electron.md`. They don't need maintaining.

## Design

- Prefer the system's look on current macOS: Liquid Glass for tabs and toolbars, Finder's symbols, font sizes and row heights.
- A window holds at most 25 tabs.

Open issues are in `docs/known-issues.md` and `docs/battery.md`.
