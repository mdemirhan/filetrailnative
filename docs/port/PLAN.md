# File Trail: native Swift port plan

Status: draft, 2026-10-13. Reference app: `~/src/tsproj/filetrail` at commit `e4d0872` (pinned; see §5.1).

## 1. Goal and decisions

Rebuild the whole Electron/TypeScript app as a native macOS app in Swift and AppKit. Functionality, flow and design stay the same as the original. File-operation behavior matches exactly, including conflict detection, the Replace safety protocol, crash recovery, Undo and every edge case its tests cover. Performance and footprint are first-class requirements.

Decisions made (2026-10-13):

| Topic | Decision |
|---|---|
| Tabs | **Native macOS window tabs** (one `NSWindow` per tab, system tab bar). The original's in-window tab strip is not recreated; its behaviors are mapped in §3.4 and differences go in `DEVIATIONS.md`. |
| Look | **Native controls, matched metrics.** AppKit controls everywhere. Layout, sizes, row heights, spacing, fonts, colors and icons match the original. Screenshots are diffed against the Electron app with a tolerance; native rendering differences are allowed. |
| Search | **Keep bundling `fd` 10.5.0** (2.9 MB arm64). Same arguments, streaming and limits as today. |
| Orchestration | **One Workflow per phase**, with this session as orchestrator. Gates between phases, and a final loop that runs until a parity sweep finds nothing new. |

Defaults chosen in this plan (change any of them by saying so):

- **Exact parity first.** Gaps in the original (packages detected by an extension list, hidden = dot-prefix only, Finder aliases not resolved, single-item Quick Look, no promised-file drops, no hard-link dedup in folder sizes) are reproduced as they are. Each goes on a post-parity backlog. Clear bugs (for example `nativeReadDragChangeCount` not being exported) are not reproduced; they are logged in `DEVIATIONS.md`.
- **AppKit only, no SwiftUI.** This gives the most control over metrics, a smaller memory footprint, and no SwiftUI startup cost.
- **Zero third-party Swift dependencies.** System frameworks only, plus the bundled `fd`.
- **Bundle id.** `com.filetrail.native` during development, so both apps run side by side for comparison. At release cutover it becomes `com.filetrail.desktop`, with a one-time import of the Electron app's `app-state.json` and `visited-folders.json` (§7, phase 8).
- **Git.**
  - Work happens on the integration branch `port/integration`.
  - Each work package gets its own branch and worktree.
  - The orchestrator merges `port/integration` into local `main` at each wave gate.
  - Nothing is pushed: the repo has no remote.
  - Commits carry no `Co-Authored-By` trailer, per the global CLAUDE.md.

## 2. What is being ported

The inventories in `docs/port/inventory/` are the specification. Every work package cites sections of them:

| Inventory | Covers |
|---|---|
| `file-operations.md` | The copy engine, conflicts, Replace staging, journal, Undo, batch rename, native calls per step, and a test checklist (A–N) |
| `native-and-system.md` | Each C/ObjC helper and its Swift API, listing, folder size, search, watching, volumes and eject, disk images, Open With, icons, thumbnails, Quick Look, drag, Trash, logging |
| `ui.md` | Window layout, toolbar, views, the selection model, every dialog, sheet and menu, Settings and all 82 commands, design tokens and colors, accent derivation, formatting, Help, About, navigation |
| `app-shell-and-tests.md` | Menu tree and enable rules, persistence and every preference key, window lifecycle, the 80 IPC channels (which become the Swift service API), logging, build and release, and the test-suite inventory |

Size of the original:

| Part | Production lines | Test lines |
|---|---|---|
| Renderer (React) | 60k (8.2k CSS) | 48k |
| Main process | 14k | 22.5k |
| Shared and contracts | 5.8k | 3.5k |
| Core (copy engine, listing, search) | 8.8k | 19k |
| Native addon (C/ObjC) | 5.2k | 1.6k |

There are 3,366 Vitest cases and 31 Playwright e2e cases. By class:

| Class | Cases | Ports as |
|---|---|---|
| Pure logic | ~1,700 | XCTest unit tests, including about 550 renderer view-model `lib/*` cases |
| Real filesystem | ~700 | XCTest with temp dirs and `hdiutil` disk images |
| UI behavior | ~1,150 | Controller tests and in-app automation flows |
| Electron or Zod transport | ~50 | Replaced by Codable and service-boundary tests |

The spike already in this repo is the starting point for the shell, the List and Icon views and the benchmark/snapshot mode. Its lessons stay binding:

- No per-file LaunchServices calls (`localizedNameKey` / `localizedTypeDescriptionKey`).
- Cells are laid out with frames, not Auto Layout.
- Free space is read after the folder is drawn.

## 3. Target architecture

### 3.1 Project layout

Everything is one Swift package; there is no Xcode project. `scripts/build-app.sh` wraps the executable in an app bundle, as the spike does, and also handles the Info.plist, entitlements, icon, the bundled `fd` and code signing. UI flows and screenshots come from a debug-only in-app automation mode instead of XCUITest. That mode drives the app's own commands and events and draws its own windows into PNGs, so it needs no Accessibility or Screen Recording permission and has no hand-maintained project file. (Changed on 2026-10-13, while starting P0.)

```text
Package.swift                    FileTrailKit: libraries + unit/FS tests
Sources/
  CFileTrail/                    C: getattrlistbulk folder-size walker (ported from native_foldersize.c),
                                 copyfile status-callback shim, IOKit disk-parent walk
  FTFoundation/                  pure logic: paths, item names, Keep Both naming, trash/system-path rules,
                                 formatting (relative dates, sizes, permissions), preferences + sanitizers,
                                 shortcuts table + policy, visited folders, batch-rename proposals,
                                 toolbar items, command availability, menu state, design tokens + accent math
  FTFileSystem/                  actors/services: listing, metadata, tree, path suggestions, FSEvents watch,
                                 volumes, eject (DiskArbitration), disk images (hdiutil), icons, thumbnails,
                                 Open With, fd search, folder sizes (+ cache + adjust), trash state,
                                 Empty Trash, app-state store, logger
  FTOperations/                  write engine: copy analysis, policy, execution, fingerprints, Replace staging,
                                 crash journal + recovery, write coordinator (one slot), trash/delete/new
                                 folder/rename, undo log/plan/history/execution, batch-rename execution
  FTAppKit/                      AppKit UI: windows and tabs, menus, toolbar, sidebar, views, dialogs,
                                 Settings, Help, About, Acknowledgements
Tests/  FTFoundationTests  FTFileSystemTests  FTOperationsTests  FTAppKitTests (controller tests, fakes)
  FileTrail/                    executable: main.swift only; debug builds add the automation mode
                                 (--automation <script>: run scenario steps, dump view geometry, snapshot)
Resources/                       Info.plist, entitlements, AppIcon.icns; fd added by build-app.sh
tools/  parity/  capture/  pixeldiff/  fixtures/   (see §5)
```

There is no IPC. The 80 channels and 14 push events become async methods on actors and `AsyncStream`s. The window-scoped behaviors go to a per-window `WindowSession` object:

- the window's session preferences;
- its menu state;
- its folder watch;
- the handover of a running operation when its window closes.

### 3.2 Concurrency and performance design

- **Swift 6 language mode** with strict concurrency, built with zero warnings. UI is `@MainActor`; everything that touches the disk runs on actors off the main thread.
- **Listing.**
  - Use `getattrlistbulk`, reading name, type, dates, size and flags in one pass. This replaces Node's `readdir` plus lazy `stat` batches; metadata comes with the listing, so the lazy batch protocol is dropped.
  - Kind strings come from `UTType` and are cached per type.
  - Finder-order sort uses `localizedStandardCompare` and runs off the main thread.
  - Keep the 3 s response cache semantics only where behavior depends on them (repeated tree expands); otherwise cache by FSEvents generation.
- **Folder size.** The C walker is ported verbatim: 4 threads, same device only, mount points skipped, utility QoS for automatic jobs. Results stream through an `AsyncStream` instead of 200 ms polling. `FolderSizeCache` and its adjust logic port as plain Swift.
- **Icons and thumbnails.**
  - Icons: `NSWorkspace.icon(forFile:)` held in an `NSCache` keyed as in the original (`ext:`, `kind:`, `path:`).
  - Thumbnails: `QLThumbnailGenerator`, at most 4 at a time, cancelled when a cell is reused.
- **Views.**
  - `NSTableView` and `NSCollectionView` with fixed row and item metrics and frame-laid cells.
  - No Auto Layout inside cells.
  - No synchronous disk access while drawing.
- **Search.** `fd` runs via `Process` + `Pipe`. NUL-separated output is parsed into an `AsyncStream` and pushed to the view in batches, replacing the original's 120 ms polling. Kept from the original: the 20,000-result cap, SIGTERM on cancel, and every `fd` killed at quit.

### 3.3 Native API mapping

`native-and-system.md`, "Quick API mapping table", is binding. In short:

- **System calls, called from Swift via Darwin:** `copyfile` (`ALL|CLONE|NOFOLLOW_SRC|EXCL|DATA_SPARSE`, with a status callback for stop and progress), `renamex_np(RENAME_EXCL)` with the same fallback, `lchflags`, `acl_*_link_np`, `pathconf`, `getattrlist`, `getmntinfo(MNT_NOWAIT)`.
- **Same frameworks:** DiskArbitration for eject, ImageIO for date taken, `FileManager.trashItem(at:resultingItemURL:)`, and the `NSWorkspace` Open With APIs.
- **Kept as processes:** `hdiutil`, with plists parsed by `PropertyListSerialization`; and Empty Trash through Finder, via `NSAppleScript` (keeps the TCC prompt and the entitlement).
- **Replaced by native equivalents:**

| Original | Swift/AppKit |
|---|---|
| `fs.watch` | `FSEventStream` (file events, watch root), keeping the 250/1000 ms debounce and the mtime check on window focus |
| `BrowserWindow.previewFile` | `QLPreviewPanel` (single item, for parity) |
| Synthesized drag | Native `NSDraggingSource` / `NSDraggingDestination` with the same operation rules and drag images |

### 3.4 Native window tabs, mapped to the original's tab behavior

| Original behavior | Native plan |
|---|---|
| Per-tab state (folder, history, tree root, view, sort, search) | Per `NSWindow` (one window per tab) |
| Per-window state (tree/Info panel/Info Row shown, pane widths, column widths, Reopen Closed Tab list) | Shared by every window in an `NSWindowTabGroup` through a `TabGroupSession`; changing it in one tab updates the others |
| Tab label `“query” in Folder`, `Name — Parent` disambiguation, "Macintosh HD" | `window.tab.title` (window title stays the folder name for the Window menu) |
| Max 100 tabs; New Tab / Duplicate / Reopen / Open in New Tab refuse with a notice past it | Enforced in `newWindowForTab` and our own tab-opening paths |
| Reopen Closed Tab (⇧⌘T) | Our own closed-tab stack per tab group |
| Move Tab to New Window, Merge All Windows, with "busy windows stay" rules | Our own actions replacing the system selectors, so the busy, sheet and 100-tab rules hold |
| Show Previous/Next Tab (⌃Tab, ⇧⌘[ ]) | System selectors, with the keys from the shortcut table |
| Session restore of windows, tabs, front tab and bounds | Same `app-state.json` schema: each stored window becomes a tab group, in order |
| Tab context menu: Duplicate Tab; middle-click close; spring-switch on file drag hover; "+" button tooltip | **Deviations** (the system tab bar owns these). Logged in `DEVIATIONS.md`; Duplicate Tab stays in File menu / shortcuts |

### 3.5 Look: tokens, zoom, accent

- **Tokens.** `FTFoundation/DesignTokens.swift` is generated once from `styles.css` (`ui.md` §5): type scale, radii, spacing, all light and dark colors, and motion. No literal metric appears in UI code; everything reads a token.
- **Zoom, 75–150%.**
  - AppKit has no page zoom, so every token is a function of `zoom` (fonts and metrics).
  - Changing zoom re-lays out every window.
  - This is built in from the first UI commit; retrofitting it later would touch every view.
- **Accent.** Any hex color. The derived colors are computed as in `accent.ts`: selection background with 4.5:1 contrast, soft background, borders, solid buttons. `controlAccentColor` and the system selection drawing are not used. Selection is drawn by a custom `NSTableRowView`/collection item, and turns gray when the window is inactive.
- **Chrome.**
  - `NSVisualEffectView(.sidebar)` for the translucent sidebar.
  - `NSToolbar` with custom item views for the capsule groups, the segmented view switch and the search capsule.
  - Toolbar customization uses the system sheet, with the original's palette order and required items.
- **Icons.** Toolbar, menu and Info-panel icons are SF Symbols where one matches the original's stroke icons closely, and redrawn as template PDFs otherwise. The geometry check in §5.4 compares each icon's bounding box.

## 4. Budgets (enforced at every gate)

| Metric | Electron today | Budget |
|---|---|---|
| App bundle | 320 MB | ≤ 12 MB (fd 2.9 MB included) |
| Idle memory, one window in Home | ~134 MB in 4 processes | ≤ 60 MB, 1 process |
| Cold launch to first folder drawn | — | ≤ 350 ms |
| Open a 3,000-item folder (List) | 50–80 ms | ≤ 50 ms to drawn |
| Back to a small folder | ~50 ms | ≤ 10 ms |
| Open a 100,000-item folder | — | ≤ 600 ms to first rows, UI never blocks > 50 ms |
| Scrolling 10k rows (List, Icons) | — | no frame over 16 ms on the main thread |
| First search results (`fd`, Home) | — | ≤ 150 ms |
| Copy throughput | `copyfile` | equal, ±5% |

The spike's `--bench` grows into `tools/bench`. It runs fixed scenarios against generated fixture trees, and each phase gate compares results to the previous run (fail on > 10% regression).

## 5. Validation system (built first, in phase 0)

### 5.1 Reference app

- `tools/reference/setup.sh` clones `~/src/tsproj/filetrail` at the pinned commit into `~/Library/Caches/filetrail-port/reference/electron` (outside every checkout), runs `bun install`, builds native-fs, and runs `bun run desktop:build`.
- The user's own checkout is never built in or written to.
- Re-pinning to a newer commit is an explicit orchestrator step that also diffs the inventories.

### 5.2 Parity matrix (`docs/port/parity/`)

- **`tests.tsv`.** Every one of the 3,366 test cases and 31 e2e cases, extracted mechanically. Columns: id, file, title, class (L/FS/UI/E), target Swift test, status (todo / ported / passing / N/A + reason). A TS case counts as covered only when a Swift test cites its id.
- **`features.md`.** Every feature, command, preference, dialog and edge case from the four inventories, as `F-###` rows: spec reference, Swift owner, tests that prove it, UI scenario id, status.
- **`STATUS.md`.** The dashboard the orchestrator rewrites after every workflow: share of each matrix done, open findings, budget table, and deviations.

### 5.3 Differential testing against the TypeScript engine

`tools/parity/` holds a Bun driver that imports the reference app's own `packages/core` and shared modules in Node mode (the native addon is already built). It runs the same input through both implementations:

- **Pure functions, fuzzed with shared seeds.**
  - Keep Both naming and `fitName`.
  - Batch-rename `proposeNames` and `planBatchRename`.
  - Shortcut parsing and resolution, preference sanitizing, visited-folder scoring.
  - Relative-date and size formatting, list filter, icon-label middle truncation.
- **Analysis reports.** A scenario tree is generated on disk, both engines analyze the same paste, and the conflict trees, classes, issues and choices are compared.
- **Execution.** Each engine gets an identical fresh fixture and runs a scenario script (paste with a policy and overrides, runtime-conflict answers, stops at chosen points). The comparison covers:
  - the resulting tree: names, kinds, sizes, content hashes, flags, ACLs;
  - Trash contents;
  - the journal file;
  - the undo log;
  - the ordered event and question stream, normalized.
- **Crash recovery.** A crash is injected at each journal step (a kill hook), then each engine runs its own recovery and the results are compared.

### 5.4 UI validation (native controls, matched metrics)

The checks run in three tiers, so the expensive steps run rarely (see §6.6):

| Tier | When | Variants | Vision review |
|---|---|---|---|
| WP | Inside a UI work package | Only the scenarios that WP touches, light, 100%, Comfortable | None; geometry and pixel diff only |
| Wave gate | End of each UI wave | All scenarios, light and dark, 100% | Only scenarios whose pixel diff is over the threshold |
| Final | P7, once at the start and once at the end | Light and dark, 100%, Comfortable | Over-threshold scenarios, and 1 in 10 of the rest as a spot check |

Zoom levels other than 100% and Compact density are not captured as screenshots. They are covered by unit tests of the token math at every gate: every metric and font at 75%, 125% and 150%, and every Compact metric, checked against the values in `styles.css` and `ui.md` §2.

1. **Scenario catalog** (`tools/capture/scenarios.json`). About 120 named UI states, such as `list-sorted-size-bars`, `cut-items-clipboard-popover`, `review-sheet-folder-conflict`, `batch-rename-numbering`, `settings-shortcuts`, `search-results-scope-bar`, `goto-panel-suggestions`.
   - A deterministic fixture tree (`tools/fixtures`, the "Lighthouse" project from the README screenshots) with fixed mtimes.
   - A frozen clock: Playwright `page.clock` on the Electron side, `FILETRAIL_NOW` on the Swift side.
   - A fixed window size, accent and preferences.
2. **Capture.**
   - Electron: Playwright `_electron` drives the scenarios.
   - Swift: the in-app automation mode runs the same scenario steps and draws the window into a PNG itself.
   - Electron: `page.screenshot`. The native traffic-light area is masked on both sides.
3. **Geometry diff (the main gate).**
   - Electron: a DOM dump of named elements' frames (`getBoundingClientRect` by `data-testid`/role).
   - Swift: a debug view-tree dump of the same names (`accessibilityIdentifier`).
   - Every named element's frame must match within ±1 pt.
   - Font size, weight and color tokens must match exactly.
4. **Visual diff.** `tools/pixeldiff` (Swift, CoreImage) computes a per-region perceptual difference with masks for natively drawn parts (traffic lights, scrollers, text antialiasing) and writes heat maps.
5. **Vision review.** A reviewer agent sees both screenshots side by side, with the heat map, and lists every material difference. It is prompted to find differences and to default to "differs" when unsure. It runs only where the tier table says, and it looks at one scenario's pair of images at a time. At wave gates, you can do this review yourself from the side-by-side contact sheet the harness writes (`tools/capture/out/contact.html`), which costs no tokens.

### 5.5 Behavior validation

- **Ported unit and FS tests.** Every L and FS row in `tests.tsv` gets a Swift test of the same intent. Real-disk tests use sparse `hdiutil` images (FAT32, exFAT, HFS+, APFS case-sensitive), cloned from a cached blank image as the original does. Large-file tests are gated behind `FILETRAIL_LARGE_FILE_TESTS`.
- **Controller tests.** The ~1,150 React behavior tests are covered **by feature row, not one-for-one**. Many of them repeat a flow through a different component, so each `F-###` UI row gets the controller tests that prove it. Window controllers are driven with fake services and the same visible-state assertions. A React test whose behavior is already proven is marked `covered-by:<swift test>` in `tests.tsv` instead of being ported. L and FS tests are still ported one-for-one.
- **In-app automation e2e.** The 31 Playwright flows, plus one flow per major feature row. These include drag inside the app and between windows. Drags to and from Finder are a human checkpoint (§8).
- **Behavior differential.** For each scenario, both apps run the same scripted action sequence (keys, menu commands, clicks by element name). The resulting filesystem state, selection, window title, status text and visible rows are compared.

## 6. Orchestration

### 6.1 Roles

- **Orchestrator (this session).**
  - Owns `PLAN.md`, the parity matrix, `STATUS.md` and `DEVIATIONS.md`.
  - Writes each phase's work-package list, launches one Workflow per phase (or batch), and reads the results.
  - Decides re-runs (Workflow `resumeFromRunId`), merges at wave gates, and escalates to the user only for decisions and human checkpoints.
  - Never edits feature code itself; fixes go through work packages.
- **Sub-agents.** Each runs inside a workflow, in its own git worktree, and is one of five kinds:

| Agent | Does |
|---|---|
| Implementer | Builds one work package and its ported tests |
| Verifiers | One per lens (below) |
| Fixer | Applies confirmed findings |
| Integrator | Merges branches one at a time and runs the full CI |
| Critic | Looks for whatever is still missing |

### 6.2 Work-package (WP) format

Each WP is passed to the workflow in `args`:

```json
{ "id": "OPS-04", "title": "Replace staging, journal and recovery",
  "spec": ["file-operations.md §3.1-3.5", "FILE_OPERATION_RISKS.md"],
  "reference": ["packages/core/src/fs/copyPasteExecution.ts:1443-2400", "apps/desktop/src/main/bootstrap/writeJournal.ts"],
  "owns": ["Sources/FTOperations/Replace/", "Tests/FTOperationsTests/Replace/"],
  "tests": ["tests.tsv rows: core/copyPasteConflictSafety.realfs.*, copyPasteRecovery.*, writeJournal.*"],
  "features": ["F-210..F-236"], "differential": ["exec:replace-*", "crash:replace-*"],
  "depends": ["OPS-01", "OPS-03"], "budgets": ["copy throughput"],
  "risk": "high", "model": "opus" }
```

`risk` sets how much checking the WP gets, and `model` sets who builds it (§6.6). The spec and reference ranges are exact `file:line` spans, so the implementer reads only those and doesn't explore.

Rules every implementer follows:

- Touch only the paths in `owns`. Shared files (`Package.swift`, `scripts/ci.sh`, `DesignTokens.swift`, the command table) are changed only by the integrator, from requests in the WP's report.
- Cite the TS source and inventory section in a short header comment of each ported file.
- Port the listed tests before calling the WP done.
- Accepted risks from `FILE_OPERATION_RISKS.md` are not "fixed". A finding below its bar goes to the accepted list.

### 6.3 The per-phase workflow

Each phase workflow is a pipeline over work packages, so a finished WP moves on to verification while others are still building:

```text
for each WP (pipeline, worktree isolation):
  implement      → code + ported tests on branch port/<wp-id>; the implementer itself runs
                   scripts/ci.sh --scope <wp> until green (gates are scripts, not agents)
  gate           → plain script result: build + tests + differential (+ geometry/pixel for UI WPs)
  verify (only if the gate passed; lenses by risk tier, each prompted to refute "this WP matches
          the original" and to back every finding with a failing test or a diff):
      low    — no reviewer: the gate (tests, differential, geometry) is the check, and the
               phase critic reads these WPs first
      medium — parity (Sonnet) + one domain lens (Opus): performance for listing/views,
               visual for UI
      high   — parity + safety + one domain lens (all Opus); write engine and the copy flow UI
  fix            → apply findings that come with a failing test or diff; re-gate
  (fix→gate→verify at most 2 times; after that, report as blocked with the open findings)
barrier → integrator (Sonnet): merge passing branches into port/integration one at a time,
          full CI, bench, fix integration breaks; escalate to Opus only on a break it can't fix
critic  → once per phase (Sonnet): "what in this phase's feature rows is still unproven?"
```

A finding must come with a failing test or a concrete diff to count. That replaces the 2-of-3 skeptic votes: one reviewer whose claim can be checked costs less than three voting.

The workflow returns a structured report for each WP: status, tests ported and passing, feature rows closed, findings, deviations proposed, and budget numbers. The orchestrator merges these into `STATUS.md`.

### 6.4 Scale and batching

- This machine allows 14 concurrent agents per workflow (16 CPUs).
- This session's workflow-size guideline is "medium: under 10 agents per workflow". Under it, each phase runs as several workflow batches of about 3 WPs each, which takes more orchestrator turns.
- To run whole phases per workflow, raise "Dynamic workflow size" in Claude Code's config, from an interactive `claude` terminal.

### 6.5 Loop until done

After phase 7 starts, the orchestrator repeats the following until one round finds nothing new, every matrix row is passing or N/A with a reason, every scenario passes geometry (and vision review where its tier asks for it), and every budget holds:

1. Run the full parity sweep. This is scripts only and costs no agent tokens: tests, differential, scenarios, e2e, bench. Its failures are the first work list.
2. Run critic agents (Sonnet, 3 per round) with different angles. The first round uses all five; later rounds keep only the angles that found something last time:
   - by inventory section;
   - by menu command and preference;
   - by the edge-case checklist A–N;
   - by "a Finder user's first hour";
   - by the deviations log.
3. Dedupe findings against everything already seen (plain code, not an agent).
4. Keep only findings that come with a failing test or a diff.
5. Turn confirmed gaps into work packages and run them.

The loop stops at a set ceiling of 2 rounds. If it hasn't run dry by then, what's left goes to you as a list to decide on, rather than more rounds.

### 6.6 Cost controls

These apply throughout. They are listed roughly by how much they save.

1. **Scripts gate the work, not agents.** Builds, tests, differential runs, geometry and pixel diffs, bench and parity-matrix bookkeeping are scripts whose results are plain data. Agents read the results; they never re-derive them.
2. **Quiet build output.** `scripts/ci.sh` prints a one-line summary plus only the failing tests, errors and warnings, capped at 200 lines. Full logs go to `build/logs/` for an agent to `grep` when it needs more. Raw `swift build` and `swift test` output can run to tens of thousands of lines per run, and agents run CI many times.
3. **The model matches the work.**

   | Model | Used for | Effort |
   |---|---|---|
   | Opus | Write engine (P3), copy-flow UI (P6-02), safety and visual lenses, and any work package escalated after 2 failed fix loops | Default |
   | Sonnet | All other implementers: pure logic, file-system services, views, dialogs, Settings, test porting. Also the parity lens, the integrator and the critics | Medium |
   | Haiku | Mechanical steps: summarizing a failing log, renaming across files, filling matrix rows from a script's output | Low |

4. **Checking scales with risk.** Low-risk WPs get no reviewer and rely on their gate and the phase critic; medium get 2, high 3 (§6.3). Each WP has at most 2 fix loops.
5. **Exact specs, no exploration.** Each WP lists the inventory sections and TS `file:line` ranges it needs, and agents share one fixed preamble. The inventories were paid for once and are reused everywhere.
6. **Fewer, larger work packages.** Small related WPs are merged, so each agent's startup reading is spread over more output (P1: 9 → 4 WPs; P2: 10 → 7; P5: 14 → 9; P6: 6 → 4).
7. **UI tests by feature, not one-for-one** (§5.5). This cuts the UI test porting work by about half; the L and FS tests stay one-for-one.
8. **Vision review only where pixels disagree** (§5.4 tiers), or done by you from the contact sheet.
9. **A lean orchestrator.** Workflows return short structured reports, details go to `STATUS.md`, and this session compacts between phases. It never reads full agent transcripts.
10. **A token meter at every gate.** Before each wave, the orchestrator reads the plan's weekly limit. It doesn't start a wave that would push past it, and pauses until the reset instead. Extra usage stays off unless you turn it on.

### 6.7 Checkpoints: run, pause, stop and resume at any time

The orchestrator never depends on what is in its conversation. Everything it needs to continue is on disk and in git, so a new session, a compacted one or one started days later continues the same way.

**What is saved:**

| Where | What |
|---|---|
| `docs/port/ORCHESTRATOR.md` | The orchestrator's operating instructions: the loop, the gates, the rules in §6. Any session that loads it can act as orchestrator. |
| `docs/port/state/orchestrator.json` | The authoritative state. It has the reference commit, current wave and phase, and each WP's stage, branch, head commit, attempt count, last gate result, open findings and token use. It also holds the batches with their workflow run ids, the last usage-meter reading, a pause request, and a one-line "next action". |
| `docs/port/state/journal.jsonl` | An append-only log of every state change, so a crash in the middle of a write can be replayed. |
| `port/<wp-id>` branches | The work itself. Implementers and fixers commit as they go (`wip(<wp>): …`), and each finished stage is a commit with a `Port-Stage: implemented / gated / reviewed / fixed-N` trailer. |
| `tools/orchestrator/` | The workflow scripts, kept in the repo and run by path, so a resumed session runs the same script. |

The orchestrator commits the state files to `port/integration` after every change ("port: checkpoint …").

**Stages are idempotent.** A WP moves through todo → implementing → implemented → gated → reviewed → fixing (1–2) → ready → merged, or ends as blocked. Before acting, each stage checks the branch for its own `Port-Stage` commit; if it's there, the stage is skipped. Re-running a batch after a stop therefore redoes only the stage that was interrupted.

**The controls:**

| You | What happens |
|---|---|
| `/port` | Start or resume. The orchestrator reconciles state with git (below) and continues from "next action". |
| `/port status` | Prints the dashboard from the state files. Nothing runs and no agents start. |
| `/port pause`, or just saying "pause" | Graceful. The batch already running finishes (at most about 10 agents), its results are merged into state and checkpointed, and nothing new starts. |
| Stopping the session or workflow (the stop button, Esc, or closing the app) | Immediate. Only the in-flight agents' uncommitted work is lost; their WPs redo just the interrupted stage on resume. |
| Weekly limit near | The orchestrator pauses on its own and records the reset time. If you allow it, a scheduled task starts `/port` again after the reset. |

**Reconcile on resume.** Every `/port` begins with a cheap, scripted check (`tools/orchestrator/reconcile.sh`):

1. List the `port/*` branches and any leftover worktrees, and compare them with the state.
2. Commit any uncommitted changes in a leftover worktree as `wip(<wp>): recovered`; never discard them. Then remove the worktree.
3. Mark WPs that were mid-stage as interrupted; they continue from their last `Port-Stage` commit.
4. Check that the reference build in `~/Library/Caches/filetrail-port/reference/electron` is still at the pinned commit.
5. Read the usage meter.

Within the same session, a stopped workflow can also continue with Workflow `resumeFromRunId`, which returns the agents that already finished from cache at no cost. Across sessions, the state files and branches do the same job.

What is **not** cut, because a mistake there can lose files:
- the write engine's differential and crash-injection tests;
- its safety lens;
- the one-for-one port of its L and FS tests;
- the real-disk checks.

## 7. Phases and work packages

The phases run in waves; phases in the same wave run in parallel:

| Wave | Phases |
|---|---|
| 0 | P0 |
| 1 | P1, P2, P4-01, P4-02 |
| 2 | P3, P4-03, P5 |
| 3 | P6 |
| 4 | P7 (loop) |
| 5 | P8 |

### P0. Foundations and harness

All P0 work is Sonnet except P0-04 and P0-05, which set up the checks everything else relies on.

| WP | Risk · model | Delivers |
|---|---|---|
| P0-00 | orchestrator itself, no agents | Checkpoint scaffolding (§6.7): `ORCHESTRATOR.md`, the state schema with the initial `orchestrator.json`, `journal.jsonl`, `reconcile.sh`, the `/port` skill (`.claude/skills/port/SKILL.md`, with `status` and `pause`), and the workflow scripts in `tools/orchestrator/`. Tested by stopping and resuming a dummy batch. |
| P0-01 | low · Sonnet | Package restructure (§3.1); quiet `scripts/ci.sh` (§6.6) with build, `swift test`, `swift-format lint` and a zero-warning check; `build-app.sh` updated |
| P0-02 | low · Sonnet | Reference setup (§5.1); fixture generator (Lighthouse tree, large trees for bench, disk-image cache) |
| P0-03 | low · Sonnet | Parity matrix: a **script** extracts `tests.tsv` from all Vitest/Playwright files; an agent turns the inventories into `features.md` |
| P0-04 | medium · Opus | Differential harness: Bun driver, Swift CLI runner and comparator, with one end-to-end example |
| P0-05 | medium · Opus | Capture harness: Playwright driver and the in-app automation mode, geometry dumpers, `pixeldiff`, contact sheet, first 10 scenarios |
| P0-06 | low · Sonnet | `DesignTokens.swift` + accent math (differential tests against `accent.ts`), zoom-scaled metrics |
| P0-07 | low · Sonnet | Bench harness grown from the spike's `--bench`, with a budget file (§4) and a regression check |

P0 runs as two batches. **P0-A:** P0-01, P0-02, P0-03, with no dependencies between them. **P0-B:** P0-04 to P0-07, which build on P0-01's package layout and P0-02's reference build.

**Gate:** CI green on the restructured spike; one scenario captured from both apps and diffed; one differential case passing; matrix files generated; token use of P0 measured to recalibrate §10.

### P1. Pure logic (FTFoundation)

| WP | Risk · model | Delivers |
|---|---|---|
| P1-01 | medium · Sonnet | Paths, item names, package names, Trash/system-path rules, write effects, `withoutNestedPaths`; Keep Both and duplicate naming, `fitName` (grapheme-aware, 255 bytes), New Folder/undo numbering |
| P1-02 | low · Sonnet | Formatting (relative dates, sizes, permissions, status summary, tooltips, icon-label truncation, list filter); visited-folder scoring and Go To ranking |
| P1-03 | low · Sonnet | Preferences model and sanitizers, window-session keys, migrations; toolbar items model; shortcut table (82 commands), parsing, resolution, refusals; command availability and menu state |
| P1-04 | medium · Sonnet | Batch-rename settings, `proposeNames`, plan and conflict policy, presets |

**Gate:** all L rows for these areas passing; fuzz differential clean.

### P2. File system services (FTFileSystem, CFileTrail)

| WP | Risk · model | Delivers |
|---|---|---|
| P2-01 | medium · Sonnet | Listing (getattrlistbulk), snapshot, sort, tree children, path suggestions, resolve; FSEvents folder watch with debounce and missed-change check; bench |
| P2-02 | medium · Sonnet | Folder-size walker (C, ported verbatim), jobs and queue rules, cache, adjust after writes, Trash counting |
| P2-03 | medium · Sonnet | Volumes (getmntinfo + IOKit), mount notifications, eject (DiskArbitration, whole disk, force, busy); disk images (hdiutil, hand-off) and the open-file entry point |
| P2-04 | low · Sonnet | Icons and thumbnails (caches, keys, 4-wide queue, iconMode) |
| P2-05 | low · Sonnet | Open With (lists, default app, intersect, pinned apps, Always Open With, cache), Open in Terminal/Editor; Trash state, Empty Trash via Finder, Full Disk Access link, `diskHasTrash`, disk ids |
| P2-06 | low · Sonnet | `fd` search service (arguments, streaming, cap, cancel, kill at quit) and bundling |
| P2-07 | medium · Sonnet | App-state store (same JSON schema, atomic writes, two save tiers), visited-folders file, logger with rotation |

**Gate:** native-fs's 76 cases and these areas' FS rows passing; listing budgets met.

### P3. Write engine (FTOperations)

This is the highest-risk phase. Every WP is **high · Opus**, the WPs run in dependency order, and none of the cost cuts that weaken checking apply here (§6.6).

| WP | Delivers |
|---|---|
| P3-01 | Fingerprints, identity, `copyfile`/`renamex_np`/flags/ACL wrappers, stoppable copy, error mapping |
| P3-02 | Analysis report (conflict tree, classes, issues, warnings) and policy resolution |
| P3-03 | Execution: create, merge, keep both, skip, per-file cut, same-device rename fast path, cross-device move verification, runtime conflicts and questions |
| P3-04 | Replace staging, hidden names, crash journal, startup recovery and retries |
| P3-05 | Write coordinator: one slot, progress throttling, window ownership and handover, quit and close while busy |
| P3-06 | Trash, Delete Immediately, New Folder, Rename, system-location guards |
| P3-07 | Undo log, history, plan and execution |
| P3-08 | Batch-rename inspect and execution (swaps, chains, blockers, case-only changes) |

**Gate:**
- every A–N checklist item and all core/bootstrap FS rows passing;
- the execution and crash differential clean on HFS+, APFS, APFS case-sensitive, FAT32 and exFAT images;
- the safety lens with no open findings above the risk bar.

### P4. App shell (FTAppKit)

| WP | Wave | Risk · model | Delivers |
|---|---|---|---|
| P4-01 | 1 | medium · Sonnet | App delegate, launch arguments, open-file, Dock menu, quit while busy, logging wiring; command registry and menus built from the shortcut table, dynamic Undo labels, window targeting rules |
| P4-02 | 1 | medium · Opus | Window and tab model (§3.4): session restore, New Window / Move Tab / Merge rules, 100-tab limit, Reopen Closed Tab, `lastClosedWindow` |
| P4-03 | 2 | low · Sonnet | Theme (auto/light/dark), accent, global zoom, inactive-window state; About, Acknowledgements (licenses generated at build time), Help window and its content |

### P5. Explorer UI

| WP | Risk · model | Delivers |
|---|---|---|
| P5-01 | medium · Sonnet | Window layout grid, split panes with the original's limits and keyboard resizing, Info panel slide; toolbar (capsules, title, view switch, sort menu, search capsule, history buttons, clipboard button, overflow, customization) |
| P5-02 | medium · Sonnet | Sidebar: Favorites (icons, reorder, add/remove), Locations (eject button), folder tree (`NSOutlineView`, tree root, expand rules) |
| P5-03 | medium · Sonnet | List view: columns, sort rules, resize and fit, size bars, striped inset rows, narrow-pane rules |
| P5-04 | medium · Sonnet | Icon view (grid math, labels, thumbnails, selection pill, clipboard badges); Compact List (column-major, horizontal scroll) |
| P5-05 | medium · Sonnet | Selection model, keyboard navigation, type-to-filter pill, inline rename, Return/F2 rules; navigation history, Go menu places, startup navigation, folder visit tracking |
| P5-06 | low · Sonnet | Path bar and status bar, Info Row, Info panel (Get Info) |
| P5-07 | medium · Sonnet | Search UI: scope bar, options menu, results columns, filter, per-tab search, background tabs |
| P5-08 | medium · Opus | Drag and drop (in, out, between windows, move vs copy, drag images); clipboard marks, dimming, flash, Show/Clear Clipboard |
| P5-09 | low · Sonnet | Context menus (hide, not dim), Open With menu, Quick Look; notifications (toasts) and progress card |

### P6. Dialogs and Settings

| WP | Risk · model | Delivers |
|---|---|---|
| P6-01 | low · Sonnet | Go To / Move To panel with suggestions, ranking, Tab completion; alerts (generic, eject, undo question, text prompt, recovery notices) |
| P6-02 | high · Opus | Copy and paste flow: review sheet, runtime conflict dialog, result dialog |
| P6-03 | medium · Sonnet | Batch Rename sheet with live preview and presets |
| P6-04 | low · Sonnet | Settings window (all five tabs and every control), shortcut recorder and conflict warnings |

### P7. Integration and parity loop (§6.5)

The full sweep runs the "Final" tier of §5.4 once at the start and once at the end, and the "Wave gate" tier in between. Gaps become WPs. The loop runs until one round finds nothing new, with a ceiling of 2 rounds.

### P8. Release engineering

All P8 work is low · Sonnet.

| WP | Delivers |
|---|---|
| P8-01 | Signing and notarization script (Developer ID, hardened runtime, apple-events entitlement, `fd` signed inside out), DMG and ZIP, versions from git tags |
| P8-02 | Bundle id cutover and one-time import from the Electron app's state files; README, Help and screenshots refreshed from the native app; release script |

## 8. Human checkpoints (what only you can do)

| When | What |
|---|---|
| During P0 | Nothing to grant. The in-app automation mode needs no Accessibility or Screen Recording permission. macOS may ask once for access to Desktop, Documents or Downloads when the app opens folders there. |
| Before P3 gate | Real-disk checks the harness can't fake: an exFAT USB stick, an SMB share, unplugging during a cross-disk move, a full disk. I'll give a script and checklist. |
| Before P5 gate | Drag between File Trail and Finder, Mail and Photos, both ways (scripted drags can't cross apps reliably). |
| Each wave gate | Approve the deviations log entries added in that wave. |
| P8 | Signing certificate and the `notarytool` keychain profile. |

## 9. Risks

| Risk | Mitigation |
|---|---|
| Copy engine (3k lines of TS, safety-critical) reimplemented with a subtle difference | Differential execution and crash-injection testing on 5 file systems; mandatory safety lens; the original's 700 FS tests ported; human real-disk pass |
| Whole-UI zoom has no AppKit equivalent | Tokens are functions of zoom from the first UI commit; 75–150% is checked by unit tests of the token math at every gate (no zoomed screenshots) |
| Native tabs can't do some original tab behaviors | Mapped in §3.4; remaining differences logged and approved at a gate |
| "Pixel perfect" vs native rendering | Geometry is the hard gate (±1 pt); pixels are a soft gate with masks; vision review covers the rest |
| Workflows produce plausible but unverified work | Every WP is gated on executable checks (tests, differential, geometry); a reviewer's finding counts only with a failing test or a diff |
| Parallel WPs collide | Strict `owns` paths, shared files changed only by the integrator, merges serialized |
| The original keeps changing | Reference pinned at `e4d0872`; re-pinning is a deliberate step that diffs the inventories |
| Flaky UI automation (TCC prompts, focus) | Scenario driver runs in a dedicated user session; `--snapshot` fallback; retries only on known infrastructure errors |

## 10. Cost

With the controls in §6.6, there are 43 work packages: 16 low-risk, 18 medium and 9 high. That works out to roughly **185–200 agent runs**, about 40% of them on Opus:

| Part | Agent runs | Mostly |
|---|---|---|
| WPs: build, review, fix (low ≈ 1.5, medium ≈ 3.5, high ≈ 5 runs each) | ~135 | Sonnet; Opus for P3, P6-02 and the safety/visual lenses |
| Integrators (one per batch) | ~15 | Sonnet |
| Phase critics | ~8 | Sonnet |
| P7 loop (≤ 2 rounds) | ~25–40 | Sonnet critics, gap WPs by risk |

That comes to an estimated **45–80M tokens**, down from 150–300M. Measured against this account's weekly limit (about 40M+ tokens per week, from the usage meters on 2026-10-13), that is roughly 1–2 weeks of full weekly allowance. Sonnet's share may count for less against the limit than Opus's, so it could well be less.

These are estimates. P0 is measured precisely and the remaining phases are re-estimated from it before wave 1 starts.

Cuts adopted on 2026-10-13, which trade some assurance for cost:
- P7 ceiling of 2 rounds instead of 4 (about 10–20M); the remaining findings come to you as a list.
- Low-risk WPs with no reviewer, relying on their gate and the phase critic (about 5–8M).
- No 125% zoom or Compact density screenshots; unit tests of the token math instead (about 3–5M).

One further lever remains: **vision review done only by you,** from the contact sheets, at the wave gates (about 5–10M).
