# File Trail

A native macOS file browser in Swift and AppKit. It's a Swift package with no Xcode project.

## Read first

- `docs/principles.md`: the few rules over everything else. A decision is a default to ask about, not a wall; safety is weighed against what it costs the ordinary case; do what was asked; ask the owner only what is the owner's to say.
- `docs/decisions.md`: the owner's decisions, each with its reason, by area in `docs/decisions/`. Read the part that covers what is being changed before changing it.
- `docs/working/reviews.md`: how a review's findings are reported (blocker or not, and why what was left was left). Give it to any reviewer started for one.
- Open issues are in `docs/state/known-issues.md` and `docs/state/battery.md`; what was learned finding a stalled test run or a permission question is in `docs/working/debugging.md`. `docs/README.md` says what is where.

## Commands

- Check changes: `scripts/ci.sh --scope <filter>`, `scripts/ci.sh --affected` for the test bundles the changed files can reach, or `scripts/ci.sh` for everything (the app and the tests built with zero warnings, the tests, format lint). `--full` also builds from clean and builds the release app, as `scripts/release.sh` does. Logs are in `build/logs/`. Its test processes play no alert sounds (`tools/silent-alerts`); `FILETRAIL_ALERTS_LOG=<file>` lists each one with where it came from.
- Tests that drive real windows: `FILETRAIL_GUI_TESTS=1 swift test --filter GUITests` runs all of them (every such suite's name ends in `GUITests`). `scripts/release.sh` runs them.
- Large-file tests: set `FILETRAIL_LARGE_FILE_TESTS=1`. A release runs them.
- Release-only tests (the test helpers' own tests, the 150,000-file paste, the file-limit walk, a second launch): set `FILETRAIL_RELEASE_TESTS=1`. A release runs them, and the fuzz tests at more cases from a seed of the day: `UNDO_FUZZ_CASES`/`UNDO_FUZZ_SEED` and `BATCH_RENAME_FUZZ_CASES`/`BATCH_RENAME_FUZZ_SEED` run a seed again.
- One `scripts/ci.sh` or `swift test` at a time on this Mac: several at once stall each other. Agents working side by side put every such run behind one lock (`/usr/bin/lockf <scratch>/filetrail-ci.lock scripts/ci.sh --scope '…'`), keep their runs scoped, and leave the one full run for the end; a plain `swift build` may run outside it. Say so in the brief of any agent that may run tests.
- A run that stalls or fails now and then is looked into, not run again: `docs/working/debugging.md`.
- App: `scripts/build-app.sh`, then `open "build/File Trail.app"`. To try a change by hand, `scripts/build-app.sh debug` and a scratch `--automation` scenario: `tools/capture/README.md`.
- Release: `scripts/release.sh <major|minor|patch|X.Y.Z> --notes <file>` makes a draft GitHub release; publishing stays manual. A release is `minor` unless the owner asks otherwise, and its notes are for the people who use the app (`docs/decisions/code.md`). The notes are written for people before it starts and become the draft's text and the tag's message. It measures the frame times of scrolling, shows them against the last release on the same Mac model, stops on a clear slowdown, and keeps them in `docs/frame-timings.json` in the commit it tags. A release run by an agent shows the owner that table once the draft is made, and is published only with the owner's explicit yes.
- README screenshots: `scripts/readme-screenshots.sh`.

## Test data

- `Tests/Golden/*.json` are expected results kept by hand. Some were first recorded from the Electron app, and some have been recorded again from this app's output since (`help-content.json`). When behavior changes on purpose, update them by hand.
- Fixtures are built by `bun tools/fixtures/generate.ts` (it needs [Bun](https://bun.sh)) into `~/Library/Caches/filetrail-dev`. The tests that read them are skipped without them; `scripts/release.sh` refuses to start.
- Comments describe this app on its own terms: no record IDs (`B-…`, `F-…`, `T-…`), "Port of …" headers, Electron file or function names, or comparisons with "the original".

## Design

- Prefer the system's look on current macOS: Liquid Glass for tabs and toolbars, Finder's symbols. Font sizes and row heights stay the app's own, not Finder's.
- A window holds at most 25 tabs.

## Working in this repository

- Work lands on local `main` by fast-forward or rebase, with no pull requests and no merge commits, and nothing is pushed unless the owner asks (`docs/decisions/code.md`).
- A request to delete worktrees or branches covers the ones this session made, however it is worded: others that look idle or merged may be another session's work. List them and ask.

## Benchmarks

- Only a few, and only ones that gate a release: today the frame times of scrolling (`FrameTimeGUITests`, run by `scripts/release.sh`, limits in `scripts/lib/frame-timing-limits.sh`). None run in plain CI. No other bench scripts, benchmark tests, budgets or `--bench` modes; a CPU-time test (`CPUTime.measureThread`) guards a speed fix where one is needed.
