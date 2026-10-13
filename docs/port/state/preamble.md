# File Trail native port: context for every agent

You are part of a team porting File Trail, a macOS file browser, from Electron/TypeScript to native Swift and AppKit. The behavior, flow and design must match the original. The plan is `docs/port/PLAN.md`. Read only the sections your brief cites; do not read whole inventories or the whole plan.

## Places

| What | Where |
|---|---|
| This repo | Your current directory: a git worktree of `/Users/tcmudemirhan/src/swiftproj/filetrail` |
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
  - Never `git stash`, never push, never commit to `port/integration` or `main` (only the integrator merges).
  - Leave your branch free when you finish (`git checkout --detach`).
- **Keep output small.**
  - `scripts/ci.sh` prints only a summary and failures; full logs are in `build/logs/`. `grep` them rather than printing them.
  - Never paste more than 40 lines of any log into your answer.
- **Your final answer is data for the orchestrator.** Keep it to the requested structure; no prose for humans.
