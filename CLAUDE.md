# File Trail

A native macOS file browser in Swift and AppKit. It's a Swift package with no Xcode project.

## Read first

- `docs/principles.md`: the few rules over everything else. A decision is a default to ask about, not a wall; safety is weighed against what it costs the ordinary case; do what was asked; ask the owner only what is the owner's to say.
- `docs/decisions.md`: the owner's decisions, each with its reason, by area in `docs/decisions/`. Read the part that covers what is being changed before changing it.
- `docs/process/commands.md`: what a new command needs so it is in the menus, the command palette, Help and Settings → Shortcuts. Follow it for every command added.
- `docs/process/reviews.md`: how a review's findings are reported (blocker or not, and why what was left was left). Give it to any reviewer started for one.
- Open issues are in `docs/state/known-issues.md` and `docs/state/battery.md`, engineering work left for later in `docs/state/tech-debt.md`; what was learned finding a stalled test run or a permission question is in `docs/process/debugging.md`. `docs/README.md` says what is where.

## Commands

- Check changes: `scripts/ci.sh --scope <filter>`, `scripts/ci.sh --affected` for the test bundles the changed files can reach, or `scripts/ci.sh` for everything (the app and the tests built with zero warnings, the tests, format lint). Every run also fails on a new path read back from a file URL in `Sources/` (`url-paths`: `scripts/lib/path-readbacks.sh`, today's in `scripts/lib/url-path-readbacks.txt`). `--full` also builds from clean and builds the release app, as `scripts/release.sh` does. Logs are in `build/logs/`. Its test processes play no alert sounds (`tools/silent-alerts`); `FILETRAIL_ALERTS_LOG=<file>` lists each one with where it came from.
- Tests that drive real windows: `FILETRAIL_GUI_TESTS=1 scripts/with-test-lock.sh swift test --filter GUITests` runs all of them (every such suite's name ends in `GUITests`). `scripts/release.sh` runs them.
- Large-file tests: set `FILETRAIL_LARGE_FILE_TESTS=1`. A release runs them.
- Release-only tests (the test helpers' own tests, the 150,000-file paste, the file-limit walk, a second launch, the accent parity runs on disk images and in most kinds of accented folder, what the system calls an accented name): set `FILETRAIL_RELEASE_TESTS=1`. A release runs them, and the fuzz tests at more cases from a seed of the day: `UNDO_FUZZ_CASES`/`UNDO_FUZZ_SEED` and `BATCH_RENAME_FUZZ_CASES`/`BATCH_RENAME_FUZZ_SEED` run a seed again.
- One test run at a time on this Mac: several at once stall each other. `scripts/ci.sh` waits for any other run itself, from every checkout and worktree of the repository and every session, by a lock in the shared git folder (`scripts/lib/test-lock.sh`), and says whose run it waits for. `--no-lock` runs at once beside the others, only for an exception: a run that holds the lock and can't be stopped, or the owner asking for it; the lock ends with the process that holds it, so a run that crashed never leaves it held. A `swift test` of your own goes behind the same lock: `scripts/with-test-lock.sh swift test --filter …`, never bare, and never behind a lock of your own in a scratch folder, which keeps out no one else's run. Agents side by side keep their runs scoped and leave the one full run for the end; a plain `swift build` needs no lock. Say so in the brief of any agent that may run tests.
- A run that stalls or fails now and then is looked into, not run again: `docs/process/debugging.md`.
- App: `scripts/build-app.sh`, then `open "build/File Trail.app"`. To try a change by hand, `scripts/build-app.sh debug` and a scratch `--automation` scenario: `tools/capture/README.md`.
- Release: `scripts/release.sh <major|minor|patch|X.Y.Z> --notes <file>` makes a draft GitHub release; publishing stays manual. A release is `minor` unless the owner asks otherwise. Its notes are written before it starts, for the people who use the app, as `docs/decisions/code.md` ("Release notes are written for the people who use the app") says, and become the draft's text and the tag's message. A release run by an agent is published only with the owner's explicit yes.
- README screenshots: `scripts/readme-screenshots.sh`.

## Test data

- `Tests/Golden/*.json` are expected results kept by hand (some were first recorded from the Electron app), never regenerated from the code's output. Whoever makes a change updates the goldens it moves, without asking the owner, each value checked against what the change should do; none is deleted without the owner's yes. The rules, the one exception and the bases-and-changes layout are in `docs/decisions/code.md` ("Goldens are expected results kept by hand").
- Fixtures are built by `bun tools/fixtures/generate.ts` (it needs [Bun](https://bun.sh)) into `~/Library/Caches/filetrail-dev`. The tests that read them are skipped without them; `scripts/release.sh` refuses to start.
- Comments describe this app on its own terms: no record IDs (`B-…`, `F-…`, `T-…`), "Port of …" headers, Electron file or function names, or comparisons with "the original".

## Design

- The system's look and Finder's commands, keys and order, except where `docs/decisions.md` says otherwise (the standing decisions there, and the keys that differ from Finder's in `docs/decisions/windows-and-panes.md`).

## Working in this repository

- Never commit to `main` until the owner says so. Work in a worktree of its own (`.claude/worktrees/<name>`, branch `claude/<name>`), never in the main checkout, and commit there. When the owner says to land it, it goes onto local `main` by fast-forward or rebase, with no pull requests and no merge commits. Nothing is pushed unless the owner asks (`docs/decisions/code.md`).
- A commit message is a short subject (about 72 characters at most) saying what is now true, a blank line, then the detail in the body (`docs/decisions/code.md`).
- A request to delete worktrees or branches covers the ones this session made, however it is worded: others that look idle or merged may be another session's work. List them and ask.

## Benchmarks

- Only the frame times of scrolling, measured on demand by `scripts/frame-times.sh`, never by a release or CI (`docs/decisions/code.md`, "The frame times of scrolling are measured on demand"). No other bench scripts, benchmark tests, budgets or `--bench` modes; a CPU-time test (`CPUTime.measureThread`) guards a speed fix where one is needed.
