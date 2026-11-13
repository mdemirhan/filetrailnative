# File Trail

A native macOS file browser in Swift and AppKit. It's a Swift package with no Xcode project.

## Commands

- Check changes: `scripts/ci.sh --scope <filter>`, `scripts/ci.sh --affected` for the test bundles the changed files can reach, or `scripts/ci.sh` for everything (the app and the tests built with zero warnings, the tests, format lint). `--full` also builds from clean and builds the release app, as `scripts/release.sh` does. Logs are in `build/logs/`.
- Tests that drive real windows: `FILETRAIL_GUI_TESTS=1 swift test --filter GUITests` runs all of them (every such suite's name ends in `GUITests`). `scripts/release.sh` runs them.
- Large-file tests: set `FILETRAIL_LARGE_FILE_TESTS=1`. A release runs them.
- Release-only tests (the test helpers' own tests, the 150,000-file paste, the file-limit walk, a second launch): set `FILETRAIL_RELEASE_TESTS=1`. A release runs them, and the fuzz tests at more cases from a seed of the day: `UNDO_FUZZ_CASES`/`UNDO_FUZZ_SEED` and `BATCH_RENAME_FUZZ_CASES`/`BATCH_RENAME_FUZZ_SEED` run a seed again.
- App: `scripts/build-app.sh`, then `open "build/File Trail.app"`.
- Release: `scripts/release.sh <major|minor|patch|X.Y.Z>` makes a draft GitHub release; publishing stays manual.
- README screenshots: `scripts/readme-screenshots.sh`.

## Test data

- `Tests/Golden/*.json` are expected results kept by hand. Some were first recorded from the Electron app, and some have been recorded again from this app's output since (`help-content.json`). When behavior changes on purpose, update them by hand.
- Fixtures are built by `bun tools/fixtures/generate.ts` (it needs [Bun](https://bun.sh)) into `~/Library/Caches/filetrail-dev`. The tests that read them are skipped without them; `scripts/release.sh` refuses to start.
- Comments describe this app on its own terms: no record IDs (`B-…`, `F-…`, `T-…`), "Port of …" headers, Electron file or function names, or comparisons with "the original".

## Design

- Prefer the system's look on current macOS: Liquid Glass for tabs and toolbars, Finder's symbols. Font sizes and row heights stay the app's own, not Finder's.
- A window holds at most 25 tabs.

The owner's decisions are in `docs/decisions.md`: read it before changing anything it covers. Open issues are in `docs/known-issues.md` and `docs/battery.md`.

## Don't add

- Benchmarks: no bench scripts, benchmark tests, budgets or `--bench` modes. The owner removed them; a CPU-time test (`CPUTime.measureThread`) guards a speed fix where one is needed.
