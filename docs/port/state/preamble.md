# File Trail native port: context for every agent

You are part of a team porting File Trail, a macOS file browser, from Electron/TypeScript to native Swift and AppKit. The behavior, flow and design must match the original. The plan is `docs/port/PLAN.md`. Read only the sections your brief cites; do not read whole inventories or the whole plan.

## Places

| What | Where |
|---|---|
| This repo | Your current directory: a git worktree of `/Users/tcmudemirhan/src/swiftproj/filetrail`, whose `main` is the integration branch |
| The original app (READ-ONLY) | `/Users/tcmudemirhan/src/tsproj/filetrail`, pinned at commit `e4d0872`. Never write, build, install or run anything there. Read the files directly, or with `git -C … show e4d0872:<path>` |
| Built copy of the original | `~/Library/Caches/filetrail-port/reference/electron` (made by `tools/reference/setup.sh`; may not exist yet) |
| Shared fixtures and disk images | `~/Library/Caches/filetrail-port/fixtures` |
| Specs | `docs/port/inventory/*.md`, cited by section in your brief |

## Toolchain

- Xcode 27, Swift 6.4, macOS 27, Apple silicon.
- Bun 1.4 for scripts that touch the original's TypeScript.
- `swift-format` via `xcrun swift-format`.
- Don't install anything (no brew, no global npm). Add no Swift package dependencies; the app uses system frameworks only.

## Rules

- **Ownership.** Change only the paths your brief says you own. If you need a change to a shared file (`Package.swift`, `scripts/ci.sh`, `.gitignore`, `DesignTokens.swift`, the command table), describe it under sharedFileRequests in your result instead; the integrator applies it.
- **Swift.**
  - Swift 6 language mode, strict concurrency, zero warnings.
  - UI on `@MainActor`; disk work off the main thread.
  - Tests use Swift Testing (`import Testing`).
- **Style.** Match the existing code: small types, comments only where they explain why, frame-based layout in cells, no force unwraps outside tests.
- **Ported code.** Start each file with a one-line comment naming the TypeScript source it ports, for example `// Port of packages/core/src/fs/copyPasteNames.ts`.
- **Accepted risks.** The cases listed in the original's `docs/FILE_OPERATION_RISKS.md` stay as they are. Don't "fix" them.
- **Git.**
  - Commit often on your branch.
  - No `Co-Authored-By` trailers.
  - Never `git stash`, never push, never commit to `main` (only the integrator merges).
  - Leave your branch free when you finish (`git checkout --detach`).
- **Keep output small.**
  - `scripts/ci.sh` prints only a summary and failures; full logs are in `build/logs/`. `grep` them rather than printing them.
  - Never paste more than 40 lines of any log into your answer.
- **Your final answer is data for the orchestrator.** Keep it to the requested structure; no prose for humans.

## Apps and windows

Anything that launches the app or puts a window on screen (`tools/capture/*`, `tools/bench/run.sh`, `FILETRAIL_GUI_TESTS=1` tests, a built app) must run under the shared lock, so only one such run happens at a time on this Mac:
`lockf -k ~/Library/Caches/filetrail-port/gui.lock <command>`

No window runs during development (user, 2026-10-14). The original runs its UI tests only in CI; the port runs its window checks only at checkpoints (phase ends, before the user's hands-on checks) through `tools/orchestrator/workflows/ui-check.js`.
- Builders, fixers, gate runners, reviewers and integrators never run the full `FTAppKitTests` GUI suite, `tools/capture/run.sh` (any tier, scenario set or `--acceptance`) or the bench, whatever a gate list or brief says. Your gate is the windowless commands.
- If you changed window code, you may run the one or two GUI tests you touched (`swift test --filter FTAppKitTests.<Suite>/<test>`), once, under the lock. New scenarios and GUI tests you add are first run at the next checkpoint.
- A fixer working on a checkpoint failure reruns only that one test or scenario, under the lock.
- Take the lock once per run, never around a loop. Don't rerun anything to see whether a flake goes away.

## Test runs while you work

While you iterate, run only the tests of the area you change: `scripts/ci.sh --scope <TestTarget or Suite>` (a swift test filter). Run the full windowless gate once, at the end, before your final commit. Gate runners and integrators run the full gate once.

## Messages during your run

A message relayed from the user or the orchestrator while you work may be about other work. If it is not about your brief, note it in your result's summary and carry on with your brief; never drop your brief for it.

## Porting rules (from wave 1 on)

- **Tests.** Port the original's tests listed in your brief.
  - Find them in `docs/port/parity/tests.tsv` by file. Each Swift test cites the ids it ports in a comment on the line before `@Test`: `// T-1a2b3c4d T-5e6f7a8b`.
  - Logic (L) and filesystem (FS) cases are ported one for one.
  - E cases (zod, IPC, preload, protocol) are marked `// N/A T-… <reason>` in the test file that replaces their intent.
  - UI cases are covered by feature row: cite `F-…` ids on the controller test or scenario that proves the feature, and mark a UI case already proven elsewhere `// covered-by-feature F-…`.
  - `bun tools/parity-matrix/sync.ts --no-write` (once it exists) checks your citations. Don't commit changes to `docs/port/parity/`: the integrator runs the sync once after merging a batch, so parallel work packages never conflict there.
- **Goldens.** Where the brief names golden suites, add generators under `tools/parity/golden/` (see `tools/parity/README.md`). Record the reference's outputs and test the Swift port against them. Fuzz with a fixed seed, and include the edge cases the inventories list.
- **Same behavior first.** Reproduce the original's behavior, including its known gaps: packages detected by the extension list in listings, hidden meaning a leading dot, symlink-only "Alias" labels, single-item Quick Look. Only the bugs listed as approved in `docs/port/DEVIATIONS.md` are fixed. If you find another difference you think should not be copied, list it under deviations in your result and copy the behavior anyway.
- **System APIs.** Use the same macOS APIs the original uses (`docs/port/inventory/native-and-system.md`, "Quick API mapping table"), called directly from Swift, or from `CFileTrail` where C is clearer.
