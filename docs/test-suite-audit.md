# Test suite audit, 2026-11-13

Written as instructions for the model that does the work. Each work package below stands on its own: do them one at a time, in the order given, one commit per package.

## Rules for whoever does this work

- Read `CLAUDE.md` and `docs/decisions.md` first. Where this file and `decisions.md` disagree, `decisions.md` wins, and the item goes back to the owner.
- Never change, regenerate or delete a file in `Tests/Golden/`. Removing a hand-written test that a golden already covers is allowed; removing the golden is not.
- These stay whatever else happens: `UndoFuzzTests`, `BatchRenameFuzzTests`, the release-script tests, the large-file tests, the shape tests of the stop and crash recordings, `ExplorerWindowControllerTests` with `FakeWindow`, the `PlainLabel` and `SearchTextCell` drawing tests, the dialog framework's tests, the dozen Settings layout tests.
- No benchmarks, no timing hooks. A speed guard is a `CPUTime.measureThread` bound.
- `decisions.md` lists these under "Left out on purpose": duplicate tests of the same behavior, suite and folder names that no longer match their contents, the roughly 30 "nothing happened after a fixed sleep" checks, tests that depend on installed apps, the appearance or the keyboard layout. Packages 4 and 5 touch the first of these; they are marked "needs the owner's yes". Do not rename or move suites, and do not touch the fixed-sleep checks except the few named in package 2.
- Line numbers are from commit `d545af2`. Most findings came from readers that did not run the code. Before deleting or merging a test, open both tests and confirm the claim; if it doesn't hold, skip the item and say so.
- Before a removal, confirm the surviving test fails when the behavior is broken (break the code by hand once, see it fail, undo).
- After each package: `scripts/ci.sh`, then compare the test count and the time with the baseline below.

## Baseline (measured on this Mac, 12 performance cores)

| Step | Time |
|---|---|
| `scripts/ci.sh`, nothing to build | about 52 s (build 2 s, tests 46 to 50 s, format lint 15 s beside the tests) |
| Build from clean | 44 s |
| Tests in a full run | 3,834 |

Where the 50 s of testing goes:

| Process | Tests | Wall time |
|---|---|---|
| Windowless window suites, 8 processes | 761 | 33 to 40 s each, 278 s of CPU in all |
| FTAppKitTests, the rest | 718 | 11 s alone, 15 to 21 s beside the others |
| FTOperationsTests | 956 | 13.6 s alone, 20 s beside the others |
| FTFoundationTests | 860 | 3 s |
| FTFileSystemTests, run last and alone | 539 | 6 s |

The run's length is the slowest windowless process plus FTFileSystemTests after it. Nothing else is on that path.

What was tried and did not help:

- More windowless processes: 49 s with 8, 46 s with 12, 46 s with 16. The Mac is already out of CPU.
- A faster poll in `waitUntil` (2 ms instead of 25 ms): no change. Don't do it.
- Skipping disk images (`FILETRAIL_NO_DISK_IMAGES=1`): FTOperationsTests 13.6 s to 10.0 s, FTFileSystemTests 6.6 s to 6.3 s. Neither changes the run's length.

A sample of a windowless process shows its time is AppKit laying out a real window (window layout about a quarter of the main thread, the toolbar's layout about a tenth, the sidebar's outline after that). The median windowless test takes 0.30 s and the cheapest that opens a window 0.2 s. So the only thing that makes these faster is opening fewer or cheaper windows.

## Verdict

The suite is worth what it costs. Nearly every test is named after a behavior or a past bug, timers are injected almost everywhere, and the write engine's safety rules are checked on real disks. It is also already fast: under a minute for 3,834 tests.

- Removable outright: about 60 tests (under 2%).
- Collapsible: about 200 tests into about 80.
- Duplicates of goldens or of each other that could go with the owner's yes: about 100 more.
- Expected speed gain from everything here: about 8 to 12 s of the 50 s. Most of it comes from packages 1 and 2, which touch a handful of tests.
- The more valuable finding is the list of untested data-safety paths in package 6.

## Package 1: cheap speed wins (do first)

Each is a small, local change. Measure before and after.

1. `Tests/FTAppKitTests/Windows/NativeWindowsTests.swift:129` makes 22 tabs to reach the limit of 25 and takes 2.6 s. Set `group.tabLimit` to a small number, as `Sidebar/SidebarRowPressesTests.swift:267` does. The 25 itself is checked in `Tests/FTFoundationTests/Preferences/PreferenceKeyTests.swift:148`.
2. `PathBarRowView.sizeValueLinger` (`Sources/FTAppKit/PathBar/PathBarRowView.swift:36`, 1.2 s, a `static let`) is waited out in real time by `Content/Icons/IconsTests.swift:335` and `:371` and `Content/CompactList/CompactListTests.swift:300`. Make the wait injectable the way the app's other timers are, and advance it by hand in the tests. Saves about 3.5 s of CPU-bound wall in three processes.
3. `Tests/FTAppKitTests/Content/LeadStaysInViewTests.swift` is the slowest windowless suite: 13.5 s for 16 tests. Its `open()` (line 14) writes 400 real files per case and lines 55 to 98 add up to 200 more. Move the view-parameterized cases (55, 72, 87, 167, 190, 271) onto the pane-only fixture `LeadStaysOnThePaneTests` in the same file already uses, or cut the file count to what the scrolling needs. Keep every case.
4. Recovery waits out real timeouts: `Tests/FTOperationsTests/Recovery/CopyPasteRecoveryTests.swift:29` (`answerWithinMs = 1_000`, waited in full at `:46` and `:102`), `Recovery/BatchRenameRecoveryTests.swift:134` (1,000 ms), `Coordinator/WriteCoordinatorWindowsTests.swift:543` and `Undo/UndoStartTests.swift:109` (500 ms). Use 50 ms, as `Recovery/WriteRecoveryTests.swift:176` does. Fix the stale "after 20 ms" comment at `WriteCoordinatorWindowsTests.swift:548`.
5. `Tests/FTOperationsTests/Exec/SwiftExecEngine.swift:119` sleeps a fixed 10 ms per golden case to let the service settle (158 cases). Replace it with a completion signal. `ExecGoldenTests` is the slowest suite in FTOperationsTests (10 s alone).
6. `Tests/FTOperationsTests/Copy/StoppableCopyTests.swift:129` (0.6 s) and `:134` (0.4 s) wait on the 250 ms progress ticker. Signal from `onProgress` for the first; test "doesn't fire again" on `DispatchProgressTicker` with a 5 ms interval.
7. `Tests/FTOperationsTests/Undo/UndoPlanTests.swift:459` sleeps up to 8 ms per `lstat` (1.9 s) and asserts `most > 1`, which depends on timing. Hold and release the lookups with semaphores.
8. `Tests/FTFileSystemTests/System/OpenWithCatalogTests.swift:144`: a stub `usleep`s 2 s on a thread nobody waits for. Release it with a semaphore in `defer`.

## Package 2: make FTFileSystemTests quick and able to run beside the others

`scripts/ci.sh` runs this bundle last and alone because its folder watches fall behind on a busy Mac. That costs 6 s at the end of every run.

1. `Tests/FTFileSystemTests/Watch/FolderWatchStreamTests.swift` (lines 37, 61, 96, 122, 152, 170) and `System/TrashFoldersTests.swift:189` sleep 300 to 500 ms hoping the FSEvents stream has started, and two tests wait 4 s before trying again when it hasn't. `FSEventsFolderWatcher.watchFolder` starts its stream in a detached task, so the sleep guarantees nothing. Either give `watchFolder` a "started" callback for tests, or have the tests repeat their probe write every 250 ms until told. The slowest test in the bundle (6.2 s, `tellsOfItemsMadeRenamedAndRemovedInsideTheFolder`) is one such retry.
2. The three "nothing was told" checks in those files (`FolderWatchStreamTests.swift:99`, `:157`, `TrashFoldersTests.swift:201`): after the change that must not be told, make one that must, wait for it, then assert the first is absent. This is three of the fixed-sleep checks `decisions.md` leaves alone; it is worth it here only because it is what lets the bundle run beside the others. Ask the owner if in doubt.
3. `FolderSize/NativeFolderSizeTests.swift:321` (`measuresAFolderWithMoreSubfoldersThanTheAppMayOpenFilesAtOnce`) makes 15,600 folders (3.3 s) and lowers `RLIMIT_NOFILE` for the whole process while other tests spawn `hdiutil`, `fd` and `ps`. Gate it to the release run (package 7).
4. `Listing/ResponseCacheTests.swift:198` bounds wall time with `ContinuousClock` (under 10 ms). Use `CPUTime.measureThread`. Same for `Tests/FTOperationsTests/Analysis/LargeTreeAnalysisTests.swift:125`.
5. `Icons/FileIconStoreTests.swift:312` sleeps 200 ms; the store already takes a `sleep:` parameter (`Sources/FTFileSystem/Icons/FileIconStore.swift:94`). Inject it.
6. Then try the bundle beside FTAppKitTests and FTOperationsTests in `scripts/ci.sh` (`full_tests`), 20 runs in a row. If it holds, drop the "last and alone" step; if not, leave the order and keep the speed-ups.

## Package 3: fewer windows (collapse without losing a case)

About 45 fewer window openings, roughly 11 s of CPU over 8 processes. Use `@Test(arguments:)`; follow `DragDrop/DragDropMatrixTests.swift` (lines 222, 265, 309, 392) and `WriteOperations/PasteEndsMatrixTests.swift:297`. Paths are under `Tests/FTAppKitTests/`.

| Where | Before to after | How |
|---|---|---|
| `Windows/ReleasedFolderTests.swift` 14, 29, 59, 78, 107, 134 | 9 to 4 | six tests open a window, clear the selection and check one property: one test |
| `Windows/TabsCarryTheViewTests.swift` 398 to 473 | 5 to 2 | keyboard pane: arguments over pane and (new tab, open, duplicate) |
| `Windows/TabsCarryTheViewTests.swift` 495 to 578 | 4 to 2 | refresh and view change keep the row |
| `Navigation/OpeningDiskImagesTests.swift` 29, 47, 61 and 116, 137, 150 | 6 to 3 | arguments: list, Info panel |
| `Navigation/FoldersThatGoAwayTests.swift` 101, 117 and 257, 268 | 4 to 2 | favorite or location; gone or unreadable |
| `Windows/KeysAndPressesTests.swift` 126, 146 and 214, 226; `Windows/TabsAndViewsMatrixTests.swift` 27, 38 | 6 to 3 | list or icons as an argument |
| `Menus/CommandRoutesTests.swift` 127, 145, 160 | 3 to 1 | menu dimming on one window |
| `Content/HiddenItemLookTests.swift` | 3 windows to 1 | switch the view in one window |
| `Layout/ResizerBandTests.swift` 36, 89, 235, 285, 297; `Layout/WorkspaceTests.swift` 12, 99, 253; `Layout/BandGeometryTests.swift:17`; `Layout/ZZReviewBandMenuTests.swift` 23, 40, 58 | 12 windows to 3 or 4 | chrome at rest checked on one window per file |
| `ContextMenus/ContextMenuRoutesTests.swift` 216 to 295 (Calculate Size) | 7 to 2 | table of where clicked, folder measured, panel opens |
| `Content/Icons/IconsTests.swift` 307, 349 and `Content/CompactList/CompactListTests.swift` 254, 282 | 4 to 2 | size commands and slider, by view |
| `App/LaunchContextTests.swift` | 9 to 2, and `DescribeOpenedPathTests` 3 to 1 | tables (no window; tidiness only) |
| `App/QuitWhileBusyTests.swift` 7 to 70 | 8 to 2 | table of kind and trigger |

Pure-logic collapses, no speed gain, lower priority:

- `Tests/FTFoundationTests/GridLayout/FlowListLayoutTests.swift:159-210` 11 to 1; `Clipboard/ClipboardTextsTests.swift:20-77` 8 to 2; `Formatting/SelectionStatusTests.swift:83-146` 9 to 2; reveal families in `FlowListLayoutTests` 30 to 48 and `IconGridLayoutTests` 59 to 85, 11 to 2; `PathsTests.swift:16-54` 6 to 2; `Commands/ShortcutPolicyTests` 22 to about 14.
- `Tests/FTFileSystemTests/System/ApplicationPathsTests.swift` 10 to 4; the highlight tests (`Search/HighlightModeTests.swift` and `SearchResultsTests.swift:115`) 6 to 1.
- `Tests/FTOperationsTests/Analysis/CopyPasteAnalysisTests.swift:263-394` 12 to 4; `Identity/CopyPasteFingerprintTests.swift:7-38` 4 to 1.
- `Tests/FTOperationsTests/Replace/ScenarioMatrixTests`: four tests loop over 30 scenarios inside the test body. Make them `@Test(arguments:)` so a failure names its scenario.

Do not collapse: `FolderSizeJobsTests`, `FolderSizeAdjustTests`, `FolderWatchesTests`, `TrashFoldersTests`, `FdSearchRuntimeTests`, `TrashOperationTests`' guards, `TrashItemTests`, `InterruptedReplaceRecoveryTests`, `BatchRenameSheetTests`, `FirstClickGateTests`, the DragDrop suites, `NavigationHistoryTests`, `ExpandReplacementTests`. Each name there is a distinct rule.

## Package 4: removals that lose nothing

Tests that assert a constant, restate the code, or test only a test double.

FTFoundationTests (paths under `Tests/FTFoundationTests/`):

- `About/AboutInfoTests.swift:38`, `ContextMenu/ToastsTests.swift:46`, `Commands/ApplicationMenuTests.swift:260`, `Clipboard/CopyPasteClipboardTests.swift:94`, `Layout/PaneWidthsTests.swift:19`, `Preferences/AppPreferencesTests.swift:24-36`, `Preferences/ViewSizeTests.swift:56`, `Contracts/CopyPasteChoicesTests.swift:74`: constants.
- `Design/MetricsTests.swift:129`, `GridLayout/FlowListLayoutTests.swift:17`, `GridLayout/IconGridLayoutTests.swift:19-29`: covered by the layout goldens in the same folders.
- `Commands/ShortcutPolicyTests.swift:225` (its own comment says the compiler checks it).
- `Commands/ShortcutTargetsTests.swift`, all 7: covered by `CommandAvailabilityGoldenTests`. Confirm case by case.
- `Navigation/DirectoryListingDiffTests.swift:41-44`: an unused private class.
- Ask the owner before touching `Design/MetricsTests.swift:93` and `:116` and `Commands/ShortcutsTests.swift:360`: they copy every design token and every default key, which may be a deliberate ledger.

FTFileSystemTests (under `Tests/FTFileSystemTests/`):

- `Icons/IconCacheKeyTests.swift:92`, `Icons/FileIconStoreTests.swift:366` and the constant line at `:299`, `System/ErrnoTextTests.swift:112` (builds its expectation with the same `strerror`), `Search/SearchResultsTests.swift:142` (tests FTFoundation's `StatusSummary`, covered there).
- `FolderSize/NativeFolderSizeTests.swift:500` (the first two assertions of `:420`), `Listing/NativeFileSystemTests.swift:126` (inside `:138`), `Listing/ExplorerServiceTests.swift:102` (inside `:635`; move the `kindLabel` assertion there), `Search/FdSearchRuntimeTests.swift:297` (no assertion; fold into `:281`).

FTOperationsTests (under `Tests/FTOperationsTests/`):

- `Execution/CopyPasteExecutionMetadataTests.swift:127` (tests the mock's switch) and `:115` (inside `:225`), `Execution/CopyPasteExecutionCutTests.swift:247` (call count for a pass that no longer exists), `Undo/UndoHistoryTests.swift:172` (a constant), `Native/NativeTrashTests.swift:64` (tests a test helper).
- `Replace/EdgeCasesTests.swift:82` and `:586`: the same as `Execution/QuestionLimitTests.swift:12` and `:39`.
- The `print` of elapsed time at `Execution/LargeTreeExecutionTests.swift:189-195` and `Execution/ReviewTopLevelCountPerfTests.swift:37`: a leftover timing hook. Keep the CPU bound.
- Dead test code: `Execution/MockWriteServiceFileSystem.swift:429` `remove(_:)`, `Undo/UndoStartTests.swift:21` `DiskGate.hasWaiters`, `Undo/UndoHistoryTests.swift:22` `units`.

FTAppKitTests (under `Tests/FTAppKitTests/`). The owner decided matching the earlier app pixel for pixel is not a goal; these pin frames, colors or sizes with no behavior behind them:

- `BatchRename/BatchRenameLayoutTests.swift`, all three; `About/AboutWindowTests.swift:156`; `About/AcknowledgementsWindowTests.swift:105`; `Help/HelpViewTests.swift:225, 245, 253, 262` (keep "compact puts the topics above the page"); `Sidebar/FoldersLabelBoxTests.swift:11-28`; `Search/ScopeBarMetricsTests.swift:12, 38`; `Toolbar/ToolbarTests.swift:164`; `Toolbar/CommandIconTests.swift:34`; `Settings/SettingsWindowRulesTests.swift:59`; `Appearance/AppearanceModelTests.swift:200`; `Appearance/WindowActivityTests.swift:104`; `Layout/FadesAndShadowsTests.swift:67, 73, 83`.
- Frame lines inside otherwise useful tests, to trim: `Content/Icons/IconsTests.swift:29-41, 58-61, 220`; `Content/CompactList/CompactListTests.swift:29-40, 176-178, 212-213`; `InfoPanel/InfoViewsTests.swift:120, 514, 423-424`; `Clipboard/ClipboardMenuRowsTests.swift:120-140`. The same numbers are pinned by the FTFoundation layout tests and goldens. Replace each with one "the views take the model's frames" check.
- Counts that break on every addition: `Automation/ScenarioTests.swift:115` (`== 77`), `Tests/FTFoundationTests/Commands/ShortcutsTests.swift:20, 34`, `Commands/ToolbarItemsTests.swift:92-93`.
- `Appearance/BoxShadowTests.swift:109` matches stand-in classes declared inside the test, never AppKit's.
- Leave the Settings frame tests and the dialog look tests: the owner kept them on purpose.

## Package 5: duplicates (needs the owner's yes)

`decisions.md` lists "duplicate tests of the same behavior" as left out on purpose. Offer this list to the owner; do only what is approved. The biggest groups:

1. Write engine, same scenario many times (under `Tests/FTOperationsTests/Execution/`):
   - "A same-disk move is a rename", 8 times: `CopyPasteExecutionRenameTests.swift:28, 209`; `CopyPasteExecutionMetadataTests.swift:172, 184`; `CopyPasteExecutionIntegrationTests.swift:10, 63`; `CopyPasteExecutionRealFSTests.swift:136, 212`. Keep `RealFS:136` and `Rename:209`.
   - The EXDEV fallback, 3 identical: `CopyPasteExecutionRenameTests.swift:127, 247`; `CopyPasteExecutionIntegrationTests.swift:25`.
   - Exact pairs: `CopyPasteExecutionCutTests.swift:165` and `CopyPasteExecutionEdgeTests.swift:141`; `CutTests:263` and `RenameTests:312`; `NativePasteTests.swift:47` and `RuntimeSafetyWholeFolderTests.swift:635`; `EdgeTests:86` and `RenameTests:56`; `CutTests:101` and `:296`.
   - Where a mock test and a real-disk test check the same rule, keep the real-disk one.
2. Hand tests that repeat a golden run through the same engine: about 20 in `Replace/` (`ConflictSafetyTests.swift:193, 210, 281, 346, 625, 677`; `ExecutionReplaceTests.swift:28, 92, 134, 150, 169, 208, 225, 288, 307`; `WriteServiceReplaceTests.swift:187, 267`), seven in `WriteService/WriteServicePasteTests.swift` (148, 162, 177, 254, 271, 303, 317), `Analysis/CopyPasteAnalysisTests.swift:41, 60, 72, 117, 168`, `WriteService/WriteServiceAnalysisTests.swift:163, 179, 191, 205`, `Copy/CopyPasteErrorsTests.swift:9, 15, 20`. Keep every test that injects a fault, counts reads, or names a safety rule.
3. `Tests/FTFoundationTests/BatchRename/BatchRenameTests.swift:784-886`: the first 8 tests of `PlanShownTests` are the scenarios of `Tests/FTOperationsTests/BatchRename/BatchRenamePlanAndRunTests.swift:77-180`, which checks the plan and then runs it.
4. Undo: a case-only rename three times (`Undo/UndoExecutionTests.swift:35`, `UndoRealDiskTests.swift:51`, `UndoNamesLockedTests.swift:49`); EACCES on rename-back three times (`UndoExecutionTests.swift:520`, `UndoFailuresTests.swift:53` and a row of `:349`); `UndoExecutionTests.swift:542` and `UndoFailuresTests.swift:279`.
5. Window tests that re-check a rule from a second entry point: Show Info on an unselected item four times (`InfoPanel/InfoTests.swift:193`, `ContextMenus/ContextMenuRoutesTests.swift:186, 198`, `InfoPanel/InfoPanelWritesMatrixTests.swift:43`); `Search/SearchEscapeAndWritesTests.swift:11` against `Search/SearchRoutesTests.swift:121`; `doesNotReadTheDetailsOfTheItemsOnScreen` identical in `IconsTests.swift:296` and `CompactListTests.swift:243`.
6. Identical helper copies (not the "similar but different" ones the owner left apart): `ScriptLog` twice in FTFileSystemTests, the fixtures-folder lookup four times there, `withOtherDisk` twice in `Execution/`, the search setup repeated in about 8 window test files, `launch`/`folders`/`menuBar`/`closeAll` copied between `NativeWindowsTests.swift` and `NativeWindowsGUITests.swift`.

Questions for the owner that came up:

- `Execution/UndoRecordingTests.swift:99, 268` and `Undo/UndoRecordingCoordinatorTests.swift:202` pin exact `lstat` counts (7 per copied file). Any harmless extra look breaks them. Loosen to an upper bound?
- `ExecGoldenTests.swift:27` replays each recording against itself. It helps diagnose a bad recording but adds no coverage. Keep?
- `BatchRename/BatchRenameSheetTests.swift:75` and lines 22, 24, 70, 283 assert accessibility text. If that text exists only for VoiceOver, it falls under "VoiceOver is not a target".
- ENOSPC is used as a generic "can't write" at `Execution/RuntimeSafetyWholeFolderTests.swift:266, 416`, `Execution/PartialFileTests.swift:161`, `Replace/ConflictSafetyTests.swift:423`. The rule is EIO; these pass only because one item is pasted.
- `Navigation/FoldersThatGoAwayTests.swift:106` pins the user-facing text `"ENOENT: no such file or directory, stat '…'"`. Is that the wording wanted?
- The golden runs carry no `.diskImages` trait, so `FILETRAIL_NO_DISK_IMAGES=1` doesn't skip them, though the comments at `ExecGoldenTests.swift:37` and `:237` say it does. Fix the comment or the trait?

## Package 6: tests to add (most valuable part)

Ordered by what a miss would cost. Each claim of "no test" was made by search; confirm before writing.

Data loss:

1. The journal failing to write while a folder is staged (`Sources/FTOperations/Execution/ExecutionNodes.swift:86, 160`, `ExecutionFiles.swift:185`) and for a large file's partial record (`ExecutionFiles.swift:44`). `MemoryJournal.failOn` is used once in all the tests, for a single-file Replace.
2. The counted permanent delete, a must-stay rule: a folder that can't be counted on a disk with no Trash (`Sources/FTOperations/Replace/ReplacedItem.swift:55-59`) and a delete failing part way (`:88`).
3. Journal text escaping (`Sources/FTOperations/Journal/FileWriteJournal.swift:193`, hand-written): write an entry whose path holds a quote, a backslash, a newline, a control character and NFD text, then read it back. A break here sets the whole journal aside and orphans staged items.
4. `NativeRemoval.removeTree` (`Sources/FTOperations/WriteService/WriteServiceFileSystem.swift:164`): no test names it. Delete a folder holding a symlink to an outside folder on a real disk and check the target survives.
5. `removeEmptyFolder`'s read before `rmdir` (same file, line 54, must-stay): no test names it.
6. The staging-name guards `isStagingName` and `isTemporaryName` (must-stay) have one negative case each. Add a table: 7 hex digits, uppercase hex, no leading dot, a user's file named like `x.filetrail-0000000g`.
7. A plain folder moved to another disk with a child that fails to copy (`ExecutionNodes.swift:148`): only the package case is tested.
8. Stop between "copy placed" and "original removed" for one file moved across disks (`ExecutionNodes.swift:279-303`).
9. Batch-rename recovery through `recoverWrites` (`Sources/FTOperations/Recovery/WriteRecovery.swift:102-134`): the entry left alone while another write runs, and the journal rewritten with only what remains after a partial put-back.
10. The journal's byte-for-byte format test (`Journal/FileWriteJournalTests.swift:158`) covers `replace` and `partial_file` but not `batch_rename`.

User-visible:

11. `Sources/FTFoundation/BatchRename/JSRegExp.swift` (622 lines, must-stay) has no direct test; the golden normalizes error text to a prefix, so none of its roughly 20 error messages is checked.
12. `Sources/FTFoundation/CopyPaste/RuntimeConflictText.swift` (the conflict card shown mid-paste): no test references it.
13. Sorting by a click on a List column header (`DetailsHeaderView.onSort`): no test references it.
14. A double click on a path bar segment cancelling the pending single click (`Sources/FTAppKit/PathBar/PathBarView.swift:375`).
15. Listing and sizing on exFAT and FAT32: the "disk left an attribute out" path is tested with a hand-built struct only. `DiskImage.withSharedVolume(.exfat/.fat32)` exists. One release-only test.
16. `VolumeEjector`'s timeout (`timeoutSeconds` is injectable, no test passes it); `FdProcess` failing to spawn.
17. Inject the 400 ms Loading delay (`Sources/FTAppKit/Content/ContentPaneController.swift:350`) and the 250 ms `retryDelay` (`MainWindowController.swift:833, 970`). `Navigation/FolderMemoryMatrixTests.swift:231`, `Navigation/OpeningStartsCleanTests.swift:167, 228` and `Navigation/FolderChangesMatrixTests.swift:98` sleep past them in real time, so their "nothing showed" checks can pass on a slow Mac without checking anything.
18. The 350 ms hold on Back and Forward (`Sources/FTAppKit/Toolbar/ExplorerToolbar.swift:499`) is not injectable, so it is checked only before a release.

## Package 7: what runs when

The full suite takes under a minute, so nothing needs to leave the commit run for time. The split below is about keeping the commit run steady and making the release run mean more.

Before each commit (no change in commands):

- While working: `scripts/ci.sh --scope <filter>`.
- Before committing: `scripts/ci.sh --affected`, or `scripts/ci.sh` when shared code changed.
- Contents: everything that runs today, minus the items moved below.

Move to the release run only (gate them the way `LargeFileTests.enabled` gates the large-file tests; one switch, say `FILETRAIL_RELEASE_TESTS=1`, set by `scripts/release.sh`):

- `Tests/FTOperationsTests/DiskImages/DiskImageSelfTests.swift` (11 mounts) and `Native/SharedVolumeTests.swift`: they test the test helper. Every disk format is mounted by a real test anyway.
- `Tests/FTFileSystemTests/DiskImages/DiskImageSlotsTests.swift`: same reason.
- `measuresAFolderWithMoreSubfoldersThanTheAppMayOpenFilesAtOnce` (package 2, item 3).
- `Tests/FTOperationsTests/Execution/LargeTreeExecutionTests.swift:183` (150,000 files): or keep it per commit at 15,000, since it asserts counts.
- `Tests/FTAppKitTests/App/ShellActionsTests.swift:36` (a second launch through the real `DistributedNotificationCenter`).

Fewer mounts per commit run matter beyond time: `Tests/FTOperationsTests/Native/NativeTestSupport.swift:150-157` records that after about 32,700 mounts since boot the Trash fails until restart. `withSharedVolume` detaches when its last user finishes (`Tests/FTTestSupport/DiskImage.swift:116-122`), so tests that don't overlap mount again; `ExecPlaces` already keeps one image per format for the process. Give `withSharedVolume` the same lifetime: about 17 uses become at most 4 mounts.

Before a release (`scripts/release.sh`), in addition to what it runs today (`scripts/ci.sh --full` with the large-file tests, then the `GUITests`):

- The gated tests above.
- The Undo fuzz with more cases and a fresh seed. `UNDO_FUZZ_CASES` and `UNDO_FUZZ_SEED` exist (`Tests/FTOperationsTests/Undo/UndoFuzzTests.swift:395`) and no script sets them, so every run replays seeds 1 to 60. Set about 1,000 cases and a seed from the date, and print the seed. Check how `BatchRenameFuzzTests` takes its seeds and do the same there.
- Keep 60 cases per commit. The three tests at `UndoFuzzTests.swift:454, 510, 574` draw the same scripts per seed; offset their seeds so each run covers three times as many.

Things only a release checks today, worth knowing: Move Tab to New Window on real tabs, window frames restored at relaunch, Window-menu titles, real menu tracking, the toolbar's customize sheet and overflow, a real disk image opened in a tab. Item 18 of package 6 would bring one of them into the commit run.

## Package 8: housekeeping

- `Package.swift`: the comment on `FTFileSystemTests` mentions budgets and `tools/bench/listing.sh`, which are gone, and no test reads the `RELEASE` define it sets. Remove both.
- `scripts/ci.sh`: `full_tests` runs `swift build --build-tests` again right after the build step. Harmless, a second or two.
- The windowless processes finish between 33 and 40 s although the groups are balanced by last run's times. If that spread holds after packages 1 and 3, have the processes take suites from a shared queue instead of fixed groups; worth up to 4 s.
- Stale comments: `Tests/FTAppKitTests/InfoPanel/InfoViewsTests.swift:550` ("320 ms"; it is 250), `Settings/SettingsWindowRulesTests.swift:58` ("pinned commit"), `Tests/FTFoundationTests/Commands/ShortcutPolicyTests.swift:42` and `Design/MetricsTests.swift:7` (zoom), `Tests/FTOperationsTests/Execution/NativePaste.swift:266` (`failOn` takes a predicate), `Recovery/WriteRecoveryTests.swift:399` ("both kinds"; there are three).
- `Tests/FTAppKitTests/Windows/ExplorerHarness.swift:45` names every windowless test's folder `filetrail-toolbar-gui`.
