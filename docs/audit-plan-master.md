# Audit follow-up plan (master)

This plan combines two independent read-only audits of the whole repository, both made at commit `c58b3fe`
(2026-11-10). At that commit `scripts/ci.sh` passed: zero warnings in the sources, 3,877 tests, format lint clean.
Everything here is below what CI sees. It replaces `docs/audit-plan01.md` and `docs/audit-plan02.md`; nothing in
those two files is needed once you have this one.

It is written to be carried out by someone who was not part of either audit. Read "How to work through this" in
full, then work the phases in order.

## How to work through this

### Before anything else

1. Read `CLAUDE.md`, `docs/known-issues.md` and `docs/battery.md`.
2. Run `scripts/ci.sh` once to confirm a clean baseline. If it is not clean, stop and say so.
3. Line numbers are from `c58b3fe` and will drift as you work. The symbol names are what counts: find the symbol,
   confirm the claim, then act.

### Decisions on record (made by the owner, 2026-11-10)

1. **Pixel parity with the earlier app is not a goal.** Code, tests and goldens that exist only to match the
   earlier app's stylesheet or layout pixel for pixel may go. Prefer the system's controls and look.
2. **The minimum macOS is 26.** Fallbacks for macOS 14 and 15 may go.
3. **File Copy, Cut and Paste keep using the app's own clipboard.** Do not move them to the system pasteboard.
4. **Batch rename keeps JavaScript regular-expression semantics for now.** `Sources/FTFoundation/BatchRename/JSRegExp.swift`
   stays as it is. Revisit later: replacing it with `NSRegularExpression` would remove about 530 lines but would
   change what `\d`, `\w`, `\s` and `\b` match (ASCII-only today, Unicode in ICU), case folding of `ß` and
   ligatures, which syntax is accepted, and the wording of pattern errors. `expandReplacement` (`$1`, `$&`,
   `$<name>`) would stay either way.

   This decision is read as covering batch rename, where the pattern decides what gets renamed. It is **not**
   read as covering the search-result highlight (item 5.2), where the matching is done by `fd` with Rust regex
   and JavaScript semantics were never what the user got. [Q7] asks the owner to confirm that reading.

Standing decisions from before the audits, which settle some items below without a question:

- VoiceOver is not a supported target. Do not add accessibility work; VoiceOver-only code may go (5.11).
- There is no import or upgrade path from the earlier app. The earliest release of this app is v0.8.0.
- Glass is used on toasts, the progress card, plain alerts and the type-select pill. Sheets, Go To and alerts
  with lists or fields stay opaque.
- A window holds at most 25 tabs.

### How much to trust each item

- **[verified]**: the lead of the second audit read the code and the finding holds. The failing scenario was still
  not run in the app, except where the item says a reproduction was made.
- **No label**: reported by one audit from reading the code; nobody re-checked it. Confirm it first, by reading the
  path end to end and, where practical, with a failing test. If it does not hold, do not "fix" it: note it in the
  Log at the bottom of this file and move on. "Found by both audits" in an item means the two audits reported it
  independently, which is good evidence but still not a run.
- **Deletions** (Phase 5) were each proven unused at `c58b3fe` by search. Prove again before deleting; see the
  rule below.
- **[Q1]…[Q18]**: needs the owner's answer before work on that item starts. The questions, each with a
  recommendation, are in "Open questions" below.

### Rules

- Work on a branch off `main`, not on `main`. Do not push, tag, release or open a pull request. The owner lands
  the branch by fast-forward or rebase; never make a merge commit.
- One item (1.3, 5.7, …) per commit. The large deletion and simplification items may take one commit per bullet.
  Commit messages follow the repository's style: one plain sentence that says what is now true of the app, not
  what was edited (see `git log --oneline -20`), for example "A failed copy whose name says 'aborted' no longer
  ends the paste as cancelled". No `Co-Authored-By` trailer.
- Tick the item's checkbox in this file in the same commit, and add a dated line to the Log for anything that
  differed from the plan.
- **Bug fixes (Phases 1, 3 and 8): test first.** Write a test that fails for the reason described, then fix, then
  see it pass. If a test is impractical (pure AppKit visuals), say so in the commit body and list what to check by
  hand. Keep the fix as small as the finding: do not refactor around it and do not fix a neighbouring finding in
  the same commit.
- **Prove before you delete.** Search again with a word-boundary search over `Sources/`, `Tests/`, `scripts/` and
  `tools/`, and rule out: selectors and `@objc`, methods AppKit calls on delegates and data sources, `Codable`
  keys, `#if DEBUG` code, and uses from scripts. Several views read constants through an alias
  (`let layout = X.self; layout.name`), so search for the member name alone too. Paste the search command in the
  commit body. If you find a production caller, do not delete; note it in the Log and move on. Delete the tests
  that only exercise the removed code in the same commit.
- **Never weaken a test to make a change pass.** Delete a test only when its subject is deleted by the same item.
  If a test of something this plan does not touch starts failing, stop and find out why.
- **Goldens** (`Tests/Golden/*.json`) are edited by hand, and only where an item names the file and the change.
  You may use a throwaway script kept outside the repository to make a mechanical edit, but read the resulting
  diff. Never regenerate a golden from the code's own output. Any other change or deletion of a golden needs the
  owner's yes first.
- Comments describe this app on its own terms: no record numbers, no "Port of", no names of files, functions,
  constants, channels or stylesheet rules from the earlier app, no "the original". New and touched comments must
  follow this even before Phase 10.
- Tests use Swift Testing (`@Test`, `#expect`). Shared helpers belong in `Tests/FTTestSupport`.
- After each item: `scripts/ci.sh --affected`. At the end of each phase: `scripts/ci.sh` (everything). Logs are in
  `build/logs/`. Do not run two builds at once.
- For anything the owner will want to try by hand (anything visible), run `scripts/build-app.sh` and say what to
  try before spending time on full CI. Phases 4, 8 and 9 change what users see: for each item there, build the
  app and stop for the owner to try it before starting the next item. Do not batch them.

### Stop and ask the owner when

- a proof search disagrees with this plan;
- a fix needs a golden changed or deleted and the item does not name that change;
- an unlabelled item turns out to be intended behaviour according to a comment or a test;
- a fix needs a product decision this plan does not make, or would change what a user sees beyond what the item
  describes;
- something in "Must stay" would have to change;
- an item in the write path (`Sources/FTOperations`) cannot be done without changing a test that is not named in
  the item;
- the same test fails twice for a reason you cannot explain.

### Phase order and sessions

| Phase | What | Why here |
|---|---|---|
| 1 | Verified bugs | Small, independent, already checked against the source. |
| 2 | Checks that tell the truth | The checks you rely on in every later phase must be sound first, above all the crash tests before the write engine is touched. |
| 3 | Reported bugs | Confirm, then fix. Most harmful first within each group. |
| 4 | Minimum macOS 26 | Removes fallbacks before the deletions look for dead code. |
| 5 | Deletions | Less code to simplify, speed up and re-comment afterwards. |
| 6 | Simplifications | Structure only, same behaviour. |
| 7 | Speed and stalls | Measured, after the code they touch has settled. |
| 8 | Behaviour the owner decides | Each waits on an answer and a hand test. |
| 9 | System controls | Changes the look; one item at a time with the owner. |
| 10 | Comments | Last of the code work, so removed code is not rewritten first. |
| 11 | Docs, scripts, tools | |
| 12 | Wrap-up | |

Start a new session for each phase so context stays short; this file and its checkboxes carry the state between
sessions. Phases 3, 5 and 6 are too large for one session: take one group (3A, 3B, …) or a handful of items per
session. Phase 10 can be done while Phase 9 waits on the owner.

At the start of a phase, ask every open question that phase depends on in one batch, with the recommendation, and
carry on with the items that need no answer meanwhile. Record each answer in the Log.

### Open questions

| | For | Question | Recommendation |
|---|---|---|---|
| Q1 | 2.7 | Should `scripts/release.sh` run the tests that drive real windows? | Yes. A release is run at the keyboard and these are the only tests of real windows. |
| Q2 | 2.9 | The `exec-stop` and `exec-crash` recordings are only replayed against themselves. What should happen to them? | Add real interrupted-Replace tests first. Run through the engine whichever recording can be; delete a recording that cannot, with the tests that only describe it. Keep the shape tests of the recordings that stay, with a comment saying what they guard. |
| Q3 | 3A.3 | Check free space before a paste starts? | Not now. Make a full disk stop the run (3A.3); a pre-check is a feature of its own. |
| Q4 | 3A.10 | Flush the journal for the entry that guards a moved item's only copy? | Yes, for that one entry only. It is written once per Replace. |
| Q5 | 3B.2 | What happens to tabs dragged into a window that already has 25? | Move each surplus tab into a new window of its own and show the tab-limit notice; where AppKit lets the drop be refused first, refuse it. Never drop them at save. |
| Q6 | 5.1 | Delete the 800-line collation table kept for the case that the system's ICU library does not load? | Yes; fall back to Foundation's compare in that case. The audits disagreed here: one called the table a deliberate fallback. The golden stays, and the ICU path is what passes it. |
| Q7 | 5.2 | Does decision 4 (JavaScript regex semantics) also cover the search-result highlight? | No. The search itself is done by `fd` with Rust regex, so JavaScript semantics were never what the user got. If yes, skip 5.2. |
| Q8 | 5.6 | `NavigationHistory.mapPaths` is called by nothing: should Back, after a folder in the history is renamed, follow the rename? `QuickLookController.windowWillChange` is called by nothing: should the panel close or follow when the folder changes? | Say what is intended. Until then neither is deleted or wired. If the behaviour is not wanted, delete the unwired code. |
| Q9 | 5.10 | Are `scripts/hands-on-setup.sh`, the `FILETRAIL_TIMING` switch and `tools/acknowledgements` still used by hand? | Delete each that is not. Nothing in the repository calls them. |
| Q10 | 5.14 | The golden files carry four metadata fields that nothing reads and that name a commit and a generator not in this repository. | Make the four fields optional in the decoder and strip them from the JSON. The cases themselves do not change. |
| Q11 | 8.1 | Show the startup disk's real name instead of "Macintosh HD"? | Yes, as other disks already do. Help can keep "Macintosh HD" as the example. |
| Q12 | 8.2 | Sort names one way everywhere, in the user's language, with numbers in order (file2 before file10)? | Yes. For an English user nothing changes except that search results get numeric order. This changes `Tests/Golden/search-sort.json` by hand. |
| Q13 | 8.3 | Should listings treat as packages the same 37 extensions that naming does, instead of 10? | Yes: `.rtfd`, `.xcworkspace`, `.photoslibrary`, `.pkg` and `.sparsebundle` show as folders today. This changes which rows are folders and may change listing goldens. |
| Q14 | 8.4 | Match accented letters in the list filter regardless of how the name is stored? | Yes, for the list filter, type-select and place ranking only. Normalize both sides for the comparison; never change a stored name. |
| Q15 | 8.5 | Can the Trash favorite be removed from the File menu as well as the context menu? | Yes, in both menus; `Favorites.swift:108` already supports it. |
| Q16 | 10 | Rename identifiers that carry the earlier app's vocabulary? | Rename the plainly leftover ones: `RendererCommand`, `InfoLocale.original`/`DateText.original`, `JSStringEquality`, `CSSTextMetrics`, `originalKeys`. Leave `JSString`, `JSText`, `JSRegExp`, `NodePath`: they name rules the app keeps (decision 4), and renaming them is large. |
| Q17 | 11.1 | `docs/finder-trash-workaround.diff` no longer applies. | Name in `known-issues.md` the commit it applies to, which keeps the record at no cost. Regenerate it only if you still mean to apply it; otherwise delete it and the sentence that points to it. |
| Q18 | 11.4 | `tools/bench`: nothing runs it and its stored baseline breaks 6 of 11 budgets. | Keep `listing.sh` and the bench tests; fix `run.sh` and record the baseline again, since nothing else enforces the budgets. The alternative is to delete `run.sh`, `report.py` and `baseline.json`. |

Settled without a question: removing the unused theme colours and the stylesheet comparison (decision 1);
removing journal compatibility for files only the earlier app wrote (no upgrade path; 5.8 still has a proof
step); removing the VoiceOver-only sidebar code (not supported); SF Symbols for toolbar and menu icons
(decision 1 and `CLAUDE.md`).

---

## Phase 1. Verified bugs

Order is by harm. Each is independent.

### [x] 1.1. A failed copy is taken for a Stop

[verified]
`isAbortError` in `Sources/FTOperations/Execution/ExecutionContext.swift:309` returns true for any error whose message
contains "aborted". Native error messages embed the item's paths (`NativeError.errno` builds
`"<CODE>: <strerror>, copyfile '<src>' -> '<dst>'"`), and `ECONNABORTED`'s code name contains it too. A failed copy of
"Aborted run.log" therefore ends the whole paste as cancelled, with the remaining items "Not started" and the real
error replaced by "Operation cancelled." Callers: `WriteServicePaste.swift:112`, `ExecutionFiles.swift:80`,
`CopyPasteExecution.swift:62`, `ExecutionNodes.swift:123` and `:397`, `CopyPasteReplace.swift:140`.
*Fix:* decide by type only (`StopError`, `CancelledWithItemsError`, and `CancellationError` if any path throws it).
Before removing the string test, grep `Sources/FTOperations` for every error thrown to mean "stopped" and make sure
each is one of those types.
*Test:* a paste whose one item fails with an errno error and whose name contains "aborted" ends `.failed`/`.partial`
with that error, not `.cancelled`.

Found by both audits. Real stops are already typed: `StoppableCopy` turns `ECANCELED` into `StopError`
(`Copy/StoppableCopy.swift`, near line 106). `Tests/FTOperationsTests/Replace/EdgeCasesTests.swift` (near line 200)
throws `OperationError("The operation was aborted")` to simulate a stop; change it to throw `StopError()`. Write
the new test on a real temporary directory: two items, the first fails with a permission error inside a folder
named `Aborted Takes`; expect the first failed, the second copied, and the result not cancelled. The `exec-*`
golden suites must still pass.

### [x] 1.2. Folder size fails on a folder with many subfolders

[verified; reproduced by the auditor outside the repo]
`Sources/CFileTrail/foldersize.c:399-402` opens every subfolder with `openat` while reading its parent and keeps the
descriptor in the work queue until a worker reaches it. A GUI app's soft limit is 256 descriptors and nothing raises
it. `EMFILE` is not in `is_skippable_open_error`, so the root is marked incomplete and the measurement errors. A
standalone build of the walker under `ulimit -n 256` failed with errno 24 on `/System/Library/Frameworks` (340
subfolders).
*Fix:* queue the child's path (already built just below) and open it in the worker that takes it from the queue,
with the same `O_RDONLY | O_DIRECTORY | O_NOFOLLOW`. Get the device for the "same volume" test from the bulk read by
adding `ATTR_CMN_DEVID` to the request, which also removes the `fstat` per subfolder. Keep the mount-point rule as it
is. Do not just raise the limit.
*Test:* in `Tests/FTFileSystemTests/FolderSize`, lower `RLIMIT_NOFILE` to 256 inside the test (restore after), walk a
temp folder with 600 empty subfolders, expect a complete result.

### [x] 1.3. The window freezes when a large Trash or Delete ends

[verified]
`collapseNestedPaths` in `Sources/FTAppKit/WriteOperations/AfterWrite.swift:162` is quadratic: a linear
`unique.contains` per path, then `roots.contains(where: isAtOrInside)` per path, each allocating `folder + "/"`. It
runs on the main actor from `ExplorerWriteSession.ended`. A standalone copy took 0.66 s for 2,000 flat paths, 4.2 s
for 5,000, 16.6 s for 10,000. `pathsLeftByWrite` (`:74-79`, `!left.contains(move.from)`) has the same shape.
*Fix:* a set for uniqueness, and for nesting walk each path's ancestors against a set of roots already kept
(cost: paths × depth). Paths must be compared exactly, not by canonical equivalence: Swift `String` hashing treats
NFC and NFD as equal, so key the sets with the project's exact key (`NameKeys.Exact` in FTFoundation, or the UTF-8
bytes). Keep the output order identical to today's.
*Test:* the existing `AfterWriteTests` must still pass unchanged; add a CPU-time test (`CPUTime.measureThread`) with
20,000 flat paths and a generous bound.

### [ ] 1.4. Back and Forward leave the history wrong when the read fails or is overtaken

[verified]
In `MainWindowController`'s navigation (`Sources/FTAppKit/Windows/MainWindowController.swift:1117`), `goBack`,
`goForward` and `jump` move `navigationHistory.index` before `await readFolder(url)`. Neither the `.superseded` return
(`:1126`) nor the `.failed` returns (`:1140-1155`) put it back.
- History [A, B, C] on C; Back to a slow B; open D before B arrives. The push lands after B's index, giving
  [A, B, D]: C is lost and B, never shown, stays.
- Back to a deleted B: C stays on screen with the index on B. Forward is enabled and "goes" to C, and the next
  Refresh or re-sort (`.replace`) overwrites B's entry.
*Fix:* `leftPlace` is already captured before the move. On `.superseded` and on a failure that leaves the old folder
on screen, restore the index to `leftPlace.index`. Read the comment above the switch first: the early move exists so
that "the results to come back are those left where this goes", so keep the early move and add the restore, rather
than delaying the move.
*Test:* both scenarios above, in `Tests/FTAppKitTests/Navigation`, using the held-read file system in
`FolderReadProbe.swift`.

### [x] 1.5. A rename can start with text typed in another tab

[verified structure; scenario not run]
`RenameDrafts` (`Sources/FTAppKit/Selection/InlineRename.swift:20`) is one app-wide store keyed by an `Int`. The key
is `renameSessions`, counted per `ContentPaneController` (`ContentPaneController.swift:164`, `:767`), and there is one
controller per tab. Two tabs' first renames both use key 1. Start a rename in tab A and type; switch to tab B without
ending it; start B's first rename: the field is initialised from A's draft, and Return submits A's text for B's file.
*Fix:* make the session number app-wide (one static counter, main-actor), so keys never collide. Smallest change;
keep the store as it is.
*Test:* two controllers, a kept draft in the first, begin a rename in the second, expect the second's field to hold
its own item's name.

### [x] 1.6. Searching from "/" finds everything twice

[verified; reproduced by the auditor with the bundled fd]
`Sources/FTFileSystem/Search/FdSearchArgs.swift:23-25` excludes only `/Volumes` when the root is "/". The data volume
is also reachable at `/System/Volumes/Data`, which is not hidden, so each item under `/Users`, `/Applications` and so
on is returned twice and the 20,000-result limit is effectively halved.
*Fix:* also pass `--exclude /System/Volumes` for a "/" root. Check with the bundled binary
(`Resources/fd/darwin-arm64/fd`) that the anchored pattern is honoured with and without `--hidden`.
*Test:* extend `FdSearchArgsTests`.

Found by both audits. A leading `/` in an fd exclude matches only at the top of the search, so a search started
inside `/System/Volumes/…` is unaffected; add a test that says so. `Tests/Golden/search-args.json` pins the
argument list: edit by hand every case whose root is `/` to carry the extra pair, in the position the code emits
it. Update the comment above the block to describe both exclusions. Check by hand that
`Resources/fd/darwin-arm64/fd --type d --max-depth 4 --exclude /Volumes --exclude /System/Volumes --absolute-path --color never '^Users$' /`
prints `/Users/` only.

### [x] 1.7. Changing a search option in Settings leaves stale results that typing then narrows

[verified]
`applyDefaults` (`Sources/FTAppKit/Search/SearchSession.swift:462`) sets `recursive`, `matchScope`, `skipGit*` and
`patternMode` "without running anything again". `canRefine` (`:418`) does not know the results on screen were found
with other options, so one more typed letter filters the old results. Example: results found with subfolders off,
Settings turns them on, type a letter: subfolder matches never appear. The highlight uses the new scope at once, so
the marks disagree with the results too.
*Fix:* remember the options the results on screen were found with (set where a search starts); `canRefine` requires
the current options to equal them. Typing then starts a new search. Do not make the Settings edit itself re-run the
search; the comment says that is intended.
*Test:* in `Tests/FTAppKitTests/Search`, the example above.

### [x] 1.8. Every in-window alert stays in memory

[verified]
In `InWindowAlerts.ask` (`Sources/FTAppKit/Dialogs/InWindowAlerts.swift:32`) the button closures capture the local
`var scrim`, the scrim holds its panel, the panel holds the content and its buttons. Nothing clears the box. The same
shape is in `askName` (`:86`) and `CopyPasteReviewPresenter.presentAlert`
(`Sources/FTAppKit/CopyPaste/CopyPastePresenters.swift:88`). `presentSheet` in that file uses `[weak scrim]` and is
fine. Each leaked scrim keeps its theme observation (`DialogScrim.swift:55`).
*Fix:* set `scrim = nil` after `dismiss()` in `answer`, and in the dismissal closure; same in the other two.
*Test:* present, answer, drain the main queue, expect a weak reference to the scrim to be nil.

### [x] 1.9. Details stay stale after a search closes

[verified]
In `ContentPaneController.show` (`Sources/FTAppKit/Content/ContentPaneController.swift:397`), a re-read of the folder
under search results does `if changedPaths == nil { kept.details.markChanged(nil) }`. With a watcher's specific
`changedPaths`, nothing is marked, so after the search closes the changed file keeps its old size and dates.
*Fix:* `kept.details.markChanged(changedPaths)` unconditionally (it already takes nil to mean "all").
*Test:* `Tests/FTAppKitTests/Content/ReviewRowWidthTests.swift` holds `ReviewStaleDetailsTests`; add the case there.

### [x] 1.10. The Info Row keeps the previous selection's icon

[verified]
`InfoRowView.show` (`Sources/FTAppKit/InfoRow/InfoRowView.swift:192`) takes `rebuildInPlace` when the name and fact
count are unchanged, and that path never updates the icon. Two different 2-item selections both read "2 items", so the
first lead's icon stays.
*Fix:* update the icon in `rebuildInPlace`.

---

## Phase 2. Checks that tell the truth

These come before the large phases so that the checks you rely on while doing them are sound. 2.9 in particular
must be done before anything in `Sources/FTOperations` is changed in Phases 3, 5 and 6.

### [x] 2.1. "Zero warnings" covers the tests and the release build

- Facts: `scripts/ci.sh` fails on a warning only for the `swift build` step (line 153, `WARN_FAILS=1`). The test
  build (`swift build --build-tests`, line 215) and the release build are not checked. The last passing run's
  `build/logs/test.log` has six warnings; `build/logs/build-app.log` has one in shipped code.
- First fix the warnings:
  - `Tests/FTOperationsTests/Execution/ReviewTopLevelCountPerfTests.swift:10` (no async work inside `await`)
  - `Tests/FTOperationsTests/WriteService/WriteServiceRuntimeTests.swift:66` (non-Sendable to `@Sendable`)
  - `Tests/FTFileSystemTests/System/SystemActionsTests.swift:142` (written, never read)
  - `Tests/FTAppKitTests/Search/SearchResultsInTabTests.swift:95` and `Content/TrashHeaderTests.swift:105`
    (mutated after capture by a sendable closure)
  - `Tests/FTAppKitTests/Settings/SettingsWindowTests.swift:702` (redundant `#require`)
  - `Sources/FTAppKit/Settings/SettingsWindowController.swift:65`: "weak reference will always be nil because the
    referenced object is deallocated here" (the `EmptyPageHost()` temporary). Release builds only. Read the code:
    `EmptyPageHost` (lines 192–204) looks unreachable; if it is, delete it and the fallback that uses it.
- Then extend the check: apply `WARN_FAILS=1` to the test-build step. `ci.sh --full` (lines 20–23, 338–343) already
  builds the release app and has no caller; make `scripts/release.sh` call `scripts/ci.sh --full` (it calls plain
  `ci.sh` at line 156 today) and make the `app` step fail on a warning.
- Find out whether an incremental build re-emits warnings for files it does not recompile. If it does not, the
  check only covers recompiled files; say so in the comment above the step and make `release.sh` do a clean build.
- Update `CLAUDE.md` and `README.md` (line 147) so the claim matches what is enforced.

Found by both audits. The simplest shape for the check: replace the two builds with one `swift build --build-tests`
under `WARN_FAILS=1`, and do not go on to the test step when the build fails.

### [x] 2.2. `ci.sh --affected` never passes with nothing run

- Where: `changed_files` (`scripts/ci.sh`, lines 102–109) diffs against `main` and `origin/main`. On `main` with
  everything pushed it finds nothing and prints `PASS test (nothing affected)` and `PASS format (no changed files)`.
- Fix: when no file is changed, run everything and say so in the summary line.
- Also: the comment at line 292 ("from either Swift Testing or XCTest output") and at line 205 ("Known failures are
  skipped in every process") describe things that do not exist; correct or remove them.

### [x] 2.3. `scripts/ci.sh --scope` with no value loops forever

`ci.sh:13-14`.

### [x] 2.4. `--affected` misses the bundle a file was moved out of

`ci.sh:104-106`: add `--no-renames` to the diff.

### [x] 2.5. Format lint covers `Package.swift` and `tools/capture/readme/photos.swift`

`ci.sh:335`.

### [x] 2.6. A release cannot pass with fixture tests silently skipped

- Facts: tests gated on `~/Library/Caches/filetrail-dev/fixtures` skip when it is missing
  (`.enabled(if: hasFixtures)` in `FileKindTests.swift:23`, `FolderSizeGoldenTests.swift:84`,
  `FdSearchProcessTests.swift:73`, `FixtureGoldenTests.swift:19`). The fixtures are built by
  `bun tools/fixtures/generate.ts`; `bun` is required but mentioned in neither `CLAUDE.md` nor `README.md`.
- Fix: `scripts/release.sh` fails early, with a message naming the command to run, when the fixtures folder is
  missing. Document `bun` as a build-time requirement in `CLAUDE.md` (Test data) and `README.md` (line 135).

Found by both audits. Also have `scripts/ci.sh` print one line when the fixtures are absent, so a run with skipped
tests is visible (`FixtureGoldenTests.swift:37, 97` skip silently as well). Two tests gate on `fixtures/names` but
also read `lighthouse` and `bench`: gate each on what it reads.

### [x] 2.7. The GUI tests run before a release, and the documented command runs all of them

- Facts: neither `ci.sh` nor `release.sh` sets `FILETRAIL_GUI_TESTS`, so about 44 tests in 11 suites never run.
  The command in `CLAUDE.md`, `swift test --filter GUITests`, misses `RealDiskImageTests`,
  `DiskImageMounterHandOffTests` and possibly the suites in `FirstClickGateTests.swift` and
  `ListScrollExtentTests.swift`.
- Steps: run every GUI-gated test once by hand (find them with `grep -rn FILETRAIL_GUI_TESTS Tests`). Report
  which fail before changing anything; do not fix product code under this item. Then rename or tag the suites so
  one filter matches all of them, correct the command in `CLAUDE.md`, and add a GUI step to `release.sh` after the
  main CI step.
- Delete `Tests/FTAppKitTests/Navigation/NavigationGUITests.swift` (0 bytes).

Found by both audits. [Q1] decides the `release.sh` step. `RealDiskImageTests` is at
`Tests/FTAppKitTests/Navigation/OpeningDiskImagesTests.swift:199`. `DiskImageMounterHandOffTests`
(`Tests/FTFileSystemTests/DiskImages/DiskImageMounterHandOffTests.swift:12`) asserts nothing: give it an assertion
or delete it. Remove the "under the GUI lock" comments: no such lock exists.

### [x] 2.8. The disk-image self-tests run once, not in all four bundles

- Where: `DiskImageSelfTests` in `Tests/FTTestSupport/LargeFileTests.swift` (lines 14–92). `FTTestSupport` is linked
  into every test bundle, so the suite runs four times: 44 `hdiutil` cycles per run, and contention for the two
  slots per image kind slows the real disk tests.
- Fix: move the suite into `Tests/FTOperationsTests` (the main user of disk images). Rename the support file to
  say what remains in it.

Found by both audits. By the saved logs the suite costs about 27 s in each of the FTAppKitTests and
FTOperationsTests bundles.

### [x] 2.9. Paste stop and crash recovery are tested through the engine

[verified] [Q2]

- Facts: `Tests/FTOperationsTests/ExecGoldenTests.swift:18` (`engineSuites`) filters out `exec-crash` (14 cases)
  and `exec-stop` (7). Their only consumer feeds each recording back through `RecordedReplayEngine` and compares
  it with itself. Every recovery test hand-builds its journal entry. So nothing checks that what `executeReplace`
  writes at each stage is what `recoverEntry` expects.
- Do in this order:
  1. Stop: `SwiftExecEngine` already has `stopAfterEvent`; wire `exec-stop` through it.
  2. Crash: add a file-system wrapper for tests that throws a "process died" error at the Nth write call and
     leaves the disk as it is. Run a real Replace (copy and move, file and folder) through it at each journal
     stage, then run recovery on what is left, and assert that no data is lost and the journal is empty. Include
     the untested window "staged: true recorded, old item still at its final name"
     (`Recovery/CopyPasteRecovery.swift:255-260`).
  3. Only then try `exec-crash` through the engine with the same wrapper.
- Do not edit a recording to make it pass. For a recording that still cannot run through the engine after these
  steps, follow the answer to [Q2]. The recommendation: delete that file from `Tests/Golden` and drop it from
  `ExecHarness.executionSuites`, so that no golden is only compared with itself, and say in the commit message
  that the behaviour is covered by the new tests and those under `Tests/FTOperationsTests/Recovery/`. Do not
  delete any of those.
- Six tests in `ExecGoldenTests.swift` assert only facts about the JSON files (`suitesCoverWhatTheBriefAsks`,
  `undoSuiteCoversWhatTheBriefAsks`, `recordingsPinStandingAnswers`, `recordingsHoldTheWriteServiceEvents`,
  `recordingsCoverADiskWithoutATrash`, `batchRenameSuiteCoversWhatTheBriefAsks`; lines 61, 78, 103, 124, 141,
  257). Delete the ones that describe a deleted recording. Keep the others, each with a one-line comment saying
  that it guards the shape of the recordings, and rename them in Phase 10. Keep
  `replayedExecutionMatchesItsRecording` for the suites that do run through the engine.

### [x] 2.10. Tests that cannot fail are made to check something, or removed

Fix each so that breaking the behavior it
names makes it fail. If the behavior cannot be reached, delete the test and say so.
- FTOperationsTests: `Undo/UndoRealDiskTests.swift:38` (swallows a Trash refusal and returns);
  `Execution/CopyPasteExecutionRenameTests.swift:92` and `CopyPasteExecutionEdgeTests.swift:128` (need a second
  device, as `CopyPasteExecutionCutTests` uses); `Exec/SwiftAnalysisEngine.swift:65-80, 183-199` (call
  `CopyPasteReview.allConflictsChoices` instead of a copy of it); `WriteService/WriteServiceAnalysisTests.swift:84`;
  `WriteService/WriteServicePasteTests.swift:208`; `Coordinator/WriteCoordinatorQuitTests.swift:19-50, 81-88`;
  `Execution/CopyPasteExecutionMetadataTests.swift:62, 139`; `Execution/CopyPasteExecutionRealFSTests.swift:170`;
  `Execution/CopyPasteExecutionRenameTests.swift:342`; `LocalOperations/TrashOperationTests.swift:84-88`;
  `LocalOperations/RenameOperationTests.swift:59, 79, 251`; `Execution/PartialFileTests.swift:170`;
  `Replace/ConflictSafetyTests.swift:389`.
- FTAppKitTests: `Windows/KeysAndPressesTests.swift:167` (loop over zero buttons);
  `Sidebar/SidebarModelTests.swift:453`; `Menus/MenuCommandRouterTests.swift:252`;
  `Search/SearchSessionTests.swift:180`; `InfoPanel/InfoViewsTests.swift:391`;
  `Settings/ShortcutSettingsTests.swift:116`; `Content/CompactList/CompactListTests.swift:114`;
  `WriteOperations/QuitBackgroundWorkTests.swift:35` (walks the real `/System/Volumes/Data`, can return with no
  assertion, wall-clock bound: rewrite against a temp tree).
- FTFileSystemTests: `Icons/FileIconStoreTests.swift:222` [verified] waits for `cachedCount == 2` where three kinds
  are preloaded and always runs out its 5 s wait: wait for 3. Make the file's `waitUntil` (`:65`) record an issue on
  timeout, and the copies at `ThumbnailStoreTests.swift:56`, `FileThumbnailServiceTests.swift:167`,
  `FolderWatchStreamTests.swift:20`, `FdSearchProcessTests.swift:230`. `System/FileDragTests.swift:49-55` asserts on
  closures the test set.
- The six tests in `ExecGoldenTests.swift` that assert only on the JSON files are handled in 2.9.

### [x] 2.11. Waits that drop their result fail instead

`Tests/FTAppKitTests/Windows/ExplorerHarness.swift:87`,
`Selection/SelectionTestKit.swift:164`, `Sidebar/SidebarTests.swift:80`, `Sidebar/SidebarFavoriteDragTests.swift:57`.

### [x] 2.12. Tests stop leaving folders in the temp folder

`Tests/FTAppKitTests/WriteOperations/StandInTrash.swift:29`
(`filetrail-test-trash-<pid>`), `Selection/SelectionTestKit.swift:136` (`filetrail-selection-writes-*`, 15 call
sites), `Tests/FTFileSystemTests/System/FileDragTests.swift:98, 173, 233`. Afterwards, tell the user the old leftovers
in `$TMPDIR` can be deleted; do not delete them yourself.

### [x] 2.13. Static seams are restored even when a test throws

`Dialogs/DialogLookTests.swift:17`,
`Dialogs/GoToBoxTests.swift:55`, `Dialogs/MoveToBoxTests.swift:18`, `BatchRename/BatchRenameInWindowTests.swift:54`,
`Automation/AutomationStepsTests.swift:200`. Use `defer`. Same for `released.signal()` in
`Tests/FTOperationsTests/Recovery/PartialFileRecoveryTests.swift:98-107`.

### [x] 2.14. Wall-clock bounds become CPU-time bounds or gates

Use `CPUTime.measureThread` or a held gate:
`Tests/FTFoundationTests/CopyPaste/RetrySourcePathsTests.swift:29`, `BatchRename/BatchRenameTests.swift:543, 615`,
`Tests/FTFileSystemTests/FolderSize/FolderSizeJobsTests.swift:275, 561`, `FolderSizeCacheTests.swift:124`,
`Tests/FTOperationsTests/LocalOperations/EmptyTrashTests.swift:111`,
`Coordinator/WriteCoordinatorQuitTests.swift:100`, `Execution/CopyPasteExecutionEdgeTests.swift:54` (a 5 ms timer
decides the expected status; `CopyPasteExecutionTests.swift:106` shows the semaphore way),
`WriteService/WriteServiceAnalysisTests.swift:60-70, 125`. Then see whether the bundle reordering at
`scripts/ci.sh:250-260` is still needed.

### [x] 2.15. Exec goldens build each scenario's tree once

`Tests/FTOperationsTests/ExecGoldenTests.swift:21-59` builds
it three times with its disk image mounted; these are the slowest tests in the bundle.

---

## Phase 3. Reported bugs

Confirm each first (see "How much to trust each item"). Grouped by area; within a group, most harmful first.

**3A. Write engine** (paths are under `Sources/FTOperations` unless they say otherwise). Do 2.9 first.

### [x] 3A.1. "Could not read it" is not "it is gone"

- `captureFingerprint` (`Sources/FTOperations/Identity/CopyPasteFingerprint.swift` 49–56) returns `.missing` for
  any `lstat` error. Four sibling helpers refuse that (`isPathTaken`, `isGone`, `lstatUnlessMissing`,
  `UndoPlan.lookUp`). On an I/O or permission error or a network timeout this means:
  - `tryDeleteMovedSource` reports "Deleted by someone else meanwhile" for a source it could not read
    (`Execution/ExecutionMoves.swift` 92–96);
  - `holdsAnyOf`/`isAnyOf` treat an unreadable pasted item as no longer at risk, relaxing the "Replace would
    destroy another pasted item" guard (`CopyPasteFingerprint.swift` 233–234, 251);
  - `explainMissingFolder` says a folder "no longer exists" (`ExecutionNodes.swift` 565–569);
  - `recordAppMovedByCopy` records a move for an original it could not see (269–273).
- Fix: add a strict variant that returns missing only for `ENOENT`/`ENOTDIR` and throws otherwise. Use it at
  those four places, deciding each as the stricter, safer outcome: the source is not reported deleted (the item
  ends "couldn't be checked"), the Replace guard treats unreadable as still at risk, the message says the folder
  could not be read, no move is recorded. Leave `captureFingerprint` as it is everywhere else.
- Tests: with the fault-injecting `TestFileSystem` (`Tests/FTOperationsTests/Execution/NativePaste.swift`), one
  test per call site with `lstat` failing `EIO`.
- This is the write path: stop and ask if any existing test not about these four places has to change.

This changes what the person is told in those four cases, so build the app and tell the owner what changed.

### [x] 3A.2. A Stop just before a conflict question leaves the paste blocked with the write slot held

`CopyPasteExecution.swift:338`, `WriteServiceRuntime.swift:44`. `cancelOperation` removes the pending question and
stops the signal; if it runs after the last `isStopped` check but before `registerQuestion`, the question is
registered afterwards and nothing resolves it. *Fix:* re-check the signal right after registering and resolve the
question as stopped; or do the check and the registration under one lock.

### [x] 3A.3. A full disk does not stop a paste

No path treats `ENOSPC` as final: every remaining item is attempted
and fails one by one, and a partly copied ordinary folder is put in place (`ExecutionNodes.swift:137-151` discards
only moves and packages). *Fix:* the first `ENOSPC` ends the run with the rest "Not started". [Q3] covers a
free-space check before starting.

### [x] 3A.4. A file moved to another disk can lose extended attributes and still have its original deleted

`Sources/CFileTrail/copyfile.c:94` returns `COPYFILE_SKIP` for a refused xattr; `copyStillWhole`
(`ExecutionMoves.swift:78`) compares only kind, size and link target. Folders in the same situation keep their source
(`applyDirectoryMetadata` → `metadataNotCopied`). *Fix:* report skipped metadata for files the same way and keep the
source. Confirm with a real disk-image test (a FAT or ExFAT image refuses most xattrs) before changing anything.

### [x] 3A.5. A Replace that cannot finish leaves the staged item without its lock and read-only mode

`Replace/CopyPasteReplace.swift:190-191` strip them; `:230` leaves without restoring; recovery's `moveUnlocked`
(`Recovery/CopyPasteRecovery.swift:269`) re-reads flags from the already-unlocked item.

### [x] 3A.6. A failed undo of staging is swallowed

`undoStaging` is called with `try?` at
`CopyPasteReplace.swift:139, 155, 170, 175, 236`. If the item's old name was taken meanwhile it stays under the hidden
`.name.filetrail-xxxxxxxx` until the next launch and the error shown does not say so. *Fix:* surface it in the item's
error, naming where the item is.

### [x] 3A.7. Undo reports restrictions restored when it never tried

`Undo/UndoExecution.swift:582`:
`restored = trashPath.map { restoreRestrictions(...) } ?? true`. With no trash path the answer should be false, so the
"couldn't be put back" note appears.

### [x] 3A.8. Progress counts are not taken back when a Replace is undone or asked again

`CopyPasteReplace.swift:113`;
completed can exceed total.

### [x] 3A.9. A crash late in a cross-disk folder move leaves a silent duplicate

`ExecutionNodes.swift:172` removes
the journal entry before `removeMovedSources` runs at `:181`; before the rename, recovery tells the person
(`WriteRecovery.swift:280`). *Fix:* remove the entry after the sources are gone, or record a second stage.

### [x] 3A.10. The journal entry that guards a moved item's only copy is not flushed

`Journal/FileWriteJournal.swift:106`
documents no fsync as a speed trade-off; that reasoning does not cover the `moved: true` entry
(`CopyPasteReplace.swift:60`), written once per Replace. [Q4]

A question about an item with a negative device number is auto-skipped today; that goes away with 6.7.

**3B. Windows, tabs, quit** (paths are under `Sources/FTAppKit` unless they say otherwise)

### [x] 3B.1. ⌘Q is lost while the "stop the copy?" question from closing the last window is open

`App/AppDelegate.swift:356-365`: `applicationShouldTerminate` returns `.terminateLater`, `quit.quit()` returns
`.questionBroughtForward` (`App/QuitCoordinator.swift:60`), and that case never replies. *Fix:* track whether a
terminate reply is already owed. If none is, `.questionBroughtForward` must answer `false`. If one is (a second ⌘Q
during a quit already waiting), keep today's behavior; the comment above the method explains why.

### [ ] 3B.2. A window can end up with more than 25 tabs, and the extra ones are not saved

- Where: `ExplorerTabGroup.replaceTabs` (`Sources/FTAppKit/Windows/ExplorerTabGroup.swift`, line 571), reached from
  `ExplorerWindows.reconcile()` when the system tab bar moves a tab into a window. `saveSession` (line 644) writes
  `tabs.prefix(openTabsLimit)` and clamps the active index.
- What is wrong: New Tab, Open in Tab, Reopen, Duplicate and Merge check the limit (`hasRoomForTab`, `addTabs`,
  `mergeInto`); a tab dragged in by the system does not. The 26th tab lives but is dropped from the saved session,
  and if it is the active one the saved active index points at another tab.
- **Reproduce first** (this was found by reading, not by running): build the app, fill a window to 25 tabs, drag a
  tab in from a second window, quit, relaunch. If it does not reproduce, stop and tell the owner.
- Fix: in the reconcile path, when a window ends up over the limit, move each surplus tab that was just adopted
  into a new window of its own (the same route as the system's Move Tab to New Window, which
  `ExplorerTabWindow.moveTabToNewWindow` already handles) and show the existing `.tabLimit` notice
  (`ExplorerWindows.swift`, lines 51–55, 359). Afterwards `tabs.count <= openTabsLimit` holds everywhere, so
  remove the `prefix` and the clamp in `saveSession` and the `tabs.count > openTabsLimit` term at line 532; replace
  them with an assertion.
- Also: two comments still say 100 tabs (`MainWindowController.swift:135`, `ExplorerWindows.swift:50`); correct them.
- Tests: add a case to the tests that drive `reconcile()` (see `Tests/FTAppKitTests/Windows/`), using the
  `tabLimit` seam.
- Verify: the hand steps above; `scripts/ci.sh --scope FTAppKitTests`.

Found by both audits. [Q5] decides what happens to the surplus tabs; the fix above is the recommendation. If
AppKit lets the drop be refused before it lands, prefer that and keep the move to a new window as the fallback.

### [x] 3B.3. A restored window can come back off-screen

`Windows/ExplorerWindows.swift:24` (`ScreenGeometry.frame(for:)`)
applies stored x/y unchecked. *Fix:* if the frame does not intersect any screen's `visibleFrame` by a useful margin,
centre it on the main screen at its saved size (clamped). Confirm first whether AppKit already rescues it.

### [x] 3B.4. An item opened from another app is not selected when its folder's path is not canonical

`ExplorerWindows.swift:330` compares `tab.shownFolderPath` (still the spelling given) with `realpath(folder)`. Try
`open -a "File Trail" /tmp/x.txt` with no window open.

### [x] 3B.5. One list of the flags that mark a driven run

Two lists of "driven run" flags differ: `App/AppDelegate.swift:144` and `:167`. As a result `--snapshot` beside a
running File Trail hands over to it and quits. Make them one list. 5.10 later deletes `--snapshot` itself; the
single list stays.

### [x] 3B.6. Observers and constraints that pile up per tab

`Appearance/WindowActivity.swift:25-30` (the sidebar never
calls `stop()`), `Toolbar/ExplorerToolbar.swift:71` (`sheetObservers` never removed), `:407-411` (two more width
constraints on the shared search field each time the item is made). Follow the `isolated deinit` pattern used by
`WindowVisibilityMonitor`.

### [x] 3B.7. `window.acceptsMouseMovedEvents` is switched on by the path bar and never off

`PathBar/PathBarRowView.swift:119`.

**3C. Content, selection, folder sizes** (paths are under `Sources/FTAppKit` unless they say otherwise)

### [x] 3C.1. A size-sorted folder with more than 5,000 measured subfolders never settles

`FolderSizes/WindowFolderSizes.swift:72` (`reorder`), `:180` (`trimCache`), `:206` (`entry`), and
`Content/ContentPaneController.swift:1055`. Sorting reads every listed folder's size; entries evicted by the
5,000 cap are probed again, answered from the jobs' cache, re-inserted, which evicts another 10% and fires
`onChange`, which re-sorts. Up to 10 times a second, with rows jumping. Reproduce in a test before choosing the fix;
the likely one is that a read for sorting must not evict entries of the folder on screen.

### [x] 3C.2. A tab that lets go of its folder mid-rename stays "renaming"

`showNoFolder()`
(`ContentPaneController.swift:487`) does not reset `rowsCache`, `listFilter`, `hiddenItemCount` or `tags`; `show`,
`showError`, `showSearch` and `endSearch` do.

### [x] 3C.3. Quick Look keeps the last tab's content pane alive

`QuickLook/QuickLookController.swift:93`: `ended()`
clears `url` but not `sourceFrame`, whose closure holds the pane.

### [x] 3C.4. Quick Look zooms from the wrong rectangle in the List

`QuickLookController.swift:133` hard-codes
`row.minX + 8` and the standard density's icon size; the row uses `rowInset + rowPaddingInline` and the current
density (`Content/List/DetailsRowViews.swift:403-409`).

### [x] 3C.5. `cancel(jobId:)` marks a finished size job cancelled

`Sources/FTFileSystem/FolderSize/FolderSizeJobs.swift:516-519`.

**3D. Clipboard, drag, dialogs** (paths are under `Sources/FTAppKit`)

### [x] 3D.1. The pasting tab is not told when a paste drops missing items from the clipboard

`Clipboard/PasteFlow.swift:221` is the only `SharedClipboard.set(…, from:)` call without `tab.clipboardChanged()`;
`set` notifies only other tabs (`Windows/ExplorerWindows.swift:114`).

### [x] 3D.2. A tab opened during another window's operation offers write actions

`ContextMenus/ContextMenuCoordinator.swift:125`: `isWriteOperationLocked` is a pushed copy; use the live
`tab.isWriteLocked` as `Clipboard/TabClipboard.swift:288` does.

### [ ] 3D.3. A conflict alert whose answer is refused cannot be answered again

`CopyPaste/RuntimeConflictAlert.swift:216, 242` disables the buttons and discards `resolveConflict`'s result; the
review alert re-enables them (`CopyPastePresenters.swift:101`).

### [x] 3D.4. ⌘-period does not cancel the Rename sheet

`BatchRename/BatchRenameSheetView.swift:372` checks plain
Escape; everything else uses `KeyCode.isCancel`.

### [x] 3D.5. `pendingTreeSelectionPath` is not cleared after a cancelled or failed drop

`DragDrop/TabDragDrop.swift:613`; `duplicateFromMenu` clears it (`MainWindowController+Writes.swift:207-210`).

### [x] 3D.6. Statics that only grow

`TabDragDrop.swift:623` (`externalDropAnalyses`, a cancelled review leaves its
id), `Dialogs/GoToFolderBox.swift:31` (`lastPointers` keyed by window identity), and the static batch-rename
dictionary (`BatchRename/MainWindowController+BatchRename.swift:20`).

**3E. Sidebar, Settings, Info, Help** (paths are under `Sources/FTAppKit` unless they say otherwise)

### [x] 3E.1. Clicking a component's name in Acknowledgements does nothing

`Acknowledgements/AcknowledgementsWindowController.swift:273-274`: the labels sit above the summary and take the hit.

### [x] 3E.2. An older icon can overwrite a newer one in the Info panel

- Where: `loadOpenIcon` in `Sources/FTAppKit/InfoPanel/InfoPanelView.swift` (lines 638–646).
- What is wrong: the load handle is dropped, so a slow load for the previous selection can finish after the load
  for the current one and replace its icon.
- Fix: keep a generation number (or the requested path) and ignore a result that is not for the current request.
  Follow the pattern `SidebarModel` already uses for stale answers (`viewVersion`, request numbering).
- Tests: a test with two loads finishing in reverse order.

Found by both audits. `OpensWithPopupView.reload` (lines 415–425 of the same file) also shows the right pattern:
it checks which app the answer is for.

### [x] 3E.3. A tree row's folder icon that arrives late is never drawn

`Sidebar/SidebarCells.swift:248-254`; the
arrival callback ends in an empty method (`SidebarViewController+Input.swift:107`). Root cause:
`SidebarFolderIcons.shared` (`Sidebar/SidebarRowViews.swift:8-13`) makes its own `FileIconStore()` instead of using
`services.iconStore`, whose generic icons are preloaded.

### [x] 3E.4. Toggling hidden files while the tab has no folder leaves the tree in the old state

`Sidebar/SidebarModel.swift:586, 601-602`.

### [x] 3E.5. "Change…" on a favorite can replace a different favorite

`Settings/SettingsPages.swift:360-373` keeps an
index across the folder picker; track the favorite by path as the Open With list tracks by id (`:564-591`).

### [x] 3E.6. The colour panel outlives its swatch and then does nothing

`Settings/SettingsAppearance.swift:330-339`.

### [x] 3E.7. `InfoActions.host` is `unowned` and used after awaits

`InfoPanel/InfoActions.swift:10, 103, 147-158`;
`InfoController` guards the same hazard with `liveHost`.

### [x] 3E.8. Help says a double-click on a tree folder opens it; on an open folder it closes it

`Sources/FTFoundation/Help/HelpTopics.swift:15` vs `Sidebar/SidebarViewController+Input.swift:54-70`. Fix the text.

**3F. File system layer** (paths are under `Sources/FTFileSystem`)

### [x] 3F.1. A failed state write is never retried

`AppState/AppStateStore.swift:335-364`: `save()` clears
`unsavedFiles` even when `writeAtomically` failed, so `flush()` at quit writes nothing.

### [x] 3F.2. The 10 s timeout on setting a default app cannot fire early

`System/OpenWithCatalog.swift:221-236`: a
throwing task group waits for all children, and the system call ignores cancellation.

### [x] 3F.3. Path suggestions are empty for a typed symlink to a folder with another name

`Listing/ExplorerListing.swift:488-490`.

### [x] 3F.4. A failed reveal says "Command failed: open -R …" though no command runs

`System/SystemActions.swift:35-38`.

A listing that fails with `ESTALE` or `EDQUOT` says "Unknown system error -70" today; that is fixed by 6.4.

**3G. Text and rules** (paths are under `Sources/FTFoundation`)

### [x] 3G.1. A cut-and-paste is described as a copy when it ends

`CopyPaste/CopyPasteResultText.swift:76-78, 127, 155`
and `Clipboard/WriteEndNotices.swift:206`: neither receives the mode, so the sheet says "couldn't be copied" and the
toast "Copied 3 items". The review sheet says "Move". Pass the mode through.

### [x] 3G.2. A drag refused during an Undo or Redo says the items are "being copied"

`Clipboard/ClipboardTexts.swift:44-51` switches on raw strings with no `undo`/`redo` case. Switch on
`WriteOperationAction` instead.

### [ ] 3G.3. A Replace row says "Deletes" where the footer says "moved to the Trash"

`CopyPaste/CopyPasteReview.swift:494-504`.

### [x] 3G.4. Backspace in the list filter can leave a broken character

- Where: `eraseCharacter` in `Sources/FTFoundation/Selection/ListFilterTyping.swift` (lines 25–30).
- What is wrong: it removes one UTF-16 unit and rebuilds the string. If the query ends in a character outside the
  Basic Multilingual Plane (an emoji set through `set(_:)` from the search field), one Backspace leaves half a
  surrogate pair, which decodes to U+FFFD, and the filter matches nothing.
- Fix: remove the last `Character`. Check `Tests/Golden/list-filter.json`: the two rules differ only for such
  characters, so no case should change; if one does, edit it by hand.
- Same fault, same item: `BatchRename.text` in `Sources/FTFoundation/BatchRename/BatchRenameSaved.swift`
  (lines 4–10, 72) cuts at a UTF-16 count and can split a pair, while `limited` in
  `BatchRenameFieldRules.swift` never does. Use `limited` in both.
- Tests: one test each with a query and a preset name ending in an emoji.

Found by both audits.

### [x] 3G.5. The tree's context menu protects only the home Trash

`ContextMenu/ContextMenuRules.swift:203-207`;
`Paths.isTrashFolder` also covers other disks' Trash folders, and the write guard refuses them anyway.

### [x] 3G.6. A settings patch with one bad value is dropped whole

`Settings/SettingsValues.swift:31` decodes strictly
while `PreferencesSanitizer.apply` falls back per key.

### [x] 3G.7. `RGBA(hex:)` accepts a signed string

`Design/RGBA.swift:27`: "-12345" parses.

---

## Phase 4. Minimum macOS 26

Decision 2.

### [ ] 4.1. Raise the deployment target and remove the fallbacks

- `Package.swift` line 6: `platforms: [.macOS("26.0")]` (the string form works with tools version 6.0).
- `Resources/Info.plist`: `LSMinimumSystemVersion` to `26.0`. `README.md` line 131 and any other statement of
  "macOS 14 or later". `scripts/make-release-app.sh` and `scripts/build-app.sh`: any literal `14`.
- Availability checks to remove (all nine in `Sources/` except the last):
  - `Sources/FTAppKit/Appearance/GlassSurface.swift` lines 10, 31, 50, 54, 64 (macOS 26): the checks go, the glass
    path becomes the only path.
  - `Sources/FTAppKit/Toolbar/ExplorerToolbar.swift` lines 52, 182, 270 (macOS 15): keep the newer branch, delete
    the fallback (the remove-all/insert-all loop, the `button.isHidden` line).
  - **Keep** `Sources/FTAppKit/ContextMenus/OpenWithSubmenu.swift:98` (macOS 27).
- Then remove what only the pre-26 path used. Prove each by search before deleting: the opaque layer fill, border
  and shadow each glass surface kept for older systems (`MenuSurface.apply`, `Notifications/ToastViews.swift`
  lines 7–24, the pill in `Sidebar/SidebarViewController.swift` lines 505–527), the secondary-colour swap in
  `GlassSurface.text`, the `sheetRadius` fallback to `DesignTokens.radii.dialog`. Per the owner's standing
  decision, sheets, Go To and alerts with lists or fields stay opaque: do not turn those into glass.
- `toolbarWillAddItem`/`toolbarDidRemoveItem` (`ExplorerToolbar.swift` lines 165–171) were the only way the order
  was saved on macOS 14. Check whether the `itemIdentifiers` observation now covers every case; if so remove them,
  if unsure leave them.
- `scripts/build-app.sh` lines 71–75 restamp the SDK with `vtool` so the app gets the current look. After the
  change, build and run `vtool -show-build` on `.build/release/FileTrail`. Keep the restamp unless the binary
  already carries the right SDK version without it.
- Verify: full `scripts/ci.sh`; build the app; look at toasts, the progress card, a plain alert, the sidebar
  type-select pill and the toolbar. This changes who can run the app: tell the owner so the release notes can say it.

---

## Phase 5. Deletions

Each item: prove again (see the rule), delete the source, delete what goes with it, run the checks. Sizes are
approximate. Where an item lists many things, one commit per bullet is fine.

Leave the read-only test seams wherever a test uses one as its only way to observe something (`cachedSize`,
`jobCount`, `recordedCount`, `cachedCount`, `activeCount`, `queuedCount`, `watchedPaths`, `rowViewsShown`,
`sectionViews`, `cachedEntry`, `isTurning` and the like).

### [ ] 5.1. The collation table fallback (about 800 lines)

[Q6]

- Delete `Sources/FTFileSystem/Listing/CollationTable.swift` (689 lines); in `NameKeys.swift` the `.table` mode and
  `appendKey`/`appendASCII`/`decode` used only by it (lines 21–24, 42–115); in `Collation.swift`
  `compareNumericBase` and `foldingKnown` (lines 36–61).
- Proof: every production `NameKeys()` uses `.automatic` → `ICUCollator.shared`. `NameKeys(mode: .table)` has one
  caller, `Tests/FTFileSystemTests/Listing/ListingSortGoldenTests.swift:154`.
- Replacement for the case `ICUCollator.shared` is nil: compare pairwise with Foundation
  (`String.compare(_:options:[.numeric, .caseInsensitive, .diacriticInsensitive], locale:)`); slower, still correct.
- Goes with it: the test `sortsCoveredNamesAsTheGoldenFileSaysWithoutICU`. `listing-sort.json` stays; the ICU
  path is what passes it. Correct the doc comment in `ICUCollator.swift:5`.

### [ ] 5.2. The JavaScript regex emulation used only for the search highlight (666 lines)

[Q7]

Read decision 4 at the top first, and get the answer to [Q7].

- Delete `Sources/FTFoundation/Search/JSLegacyRegExp.swift`. Its only construction is in `highlightPattern`,
  `Sources/FTFileSystem/Search/SearchResults.swift` lines 158–173; consumers are `NameHighlight.swift:21`,
  `Sources/FTAppKit/Search/SearchSession.swift` lines 218, 227 and `Content/Search/ContentSearchDisplay.swift`
  lines 17, 28.
- Replace with `NSRegularExpression`: regex mode `NSRegularExpression(pattern: query, options: caseInsensitive)`;
  text mode a literal, case-insensitive `range(of:options:[.caseInsensitive, .literal])` search (not ICU full
  folding, so "ss" does not highlight "ß"); case-insensitive when the query has no capital letter, as now. A
  pattern ICU rejects shows no highlight, as an untranslatable pattern does today. Glob mode stays unhighlighted.
- `JSFirstMatch` and the pieces `JSRegExp.swift` shares with it stay if `JSRegExp` uses them; `JSRegExp.swift`
  itself is not touched (decision 4).
- Goes with it: `Tests/FTFoundationTests/Search/JSLegacyRegExpTests.swift` (whole file);
  `Tests/FTFileSystemTests/Search/HighlightModeTests.swift` (every test asserts a JavaScript quirk: rewrite as a
  few tests of the new behaviour); in `Tests/Golden/name-highlight.json` hand-edit the regex-mode cases that pin
  JavaScript-only behaviour (queries such as `foo\-bar`, `a]`, `^.`, `^.{2}`, `[🎉]`, `x{`, `\p{L}`, `\k`, `\8`,
  `[\w-]+`, `(?=a)*b`, `{2}`, `ſ`, `µ`, `k`); the `mapToLabel` half of that golden is unaffected. Check the
  highlight cases in `search-sort.json`.
- This only changes which characters are painted in a result name, never which files are found.

### [ ] 5.3. The toolbar layout engine the system toolbar replaced (about 200 lines, 270 of tests, 1 golden)

- Delete `Sources/FTFoundation/Layout/TopToolbarRow.swift` (87 lines). In `TopToolbarLayout.swift` delete
  `ToolbarCapsuleEdges`, `notOnACapsule`, `capsules`, `capsuleOverhang`, `rowMinWidth`, `overflowRoom`,
  `visibleOptionalCount`, `dropIndex`. The one production call is `ExplorerToolbar.swift:111`
  (`select(slots(items), optionalCount: items.count)`), which reduces to "drop separators that divide nothing":
  keep that as one small function and remove `TopToolbarSlot` if nothing else needs it.
- In `Sources/FTFoundation/Commands/ToolbarItems.swift` delete `isToolbarItemID`, `addTopItem`, `insertTopItem`,
  `moveTopItem`, `removeTopItem` (lines 43, 87–113). `sanitizeTopItems`, `paletteItems`, `isRequiredTopItem`,
  `defaultTopItems`, `definition` are live. Also `ToolbarItemKind` and `ToolbarItemDefinition.kind`, never read in
  Sources.
- Delete `CustomizePanelLayout` and `DesignTokens.customizePanel` (`ContextMenu/MenuLayout.swift` lines 94–121, 139).
- Then check which `ToolbarLayout` tokens in `Design/` were read only by the deleted code (`capsulePadding`,
  `edgedItemInset`, `overflowButtonWidth`, `titleMinWidth`, `searchMinWidth`, `searchWidth`) and delete those.
- Goes with it: `Tests/Golden/toolbar-layout.json` (647 KB),
  `Tests/FTFoundationTests/Layout/ToolbarLayoutGoldenTests.swift`, most of `TopToolbarLayoutTests.swift`, the
  add/move/remove cases in `ToolbarItemsTests.swift` and in `toolbar-sanitize.json` (hand edit; the sanitize
  cases stay).

### [ ] 5.4. Design tokens that are never drawn with, and the stylesheet comparison

Decision 1 makes the comparison itself obsolete.

- Delete `Tests/FTFoundationTests/Design/CSSTokenTests.swift` and `Tests/Golden/css-tokens.json`, and the second
  golden loader `Tests/FTFoundationTests/Design/GoldenFile.swift` (move `AccentPaletteTests` to the shared loader).
- Then delete every token with no reader outside its declaring file. Reported, to be re-proven one by one
  (short names such as `border` collide; also search for `Mirror(` and `\ThemePalette.` key paths in Sources):
  - `TabStripLayout`, `DesignTokens.tabStrip`, `Metrics.tabStrip` (`Design/Layouts.swift` 229–250).
  - `DesignTokens.sansFontStack`, `monoFontStack`, `toolbarScrimAlpha`; `Motion.reduced`, `Motion.flashSlow`;
    `ExplorerLayout.toolbarInsetWithoutTree`; `SidebarLayout.foldersTitleContentHeight`,
    `dragHoverExpandMilliseconds`; `DesignTokens.spacing`/`Metrics.spacing` if unread.
  - `ThemePalette`: bgPanel, borderStrong, contextMenuDisabled, contextMenuIcon, contextMenuSubmenuArrow,
    dialogEdge, getInfoActionBg, getInfoActionIcon, getInfoActionText, getInfoHeaderText, getInfoHeroName,
    getInfoMetaLabel, getInfoMetaSeparator, getInfoPanelBg, getInfoPanelBorder, helpMuted, pushButtonEdge,
    scrollThumb, scrollThumbHover, searchBorder, searchIcon, searchShadow, searchSurface, searchText,
    segmentedSelectedBg, segmentedSelectedShadow, segmentedTrackBg, settingsSwitchOff, shadowSm, toolbarBorder,
    toolbarNavIcon, toolbarNavIconActive, toolbarToggleActiveBg, toolbarToggleBg, toolbarToggleOnBg,
    toolbarToggleOnHoverBg.
  - `AccentPalette`: solidDark, hoverBg, pillBg, focusBorder, activeBg, heroIconBg, pathCrumbHover,
    searchPillBorder, locationRing, ringSoft, and the `Profile` alphas that feed only them.
  - `SearchLayout`: segmentShadowOffsetY/Blur/Alpha, capsuleActiveBorderWidth/Alpha, optionsButtonHeight,
    optionsButtonPadding, optionsChevronSize, optionsChevronStrokeWidth, optionsChevronGap, optionsMenuMargin.
  - CSS serialisation with no production caller: `RGBA.init?(css:)`, `RGBA.cssString`, `formatCSSNumber`,
    `ShadowLayer.cssString`, `[ShadowLayer].cssString`; `RGBA.hexString` if then unused.
- Goes with it: the `tabStrip` and `toolbarInsetWithoutTree` parts of `MetricsTests.swift`; in
  `AccentPaletteTests.swift` and `accent.json` the test reads only the tokens that remain (drop the dead keys
  from the comparison, not necessarily from the 1.5 MB file).

Also reported unread by the second audit (prove each): members of `SidebarLayout`, `ExplorerLayout` and
`SettingsMetrics`, and eleven `SearchLayout` fields at `Search/SearchLayout.swift:26`.

### [ ] 5.5. The second tooltip system (about 330 lines, 250 of tests)

- Delete `Sources/FTAppKit/Tooltips/TooltipController.swift` and `TooltipScheduler.swift`; `TitleTooltips` in
  `Sources/FTFoundation/Formatting/Tooltips.swift` (keep `toolbarItemLabel`/`toolbarItemTooltip` if used); the
  `TooltipAnchor` protocol and its two conformers' hooks (`Toolbar/ToolbarButton.swift` lines 11, 37–43, 105–125,
  359–366; `InfoPanel/InfoControls.swift` lines 99–171); the calls in `Toolbar/WindowEventRouting.swift` (36, 41)
  and `Toolbar/SystemMenu.swift` (268).
- Replace with the system's `toolTip` on both controls (the rest of the app already uses it in 57 places). Keep
  the rule that a button is quiet while its menu is open: set `toolTip = nil` while `menuOpen`, restore after.
- Goes with it: `Tests/FTAppKitTests/Tooltips/TooltipSchedulerTests.swift`; the placement and delay parts of
  `Tests/FTFoundationTests/Formatting/TooltipsTests.swift`; tests that read `button.tooltip` read `toolTip`;
  the `tooltip` entries in `tools/capture/elements.json`.

### [ ] 5.6. Pure logic with no production caller (about 550 lines)

All in `Sources/FTFoundation` unless a path says otherwise. Delete with the named tests.

- `Selection/FocusedEditTarget.swift` (whole), `Selection/ExplorerPaneFocus.swift` (whole),
  `Selection/PathIndex.swift` (whole). Tests: the matching cases in `SelectionSupportTests.swift` and
  `ContentSelectionTests.swift`.
- `Sidebar/TreeView.swift`: everything but `enum Key` (move `Key` beside `SidebarKeyboard`);
  `Formatting/Typeahead.swift`: `TypeaheadTreeNode`, `findTreeMatch`, `visiblePaths` (keep `isCharacterKey`);
  `Selection/SelectionNavigation.swift`: `flattenVisibleTreePaths`. Tests: `Sidebar/TreeViewTests.swift`, cases in
  `ListFilterTests.swift` and `SelectionNavigationTests.swift`.
- `GridLayout/Virtualization.swift`: `VirtualRange`, `range`, `chunkIntoRows`, `columnMajorRows`; fold
  `rowsPerColumn` into `FlowListLayout`. Tests: cases in `FlowListLayoutTests.swift`; in
  `flow-list-layout.json` remove by hand the cases for `range`, `columnMajor`, `chunk` (167 of 862).
- `Commands/ShortcutTargets.swift`: `openSelectionPaths`, `editSelectionPaths`, `rootTreeTargetPath`,
  `RootTreeInput`, private `selectionPaths` (only `openInTerminalPaths` is called). Tests: most of
  `ShortcutTargetsTests.swift`; the matching part of `command-availability.json` if it is keyed.
- `Commands/TreeFocusBuckets.swift`: `RawExplorerShortcutID` has 47 cases; only about eight are reached
  (cut, copy, paste, move, rename, duplicate, newFolder, trash, copyPath). Reduce it to those.
  `ResolvedShortcuts.shortcutOrder` (never read).
- Uncalled validators: `RendererCommand.isRendererCommandType`, `ShortcutCommands.isCommandID`,
  `ApplicationMenuState.init(disabledCommandNames:…)` (one test).
- `Contracts/Limits.swift`: `maxPathsPerRequest` (one test asserting the constant equals itself); move
  `maxFileDragImages` to its one user and delete the file.
- Small members, test-only: `SizeText.comparison`/`SizeComparison`/`relativeDuration`/`hint`;
  `DateText.shortDateTime`; `SettingsTab.read(fromURL:)`/`urlFragment` (and `SettingsTabTests.swift`);
  `DirectoryListingDiff.isFolderGone`/`sameEntries`/`sameDetailsByPath`; `Favorites.isTrashListingRefused`;
  `GoMenuPlaceCommand.isPlaceCommand`; `DragRules.isRealDirectory`; `ClipboardRules.pasteRequest`/
  `clearedAfterSuccessfulPaste`/`PasteRequest`; `SpringHold.warningPath`; `AlertButtons.defaultIndex`;
  `PathbarFolderMenuModel.jump`; `VisitedFolders.parse`; `ClipboardIcon` and `ClipboardSummary.icon` (generic
  name: confirm by compiling).
- Small members, no caller at all: `DetailsSorting.isActive`, `InlineRenameRules.selectsWholeName`,
  `ClipboardSummary.countText`, `ClipboardMarks.flashing`/`flashes`, `SidebarKeyboard.typeaheadResetMilliseconds`,
  `BatchRename.tokenPattern`, `JSText.utf8Length`/`utf16Length`, `JSONNode.isNull`,
  `AppPreferenceLimits.favoriteIconLabel`, `HighlightRange.nsRange`, `JSRegExp.firstMatch(in:range:)`,
  `Module.swift` in FTFoundation, FTFileSystem and FTOperations.
- `BatchRenameSheetText.describeSettingsError` (lines 246–268) strips a prefix the native engine never produces;
  it always returns its input. Delete it and the one test case with the old wording
  (`BatchRenameSheetTextTests.swift:65`).
- **Do not delete `NavigationHistory.mapPaths`** in this item. Its comment says a rename "takes the history
  along" and nothing calls it; that may be a missing behaviour. See [Q8].
- Unread constants: in `Clipboard/ClipboardLayout.swift` `Mark.badgeSize`, `badgeIconSize`, `badgeOffset`,
  `badgeBorderWidth`, `badgeBorderAlpha`, `Mark.flashMs`, `countWeight`, `Drop.treeHaloWidth`, `treeHaloAlpha`,
  `Drop.invalidTreeEdgeAlpha`, and in `DragTimings` `tabHoverSwitchMs`, `ownDropWaitMs`, `ownDragStaleAfterMs`,
  `ownDragOverQuietMs`, `dragAwayMs`, `externalDragGoneMs` (a private copy in `TabDragDrop.swift:62` is the one
  used), `externalDragCheckMs`; in `ContextMenu/Toasts.swift` `ShowDelays.loadingFolderMs`, `loadingTreeMs`,
  `pathBarMenuMs`, `spinnerMs`, `searchStopMs` (and the one test asserting their values); in
  `ContextMenu/MenuLayout.swift` `submenuMinWidth`, `rowPaddingLeading`, `checkColumn`, `shortcutGap`,
  `viewportMargin`, `historyMaxWidth`; `InfoMetrics.folderMenuMaxHeight`;
  `SelectionLayout.FilterPill.valueWeight`. Several views read constants through an alias
  (`let layout = X.self; layout.name`): search for the member name alone, not only the qualified name.

Also, from the second audit (prove each the same way):

- `PathText.segments` and `PathSegment`.
- `Clipboard/InternalDragAndDrop.swift:92, 113, 162, 182`: the members at those lines that nothing in Sources calls.
- `Commands/ShortcutParsing.swift:40-41, 50, 131`: `constructor` and `__proto__` are accepted as modifier names;
  remove them.
- In `Sidebar/TreeView.swift`, "everything but `enum Key`" means `flatten`, `keyboardAction`, `TreeKeyboardAction`
  and `FlattenedTreeNode`.
- `AppClock.isFrozen` goes in 5.12 with the geometry dump; `AppClock` itself stays.

### [ ] 5.7. Dead code in the file-system module (about 400 lines)

- `Sources/FTFileSystem/AppState/WindowBoundsRecorder.swift` (whole) and its test file; move
  `saveDelayMilliseconds = 160` to `ExplorerWindowController` (line 113).
- `Listing/Timing.swift` (whole) and `Logging/WithTiming.swift` (whole), with their tests in
  `ResponseCacheTests.swift` (339, 344) and `AppLoggerTests.swift` (189–204), and the `FILETRAIL_DEBUG_TIMINGS`
  switch if nothing else reads it.
- `AppLogger.readAppLogFile`; `AppLogger.write(level:namespace:…)`/`log(_:_:)`/`LogArg.error` if still uncalled.
- `NativeFolderSize.itemSize` (lines 109–129); `NativeFolderSize`'s own waiting queue (`waiting`, `Deferred`,
  `Waiting`, lines 24–53, 66–68, 92–96): `FolderSizeJobs` is its only caller and never calls while a walk is
  active. Tests: `NativeFolderSizeTests.swift` 544–575. Read the reasoning in the code before deleting; if you
  cannot convince yourself the queue is unreachable, leave it and note it.
- `SystemActions.openFullDiskAccessSettings`/`fullDiskAccessSettingsURL` — or better, keep them and make
  `MainWindowController.swift:1656` call them instead of hard-coding the same URL. `SystemActions.editInTextEditor`.
- `VolumePaths.isOnSameVolume`; `DirectoryService.resolvePath`, `ExplorerListing.resolvePathTarget`,
  `ResolvedPath` (tests: `ExplorerServiceTests.swift` 360–368 and one section of `FixtureGoldenTests`);
  `VolumeListing.listMounts`/`MountPoint` (duplicate of `MountTable.list`); `ResponseCache.sizes`/`Sizes`;
  `FolderSizeJobs.clearJobs`; `FdSearchRuntime.results(for:)` (tests in `FdSearchRuntimeTests`/`FdSearchProcessTests`);
  `FdProcess.processIdentifier`.
- `Sources/CFileTrail/CFileTrail.c` and `ft_c_version` in `include/CFileTrail.h` (if SwiftPM needs the umbrella
  header, keep the header and remove only the function).
- `FdBinary`: the `arch` parameter and guard in `resolveBundledPath`, the `x86_64` branch of
  `currentArchitecture`, the "Intel" branch in `AboutInfo/BuildInfo.swift` (33–37), and `Locations.resources`
  (looks for a path the build never creates). `FdBinary.archiveSHA256` is shown nowhere: delete it and the
  manifest comparison in `FdBinaryTests.swift` (see 5.10 for the manifest).
- Leave the read-only test seams (`cachedSize`, `jobCount`, `recordedCount`, `cachedCount`, `activeCount`,
  `queuedCount`, `watchedPaths`).

Also, from the second audit: `FolderSizeJobs.clearCache`, `DragPasteboard.changeCount`,
`FileIconStore.lookup(_ entry:)`, `VolumeWatcher.isScheduled`, each only if no test needs it as its one way to
observe something.

### [ ] 5.8. Dead code in the write engine (about 280 lines): proceed carefully

Nothing here changes what the app does to files; each row was proven unreachable from the app. Do them one at a
time and run `scripts/ci.sh --scope FTOperationsTests` after each.

- `WriteJournalEntry.isReplace` (`Journal/WriteJournal.swift` 90–93).
- `WriteCoordinator.whenIdle` (`Coordinator/WriteCoordinator.swift` 180–187; keep `idleWaiters`, used by
  `idleOrTimedOut`); tests `WriteCoordinatorQuitTests.swift` 135, 140, 280.
- `sendToEachWindow` (`WriteCoordinatorWindows.swift` 130–144); one test at `WriteCoordinatorWindowsTests.swift:256`.
- `pathExists` (`Identity/CopyPasteFingerprint.swift` 280–282); two tests.
- `FolderMetadata.apply` (`Native/NativeCopy.swift` 98–124): production uses `applyDirectoryMetadata`
  (`ExecutionNodes.swift` 472–500); tests `NativeCopyTests.swift` 123–150.
- The wrapper `resolveKeepBothDestinationPath` (`Analysis/AnalysisFileSystem.swift` 84–92) and then
  `CopyPasteNames.resolveKeepBothDestinationPath` (two tests); `resolveDuplicateName` and `keep-both-names.json` stay.
- `NativeError.cocoaCode`, `errnum`, `syscall`, `dest` if unread in Sources (only `.path` is read).
- Analysis warnings and thresholds: nothing outside FTOperations reads `.warnings`
  (`CopyPasteAnalysis.swift` 4–16, 87, 285–298; `WriteServiceTypes.swift` 25–28, 87–95, 199; `WriteService.swift`
  17, 25, 33, 75, 85). The `warnings` key is in `analysis-*.json`: make the golden comparison ignore it rather
  than editing three large files.
- `disposition`, `.blocked`, `summary.blockedCount`: set in four places, never read, `.blocked` never produced.
  Same golden treatment.
- The journal and recovery branches for files only the earlier app wrote: `ReplaceJournalEntry.hasKind`
  (`WriteJournal.swift` 9–11, 23, 26, 113–115, 167–170, 176) and the "part inside a hidden folder" branch
  (`Recovery/CopyPasteRecovery.swift` 140–144), with the comments at `WriteJournal.swift:7` and
  `WriteRecovery.swift` 101–102. **First** run `git log -S'"replace"' --all -- Sources/FTOperations/Journal` and
  check each release tag (`git tag`) to confirm no native release ever wrote `"kind":"replace"`; if one did,
  skip this row. Keep "unknown kind → entry ignored" and the tolerance of unknown keys. Tests:
  `WriteRecoveryTests.swift` 379–450, `CopyPasteRecoveryTests.swift` 86–93 and the cases using `legacyEntry`.
- In `Sources/FTFoundation/Preferences/AppState.swift`: `legacyWindowID` and the read of the top-level `"window"`
  key (61–62, 83–90). **Keep** a fallback for a file that has `preferences` and no `windows` (hand-edited files,
  fixtures); check `tools/fixtures` and the automation scenarios for such files first. **Keep** the `density`
  migration from the `compact*` keys (`PreferencesSanitizer.swift` 51–57): native releases v0.8 to v0.15 wrote them.

Also, from the second audit:

- `RecoveryLogger.system`; the `resolveSingleNodeWithAction` overload without `reservedPaths`;
  `UndoHistory.entries`; `.queued`, never produced, beside `.blocked` (`WriteService/WriteServiceTypes.swift:27, 35, 176`).
- The hand-written `Codable` on `UndoStep`, `UndoLog`, `ItemStamp` and `BatchRenamedItem`
  (`Identity/UndoLog.swift:131`): the history is kept in memory only.
- The two tests about `.asar` files (`Tests/FTOperationsTests/WriteService/WriteServiceAnalysisTests.swift:335-348`,
  `WriteServicePasteTests.swift:292-306`).
- `FolderMetadata.apply`: before deleting its tests, check that `applyDirectoryMetadata` has tests of its own. If
  it has not, point those tests at it instead of deleting them.
- The journal row above is settled by the standing decision that there is no upgrade path from the earlier app;
  its proof step still applies.
- `WriteOperationEventCheck` is removed in 6.7, not here.

### [ ] 5.9. Dead code in the app layer (about 450 lines)

In `Sources/FTAppKit` unless a path says otherwise.

- Windows and content: `Content/LabelCell.swift` (whole); `ContentPaneController.selectedItems` (657);
  `ItemGridPane+Input.isRenaming` (303); `TabViewState.listingOutOfDate` (`ExplorerTabs.swift:58`);
  `MainWindowController.convenience init(folder:)` (465–471), `goToPlace` (1988–1991), `showAsIcons`,
  `showAsList`, `validateMenuItem` and the `NSMenuItemValidation` conformance (147, 1998–2000, 2065–2079; one
  test at `ReleasedFolderTests.swift:115` builds a menu item to call it — delete that part), `onSearchRequested`
  (313, 1617), `windowDidResignKey` (empty, 2116–2118), the one-line forwarders at 1428, 1599, 1621, 1625, the
  duplicate `commandEntries(_:)` (1295 vs 1803) and `selectedFolder` (1631 vs `selectedContentFolder` 1772);
  `ExplorerSearchState`/`searchState` (`ExplorerWindowContext.swift` 30–36, 188; `MainWindowController.swift`
  2500–2505); `ExplorerWindowChange.treeRoot`; `ExplorerServices.folderWatches`/`.volumeWatcher` (set, never
  read); `ContentViewRegistry.register`; the unused `DetailsHeaderView.configure(fitted:sortBy:…)` overload;
  `WorkspaceCell.contentTop`; `explorerWindowsIfStarted`; the never-nil `??` fallbacks at `AppDelegate.swift` 70, 195.
- The interim rename path (`MainWindowController.swift` 1543 else-branch, 1566–1596 `interimRename`/`renameOnDisk`,
  1604–1610 `reloadSelecting`): it renames with `FileManager.moveItem`, with no journal and no Undo, and runs only
  when `writeActions` is nil, which the app never is after launch. Before deleting, find whether any test reaches
  it (candidates: `IconsTests`, `CompactListTests`, `LeadStaysInViewTests`, `GridCarryOverTests`); give such tests
  an injected `renameItem` instead.
- Move to test support (production-dead, used by tests as fakes): `App/ExplorerWindowHost.swift`'s
  `ExplorerWindowList` (59–95). Delete with their tests: `ExplorerTabs.moveTab`, `ExplorerWindowOrder.byWindow`.
- Chrome: `BoxShadowView` (`Appearance/BoxShadow.swift` 63–88); `RGBA.nsColor` (`Appearance/ThemeColors.swift`
  12–14); `SidebarModel.volumeGone` (678–685); `SidebarViewController.restoreSelection`; the do-nothing chain
  `sidebarList(_:rowArrived:)`/`onIconArrived`; the empty `viewDidLayout` override; `ProgressCardModel.showNow`
  and the unused `wasNil`; `typealias PlainResultNotice` (one test); `ToolbarGlyph.drawCheck` and the icon cases
  `.overflow`, `.stop`, `.sortAsc`, `.sortDesc`, `.clear` (and the lines of `ToolbarIconTests.swift` that list them).
- Sheets and panels: `SettingsStyle.secondarySmall`; `SettingsMetrics.cardEdgeWidth`, `iconGridBorder`,
  `iconGridMargin`, `iconGridOffset`, `menuCheckSize`; `CopyPasteSheetView.footerHasNote`; `KeyCode.period` and
  `DialogTitlebarVeil.tabBarRoom` (`Dialogs/DialogScrim.swift`); `BatchRenameSheetView.choosePreset(titled:)`;
  `ReviewSheetModel.verb`; `BatchRenameTextField.onFocus`; parameters no caller passes
  (`TextPromptAccessory.init(placeholder:)`, `GoToFolderBox.init(canForget:)`, `InWindowAlerts.notice(onClose:)`,
  `CopyPasteDialogs.present(onWindowClose:)`); `WindowWriteActions.observe` (48–51);
  `ExplorerWriteSession.progressEvent` (written, never read); `InfoPanelView.updateFolderSize` and
  `InfoPanelContentView.updateFolderSize`; the no-op lines at `InfoPanelView.swift` 910–913, 935;
  `HelpPage` `allShortcutRows`, `allRows`, `introText`, `titleText` and the stored `kind` (459–462, 88–89,
  143–144); `AcknowledgementsView.introTexts`/`AcknowledgementList.introTexts`; `TextLinkView.underlinesOnHover`
  (constant true); `InfoPanelDisplay.Item.hasOpenWith` (always true: remove it and the unreachable branches of
  `SplitOpenButton`); `WindowWriteActions.batchRenameFolders` (30–32, 632–633; production reads the map in
  `MainWindowController+BatchRename.swift`; one test at `LocalWriteActionsTests.swift` 654–655).
- Leave the read-only test seams (`rowViewsShown`, `sectionViews`, `cachedEntry`, `settingsWindow` and the other
  page-window accessors, `suggestionsAreShown`, `isTurning`, `visibleHeight`, `rowKeys`, `titleView`).

Also, from the second audit:

- `ExplorerWindows.explorerWindowID(ofTab:)`; the `moving` set in `Windows/ExplorerTabGroup.swift:24`; the unused
  `@objc` methods beside `validateMenuItem`.
- `FlushTextField` and its cell (they override nothing).
- The unreachable `.cut`, `.copy` and `.paste` cases in `performContextFileOperation`
  (`MainWindowController+Writes.swift:170`); `paste(into:)` (`WindowWriteActions.swift:81`); `AlertNoticePresenter`;
  the `throws` on `rename`, `newFolder`, `trash`, `deleteImmediately` and `emptyTrash`, which throw nothing.
- `TreeKey.shortcutEvent`; `SidebarListView.index(ofRow:)`; `pressEvent`.
- `WindowTabsRequests`, `PreferenceChangeReceiver` and the `log` hooks go in 6.1; `SearchSession.elapsedMilliseconds`
  goes in 6.12.

### [ ] 5.10. Tooling with no caller

- Delete `scripts/hands-on-setup.sh` (no reference anywhere).
- Delete `tools/fixtures/disk-images.sh`; its own header says the tests clone none of its images. Remove
  `tools/fixtures/README.md` lines 9–10 and the stale comments at `Tests/FTOperationsTests/ExecGoldenTests.swift:12`,
  `Tests/FTTestSupport/ExecBatchRename.swift:107`, `ExecPlaces.swift:178`, `DiskImage.swift:38`,
  `DiskImageSlots.swift` 56–63. `ExecDiskImages.isAvailable` only checks a format name, so the `runnable` filter
  in `ExecGoldenTests` is a no-op: remove the filter. First confirm `DiskImageSlots.lockDirectory` creates its own
  directory.
- Delete `tools/acknowledgements/` (a generator for a list of one, run by nothing). `Resources/Acknowledgements/`
  (`index.json`, `fd.txt`) stays and is kept by hand; `AboutInfoTests.swift:90` already checks the version.
- `scripts/build-app.sh` lines 79–80 copy `Resources/fd/manifest.json` and `Resources/fd/licenses/` (including
  fd's 28 KB `README.md`) into the app, where nothing reads them. Stop copying them. The licence text the app
  shows is `Resources/Acknowledgements/fd.txt`; both fd licences must stay reachable in the app, so check that
  `fd.txt` holds both (MIT and Apache) before removing the copy. Then delete `Resources/fd/manifest.json` and
  `Resources/fd/licenses/README.md`; record the checked-in binary's SHA-256 in a comment beside
  `FdBinary.manifest` and add a test that the binary matches it.
- `--snapshot` (`Sources/FTAppKit/Debug/Benchmark.swift` 191–201; `AppDelegate.swift` 81, 131, 168): no caller in
  scripts, tools or docs. Delete it and its mention in `Tests/FTAppKitTests/Automation/ScenarioTests.swift:79`.
  Leave `--bench`, `--bench-launch`, `--bench-scroll` and `tools/bench` alone (see 11.4).
- `FILETRAIL_TIMING` (`MainWindowController.swift:203`) with `NavigationTiming`: no user in scripts, tools or docs.
  Ask the owner (one line) whether it is still used by hand; delete if not.
- `Tests/FTFoundationTests/SmokeTests.swift` (an empty test); `Tests/FTFileSystemTests/Listing/JSONValue.swift`
  (a second `JSONValue` beside the one in `FTTestSupport/ExecJSON.swift`): use the shared one.

[Q9] covers `hands-on-setup.sh`, `FILETRAIL_TIMING` and `tools/acknowledgements`: get the answer before deleting
those three. If a script stays, fix what is wrong with it instead: `hands-on-setup.sh --clean` always removes the
default folder, not the one given; `tools/acknowledgements/gen.sh --check` is called by nothing, so stale licence
text can ship, and `scripts/release.sh` should call it. `Resources/fd/manifest.json:7` names
`vendor/fd/darwin-arm64/fd`, a path that does not exist.

### [ ] 5.11. VoiceOver-only code in the sidebar (about 190 lines)

- Delete `Sources/FTAppKit/Sidebar/SidebarAccessibility.swift`; `SidebarListItem.accessibilityRow`
  (`SidebarListView.swift` 32–39); the five accessibility overrides (79–104); the `rowCountChanged` post (391);
  `announceChanges` (423–434); the `SidebarAccessibleCell` conformances (`SidebarCells.swift` 92–93, 456–457);
  `sidebarAccessibilityParent` (`SidebarRowViews.swift` 143, 231, 362–368; `SidebarCells.swift` 510).
- Test: `rowsTellVoiceOverTheirStateAndTheListsHaveNames` in `SidebarRowPressesTests.swift` (318–358).
- **Keep** every `setAccessibilityIdentifier` and every `accessibilityPerformPress()` override in the app: the
  tests and the screenshot tool find and press views through them. Also remove
  `BatchRenameSheetText.accessibilityText` and its `becomes`/`notRenamed` strings only if their two production
  callers serve VoiceOver alone; otherwise leave them.

Found by both audits, and settled by the standing decision that VoiceOver is not supported. Check first that the
automation runner and `ElementFinder` do not find or press sidebar rows through these overrides; keep whatever
they use.

### [ ] 5.12. What exists only to compare this app with the earlier one (decision 1)

All of `Sources/FTAppKit/Automation` is `#if DEBUG` and does not ship; these are the parts with no remaining use,
and the pieces of release code kept alive for them.

- `tools/capture/elements.json`: each of its 376 entries has an `"electron"` half that Swift does not read, except
  `electron.textAttribute == "aria-label"` (`Automation/AutomationElements.swift` 27–28). Reduce each entry to its
  Swift identifier plus a boolean `labelled`; drop the long comparison comment; update `tools/capture/README.md`
  and the reader. Do not drop a name used by `tools/capture/readme/*.json` or by a test.
- `Automation/GeometryDump.swift`: no scene has a `geometry` step. Delete the dump format and the `geometry` step,
  `GeometryDumpTests`, and `AppClock.isFrozen` if then unused. `ElementFinder.shows`/`text(of:)` call
  `GeometryDump.text`/`frame(of:)`: keep those two helpers (move them into `ElementFinder`).
- With the dump gone, the `TextStyleSource` protocol (`Toolbar/WindowEventRouting.swift` 4–8) and its 27 one-line
  conformers have one reader left, a test helper (`Tests/FTAppKitTests/InfoPanel/InfoViewsTests.swift:18`). Remove
  the protocol and conformances if that helper can read the view directly; also `.reportedColor`
  (`Appearance/ThemedViews.swift` 182–186, 234).
- Scenario steps no checked-in scene uses and that only their own tests exercise: decide per step by searching
  `tools/capture/readme` and `Tests`. Reported unused by scenes: `geometry`, `pick`, `contextMenu`, `drag`,
  `dragFiles`, `sheetButton`, `newWindow`, `fs`, `expect`, and the file steps (`create`, `write`, `rename`,
  `delete`, `chmod`, `lock`, `touch`, with `AutomationFileOps.swift`). Delete a step only when neither a scene nor
  a test outside `Tests/FTAppKitTests/Automation` needs it. **Keep** `MouseEvents`, `KeyEvents`, `ElementFinder`,
  `AutomationDraggingInfo`/`AutomationDrag`: many tests press things through them.
- `AutomationPrefs.originalKeys` and the message "is not a preference of the original"; `AutomationReport.side`.
- Invisible views in release builds that exist only as scenario tags: six `SidebarTagView`s per sidebar row and
  `stateTag` in the header button (`Sidebar/SidebarCells.swift` 5–11, 107–112, 136–146, 310–320, 415–417, 498,
  538–539, 552–553, 563); `AllConflictsSegment` (`CopyPaste/CopyPasteControls.swift` 180–223);
  `BatchRenameSegment`/`BatchRenameSelectedMark` (`BatchRename/BatchRenameControls.swift` 471–522); `headerBox`;
  `RowValueBox`, `SplitMainPart`, `SplitChevronPart` (`InfoPanel/InfoPanelView.swift` 191–223); the hidden text in
  `InfoRow/InfoRowView.swift` 45–46. For each: delete if no scene and no test reads it; otherwise leave it.
- Debug-seam plumbing compiled into release: `SidebarListView.fileDropURLs`, `SidebarFileDrops.dropURLs`, the
  `#else return false` branch in `DragDrop/TabDragHookups.swift` (29–35, 54–56),
  `ContextMenuResponder.contextMenu(openedSubmenu:)`, `AppMenuPresenter.intercept` (called for every window event,
  returns false in release), `AppMenu.onItemsChange`, `AppMenuItem.rowIdentifier`,
  `SidebarViewController.setSection`. Put each under `#if DEBUG` or delete it.
- The `theme` and `accent` automation preferences are registered twice with different bodies
  (`App/AppDelegate.swift` 310–325 and `Layout/AutomationLayoutPrefs.swift`); keep one.
  `Search/AutomationSearchPrefs.swift` (none of its 11 keys is used by any scene) and the two unused keys of
  `InfoPanel/AutomationInfoPrefs.swift` (keep `propertiesOpen`).
- Verify: `scripts/readme-screenshots.sh` still produces the nine screenshots. Do not commit regenerated PNGs
  unless they differ visibly for a reason in this plan.

Also `AutomationReport.Check`.

### [ ] 5.13. Tests for things that no longer exist

`Tests/FTAppKitTests/App/LaunchContextTests.swift:29-61` (an
Electron argv shape; then drop the `argvOffset` parameter, always 0 in the app);
`Tests/FTFileSystemTests/Watch/ProbeFailTests.swift` (a debugging probe; covered by `FolderWatchesTests`);
`Tests/FTOperationsTests/Execution/PackagePasteTests.swift:56` (identical to `:28`);
`Tests/FTAppKitTests/Appearance/AppearanceModelTests.swift:126` (same line twice). The unused helper members listed
in the FTOperations test kits (`MockWriteServiceFileSystem`, `NativePaste`, `UndoTestKit`, `LocalOperationsTestKit`,
`CoordinatorTestKit`): grep each and remove.

### [ ] 5.14. Golden metadata

`Tests/FTTestSupport/Golden.swift:23-29` requires `suite`, `referenceCommit`, `seed`,
`generator` and reads none; every file names a commit and a generator path that are not in this repo. [Q10]

---

## Phase 6. Simplifications

These change structure, not behaviour. Each ends with the same behaviour and fewer moving parts. The existing
tests are the check; add a test only where an item says so.

### [ ] 6.1. Windows stop talking to each other as if across a process boundary

- Merge All Windows asks each window for its tabs through `WindowTabsRequests`
  (`Sources/FTAppKit/Windows/WindowChannels.swift` 18–73): a string id, a 2-second timeout and a continuation,
  answered by a synchronous property on the same actor. Make `mergeInto` synchronous (`others.map(\.mergeAnswer)`),
  delete `WindowTabsRequests` and the `merging`/`mergeUnderWay` re-entrancy flags. Check the "window closes while
  the merge asks" tests still describe something that can happen; delete the two timeout tests
  (`ExplorerWindowOrderTests.swift` 183–209).
- `ExplorerWindowMessage` has one case and `tell` ends in a direct call: call the group directly.
- `ExplorerWindowStore` has one conformer (`AppStateStore`) and no test double: take the concrete type.
- `Host.log` is assigned and never called: delete it, `ExplorerWindows.log` and the assignment at `AppDelegate.swift:223`.
- `launchContext(for:)` and `entry.launch` (six test assertions); `PreferenceChangeReceiver` (declaration only).
- `ExplorerServices.current`'s fallback chain (`ExplorerWindowContext.swift` 67–102: `fallbackDirectoryService`,
  `fallbackClipboard`, `madeChannel`, `fallbackChannel`; `AppDelegate.applyAppearance`;
  `ContentPaneController.fallbackIcons`): `installed` is set before any window exists and tests use
  `servicesOverride`. Remove the fallbacks after confirming no test builds a `MainWindowController` with neither.
- **Keep** `ExplorerWindows.reconcile()`, `adopt`/`absorb`, the `ExplorerWindowLike` generic with `FakeWindow`.

### [ ] 6.2. Write results stay typed

- `WriteOperationOutcome.action` and `WriteOperationProgress.status` are strings (`"queued"`, `"move_to"`)
  rebuilt from typed values via `.rawValue` (`Sources/FTAppKit/Windows/ExplorerTabs.swift` 139–164, 331–357;
  `WriteOperations/AppWriteOperations.swift` 162–169; `ExplorerWriteSession.swift` 377–380; `AfterWrite.swift` 16,
  71–73). Underneath, `WrittenItem.status`/`action` in `Sources/FTFoundation/Contracts/WriteEffects.swift` (4–8,
  93–99) are strings compared with `"completed"` and `"batch_rename"`. Use the enums end to end.
- "What a write moved or removed" is implemented three times (`AfterWrite.swift` 10–16, 86–95, 121–126;
  `Sources/FTFoundation/Clipboard/CopyPasteClipboard.swift` 69–106, 291; `ExplorerTabs.swift` 314–349). First
  write a test that runs all three on the same inputs and shows they agree; then keep one.
- `typealias CopyPasteMode = ClipboardMode` in `WindowChannels.swift:126` collides with
  `FTOperations.CopyPasteMode`; remove the alias.
- `write-effects.json` keys are strings: map them in the test, do not edit the golden.

### [ ] 6.3. Listing dates are dates

- `EntryMetadata.createdAt`/modified are ISO-8601 strings built by a hand-written civil-date routine
  (`Sources/FTFileSystem/Listing/ExplorerListing.swift` 401–402, 524–558 `IsoDate`; `ListingTypes.swift` 76–77,
  96–97) and parsed back per cell (`Sources/FTAppKit/Content/List/ListCellText.swift` 75–91 `ISODate.parse`).
  Carry `Date?`. `InfoPreview` and `InfoPanelModel` in FTFoundation take the strings: change them too.
- Goldens that carry ISO strings (`classify` via `FixtureGoldenTests`, others): convert in the test.

This also ends the parsing per cell refresh (`ListCellText.swift:42, 49` use `ISO8601DateFormatter` each time).
Separately, `Sources/FTFoundation/Formatting/DateText.swift:137` creates a formatter per call: keep one.

### [ ] 6.4. Errors carry their number; one table of names

- Errors are identified by Node-style string codes compared as text (about 60 `errorCode(error) == "E…"` sites),
  backed by four hand-written errno-name tables: `Sources/CFileTrail/foldersize.c` 714–893 (`ft_errno_code`, one
  caller), `Sources/FTFileSystem/Volumes/EjectError.swift` 22–63, `Listing/ListingTypes.swift` 163–169,
  `Search/FdProcess.swift` 124–134, plus `Sources/FTOperations/Native/NativeError.swift` 106–145.
- Carry the `Int32` and compare numbers. Keep one table for display. **The text shown to users must not change**
  in this item: `ExplorerError.description` stays byte for byte (six test files assert it).
- `FolderReadFailure.isTrashRefused` (`Sources/FTAppKit/Content/ContentModel.swift` 67–72) decides "Full Disk
  Access is missing" by `message.contains("EPERM") || …"operation not permitted"`; decide by the code. Same for
  `walkError?.code == "EPERM"` (`FolderSizeJobs.swift:398`) and `EjectOutcome` (50, 55).
- In FTOperations do this one file at a time with the module's tests after each.

This item also fixes a visible fault: a listing that fails with `ESTALE` or `EDQUOT` says "Unknown system error
-70", because the tables have drifted apart (the fourth is `FdProcess.errnoName`). With one table those codes get
their names. That is the one permitted change of text: the text for every code that is named today stays byte
for byte.

### [ ] 6.5. Preferences are changed by typed updates

- 35 `updatePreferences(` call sites build `[String: JSONNode]` literals. Each change filters by a string key
  list, JSON-encodes the whole `AppPreferences`, overlays, runs the full sanitizer, and encodes before and after
  again to find changed keys (`Sources/FTFileSystem/AppState/AppStateStore.swift` 75–87, 256–296). The key names
  are kept by hand in five lists (`Preferences/PreferencePatch.swift` 5–17, `AppPreferences.swift` 96–101,
  `Settings/SettingsValues.swift` 16–19, `AppState/AppStateJSON.swift` 24–31, `AppStateStore.swift` 21–22).
- Shape: `store.update { $0.theme = .dark }`; changed keys by comparing the `Equatable` struct field by field
  (generate the comparison once, in one place); the window-session split by the existing `WindowSession` struct.
  Delete `PreferencePatch.swift`, `WindowSessionKeys`, `PreferencesSanitizer.apply`.
- `batchRenameSettings`/`batchRenamePresets` are stored as untyped JSON "until the sanitizers are wired in"
  (`AppPreferences.swift` 66–69); both types are `Codable` and in the same module. Make them typed, call
  `BatchRename.sanitizeSettings/Presets` directly, delete `BatchRenameSanitizers` (`PreferencesSanitizer.swift`
  3–35) and the duplicate defaults (16–24).
- Settings: `PreferencesSync` (`Sources/FTFoundation/Settings/PreferencesSync.swift`) with its payload, echo guard
  (`isWriting`) and `payloadKeys` goes; the window edits the shared model. **Keep** coalescing of disk writes
  while a continuous control is dragged (the colour panel).
- **Keep** `PreferencesSanitizer.sanitize` for reading the file (a damaged or hand-edited file must not block
  launch), `@NullEncoded`, and the on-disk format exactly: a file written by v0.16.x must read back identically
  and vice versa. `AppStateRoundTripTests` and `prefs-sanitize.json` guard this.
- The automation hooks set preferences by string key: give them one small name-to-key-path table.
- This is wide and mechanical. Do the store first with both APIs alive, move call sites module by module, then
  delete the old API.

### [ ] 6.6. The paste review is a call, not a job to poll

- Today: `WriteService.startCopyPasteAnalysis` stores the report under an id; the window polls
  `coordinator.analysisUpdate` every 120 ms (`Sources/FTAppKit/WriteOperations/WindowWriteActions.swift` 23,
  142–146), gets a trimmed copy, then names the id to start the paste.
- Shape: `func analyze(_ request, signal) async throws -> CopyPasteAnalysisReport`; the window holds the report
  and passes it to `startCopyPaste(report:policy:overrides:)`; cancel is the `StopSignal`.
- Goes: `WriteService/WriteServiceAnalysis.swift`, the job registry and pruning in `WriteService.swift`
  (43–50, 62, 69, 119–126, 152–174), `assertAnalysisOwner`, `analysesOfOtherWindows`,
  `trimAnalysisReportForWindow` (`Coordinator/WriteGuards.swift` 74–88), `CopyPasteAnalysisJobStatus`.
- **Keep the rule** that no review starts while a write runs and only one runs at a time, unless the owner says
  otherwise (see "Left out on purpose"); enforce it at the coordinator.
- Tests to reshape: `WriteServiceAnalysisTests.swift`, the analysis parts of `WriteCoordinatorTests` and
  `WriteCoordinatorWindowsTests`, `HeldAnalysisService` in `PreparingDialogTests.swift`, every
  `CoordinatorWriteService` stub (nine files), `Exec/SwiftAnalysisEngine.swift`, `SwiftExecEngine.swift`.
- The analysis goldens (`analysis-*.json`) must pass unchanged.

### [ ] 6.7. In-process events are not validated like messages from outside

- `WriteOperationEvent.checked()`/`WriteOperationEventCheck` (`Coordinator/WriteOperationEvent.swift` 179–186,
  203–263) check non-empty ids and non-negative counts on values built a few lines earlier. If a check ever
  failed, the catch path at `WriteCoordinator.swift` 363–366 would silently answer the user's question "skip".
  Remove the checks and that path. `WriteOperationWindow.receive` and the `recordUndo`/`caches.forget` closures
  are declared `throws` though no production implementation throws: make them non-throwing and remove the
  do/catch around them. **Keep** the handling around `UndoHistory.finish`, which really throws.
- Tests: the "an event that can't be sent" cases; test windows that throw from `receive`.

One more reason: the check at `WriteOperationEvent.swift:240` refuses a negative device number, so a question
about an item on such a device would be answered "skip" without being asked. It is uncertain that macOS produces
one; removing the checks removes the risk.

### [ ] 6.8. One file-system protocol with required members

- The tower `IdentityFileSystem` → `AnalysisFileSystem` → `WriteServiceFileSystem` → `LocalWriteFileSystem` →
  `UndoFileSystem` has one production conformer at every level (`NativeWriteFileSystem`; `PosixFileSystem` for
  the first two). Its optional members (`chmod`, `utimes`, `copyMetadata`, `copyMetadataToRunInPlace`, `setAcl`,
  `getAcl`, `trash`, `canModifyFolder`, `itemSize`) are always present in the app, so every
  `guard let chmod = fileSystem.chmod` and `fileSystem.setAcl?(…)` is a dead branch.
- Make the members required. Make `WriteCoordinator.fileSystem` non-optional and remove its two down-casts
  (`LocalOperations/RenameOperation.swift` 16–21, `Coordinator/WriteCoordinatorUndo.swift` 70–75) and
  `LocalAsUndoFileSystem` (285–324). Let `UndoBatchRenamer` take `BatchRenameFileSystem`, so
  `RecordingErrorsFileSystem` (`Undo/UndoExecution.swift` 763–831) forwards six members, not thirty.
- Collapsing the five protocols into fewer is optional; stop at required members if the test doubles make
  further merging expensive.
- **Keep** `isCaseSensitive` returning nil and the probe fallback.
- The test doubles implement the tower; each gains the required members.

### [ ] 6.9. Identical code kept once

Only merge code proven identical. Where two helpers differ in any case, do not merge them in this item.

- `movedItemsOf`: `BatchRename/BatchRenameExecution.swift` 520–535 and `Undo/UndoFileSystem.swift` 58–73.
- `randomHex`: `Execution/ExecutionFiles.swift` 9–16 and `BatchRenameExecution.swift` 506–512.
- "Look a path up on its own thread with a deadline": `Recovery/CopyPasteRecovery.swift` 189–212 and inline at
  `Recovery/WriteRecovery.swift` 124–143.
- `isAsApproved` on the Replace target runs twice with nothing between (`CopyPasteExecution.swift:548`, then
  `CopyPasteReplace.swift:31`): keep the second. **Keep** the third check after staging (`ReplacedItem.swift:18`).
- `ExplorerToolbar.sortLabel` (304–311) and `ContextMenuSession.sortLabel` (192–199).
- The natural name compare: `SizeOrder.compareNames` and `TreePaths.naturalCompare`.
- `DragRules.volumeRootPath`, `TreePaths.volumeRootPath` and the copy in `Icons/IconCacheKey.swift` 152–162.
- Four "JavaScript trim" copies (`SearchResults.swift` 200–212, `ExplorerListing.swift` 499–512,
  `DiskImageNames.swift` 39–50, `ApplicationPaths.trimmed`): they use three different whitespace sets. Merge only
  those with the same set; note the others.
- Pluralize (five copies) and grouped count (three implementations, two pinned to en_US and one following the app
  language): merge only copies that give the same output for the same input, and leave the locale difference alone
  (see "Left out on purpose").
- `InfoMetrics.suggestionDebounce`/`suggestionLimit` and `PathCompletionRequests.debounce`/`limit` (same numbers
  twice); `ContentStateText.loadingDelayMilliseconds` and its twins.
- Three seeded generators in tests (`Mulberry32`, `SeededRandom`, `RandomGenerator`): leave; not worth the churn.

### [ ] 6.10. The menu bar is updated in place

- `Sources/FTAppKit/Menus/ApplicationMenuSync.swift` (113, 223–232) and `App/MainMenu.swift` rebuild the whole
  main menu and reassign `NSApp.mainMenu` whenever the Undo or Redo wording changes, on the stated ground that a
  menu item's label cannot be changed in place. `NSMenuItem.title` is settable. Set the titles.
- "Add to Favorites"/"Remove from Favorites", "Hide Folder Tree"/"Show Folder Tree", and Undo/Redo are each two
  items with one hidden (`Menus/ApplicationMenuBuilder.swift` 80–84, 105–108, 140–144): make each one item whose
  title is set when the state changes.
- `MenuCommandRouter.onCommandSent` (38–40) re-syncs after every command because "macOS flips a checkmark on its
  own". It does not. Remove the re-sync and `radioItemIDs` sibling un-checking if states are simply set from the
  model; verify by hand that checkmarks (view mode, sort, hidden files) stay right after choosing each.
- Rebuild only when the shortcuts or the text editor change, as the header comment says.
- Not in this item: replacing the pushed `ApplicationMenuState` with `validateMenuItem` (see "Left out on purpose").

### [ ] 6.11. Folder sizes: remove the copies

- Three pairs of structs copied field by field at `Sources/FTAppKit/FolderSizes/WindowFolderSizes.swift` 5–60
  (`FolderSizeProbe`/`SizeProbe`, `FolderSizeJob`/`JobState`, `FolderSizeStartResponse`/`JobStart`) and
  `typealias FolderSizeStatus`: use the FTFileSystem types.
- `maxProbesPerRequest` chunking through a `Task` hop for an in-process dictionary lookup: call directly.
- Do not change the per-window cache or the write-interaction logic (`outdatedJobIds`, `FolderSizeAdjust`,
  recording during writes).

### [ ] 6.12. Search: the leftovers of a wire protocol

- `TabSearchUpdate` is a field-for-field copy of `SearchUpdate`, `TabSearchStatus` is `SearchJobStatus` plus
  `idle` (`Sources/FTAppKit/Windows/ExplorerTabs.swift` 6–43): use one.
- `Codable` on `SearchRequest`, `SearchJobStatus`, `SearchResultItem`: nothing encodes them. Remove unless a
  golden test decodes them (then keep the decoding in the test).
- The `elapsedMilliseconds` chain (`Search/SearchSession.swift` 78, 556, 651–653), with `clock`, `startedAt`,
  `awaitingFirstUpdateAfterReturn`, `finishedAway` if only it uses them; `sessionCounter`'s guard after the
  synchronous `engine.start`.
- The per-result `lstat` runs inside the lock the main thread takes on every poll
  (`Sources/FTFileSystem/Search/FdSearchRuntime.swift` 242–287 `append` → `hasHiddenFlag`): do the `lstat` on the
  reader thread before taking the lock, and append under the lock.
- `SearchResults.compare` (92–98) makes a new `Collator()` per comparison: make one per sort.
- Leave the polling itself and the background-tab behaviour (1 s polls, search again on return).

`SearchResults.swift:81-131` does up to three locale-aware compares per comparison over up to 20,000 results.
Once 8.2 has settled the comparator, sort with keys computed once per item; until then one collator per sort is
enough.

### [ ] 6.13. Text that repeats a number reads it from the code

- "A window holds up to 25 tabs" (`Sources/FTFoundation/Help/HelpTopics.swift` 49, 101), "Search stops at 20,000
  results" (456), the banner "Showing the first 20,000 matches." (`Search/SearchBarText.swift:47`) are literals;
  the limits are `AppPreferenceLimits.openTabsLimit` and `FdSearchRuntime.resultLimit`. Build the text from the
  constants (move the search limit to FTFoundation so both can read it). `help-content.json` should not change.

---

## Phase 7. Speed and stalls

Measure before and after each (a CPU-time test with `CPUTime.measureThread`, or a timing printed from a debug
build), and put the numbers in the commit body. Skip any that measures as not worth it and note that in the Log.

### [ ] 7.1. One slow folder no longer stalls every window's listing

`Sources/FTFileSystem/Listing/DirectoryService.swift:26-60, 78-95`: every listing, tree read, `itemProperties`,
`pathSuggestions` and `hasHiddenFlag` runs synchronously on the one shared actor. Only `metadata` is detached. *Fix:*
do the disk work off the actor (as `metadata` does) and keep only the cache bookkeeping on it. This is the largest
change in this phase; read `ResponseCache` first and keep its de-duplication of identical requests.

### [ ] 7.2. Launch does not wait on slow volumes

- Blocking calls on the main thread: `ScreenGeometry.isFolder` (`Sources/FTAppKit/Windows/ExplorerWindows.swift`
  42–45), called for every restored background tab in `makeGroup` (274) and every merged tab in `addTabs`
  (`ExplorerTabGroup.swift:367`); `NativeFileSystem().realpath` in `openRequestsWaiting` (330);
  `LaunchContext.isDirectoryIfThere`/`isDirectoryOnDisk` (`App/LaunchContext.swift` 32–46). The code's own rule
  elsewhere: "Looked up off the main thread: a link into a slow volume must not freeze the window"
  (`MainWindowController.swift` 1345–1348). A restored tab on a stalled network mount blocks launch before any
  window shows.
- Fix: investigate first. A restored background tab does not load until it is shown, and a tab whose folder is
  gone already goes to the nearest existing folder (`ensureLoaded` → `openNearestExistingFolder`); if that path
  covers a restored tab that is no longer a folder, drop the check for restored tabs. For the open-request paths,
  move the lookup off the main thread and continue when it answers. Write up what you found before changing it.

### [ ] 7.3. "Is the Trash empty" does not read network shares

- `TrashState.isEmpty` (`Sources/FTFileSystem/System/TrashState.swift` 25–28) lists `/Volumes/*` and reads
  `.Trashes/<uid>` on each, network shares included, and is called while a context menu is being built
  (`Sources/FTAppKit/ContextMenus/ContextMenuCoordinator.swift:93`). `TrashFolders` (`TrashFolders.swift` 5–7)
  already uses the mount table filtered to local disks because "reading one may stall".
- Fix: `isEmpty` uses the same local-disk list as `TrashFolders`. Confirm whether the context-menu call is on the
  main thread; if it is, use the last known answer there and refresh it off the main thread.

Found by both audits. `isEmpty` also lists `~/.Trash` in full: stop at the first name found, and use the resolved
home Trash as `TrashFolders` does.

### [ ] 7.4. The Info panel does nothing when closed, and nothing proportional to the folder per selection change

`Sources/FTAppKit/InfoPanel/InfoController.swift:284-303, 317-334, 139-142, 449-457`: `selectionDetails()` builds a
set of the whole listing, `entry(at:)` scans `content.listed` linearly several times per update. Use the content
pane's `rowsByPath`, and return early when neither the panel nor the row is shown.

### [ ] 7.5. The toolbar's state refresh builds the command context once

`Sources/FTAppKit/Toolbar/ExplorerToolbar.swift:225`: each item's `canPerform` (`MainWindowController.swift:2407`)
builds a whole context, twice per command button (`ToolbarMenus.swift:248`), plus a `NumberFormatter` per item
(`ToolbarItemViews.swift:207`).

### [ ] 7.6. Sidebar row heights are looked up in constant time

`Sources/FTAppKit/Sidebar/SidebarListView.swift:519-523` uses `firstIndex(where:)` per row on every reload. Also
`SidebarViewController.swift:291-310, 375-382` builds the tree presentation twice per refresh.

### [ ] 7.7. No `Locale` per name comparison

`Sources/FTFoundation/ListLayout/SizeOrder.swift:34` and
`Sidebar/TreePaths.swift:148`; `Sources/FTFileSystem/Listing/Collation.swift:120` shows the static-locale pattern.

6.9 merges these two compares into one and 8.2 may replace the comparator. If either has been done, check whether
this is still needed.

### [ ] 7.8. Sorting by Kind does not ask Spotlight per file

`Sources/FTFileSystem/Listing/ExplorerListing.swift:23,
255` calls `MDItemCreate` once per extension-less file, uncached, on the actor (`Icons/FileKind.swift:19`). Cache by
whatever the answer depends on, or answer extension-less regular files without Spotlight.

### [ ] 7.9. The write engine stops looking at destinations that cannot exist

`Sources/FTOperations/Execution/ExecutionFiles.swift:113`: a file copied into a folder this paste just made is
looked at three times before and once after, though `copyfile` runs exclusive.
`Analysis/CopyPasteAnalysis.swift:598`: each conflicting item costs about five `realpath` calls at review and again
at execution. Take extra care: do not remove a check that guards a destination someone else could have created. If
unsure about one, leave it.

### [ ] 7.10. Smaller ones, do if cheap

- `Sources/FTAppKit/Content/CompactList/CompactListViewController.swift:14`: `nameWidths` is unbounded.
- `Content/Icons/IconViewController.swift:82` and `CompactListViewController.swift:120`: `marqueeHits` maps every
  entry's path per mouse move; `host.entryPaths` already has it.
- `Content/ContentPaneController.swift:669`: `setSelection` syncs the pane and five callers sync again.
- `Content/ContentPaneController.swift:835`: `showSearch` makes a new `ContentSearchContext` per update, discarding
  its caches.
- `InfoPanel/InfoControls.swift:6-8`: `infoTheme` builds a `Theme` per call; the sidebar caches it
  (`SidebarRows.swift:75-87`).
- `Settings/SettingsPopovers.swift:8`: an icon lookup inside `draw(_:)`.
- `Sidebar/SidebarViewController.swift:170-173`: the mount table is re-read when a window loses key as well as when
  it gains it.
- `Windows/ExplorerTabGroup.swift:640`: `saveSession()` encodes everything several times per navigation.
- `Sources/FTOperations/Coordinator/WriteCoordinator.swift:111`: the end of a paste polls with `usleep(50)`.
- `WriteCoordinator.swift:118`: progress is throttled after each event has been sent to the main queue.
- `Sources/FTFoundation/Dialogs/WriteResultNoticeText.swift:70`: `detailLines` is quadratic in item errors.

---

## Phase 8. Behaviour the owner decides

Each item waits on its question. For each: test first, fix, build the app (`scripts/build-app.sh`), and stop for
the owner to try it before the next.

### [ ] 8.1. The startup disk is shown by its real name

[Q11]

- "Macintosh HD" is hard-coded as the name of `/` in `Sources/FTFoundation`: `TabText.swift:19`,
  `Info/PathBarModel.swift` 86, 103, `Ranking/Places.swift:41`, `Sidebar/TreeItems.swift:160`,
  `Info/InfoPreview.swift:111`, `Sidebar/Favorites.swift:16`. A renamed startup volume shows the wrong name.
- Fix: read the name once at launch from `URLResourceKey.volumeNameKey` for `/` (off the main thread) and pass it
  into these functions as a parameter that defaults to "Macintosh HD", so the goldens are unaffected. Update on
  `NSWorkspace.didRenameVolumeNotification`.

Found by both audits. Also `Search/SearchBarText.swift:65`. Help can keep "Macintosh HD" as its example.

### [ ] 8.2. Names sort in the user's language, the same way everywhere

[Q12]

- Five orders are in use: the folder listing, tree and path suggestions use ICU's root locale, numeric
  (`Sources/FTFileSystem/Listing/ICUCollator.swift:31`); Kind labels and the fallback use `en_US`
  (`Collation.swift:120`); search results by name use the current locale without numeric ordering
  (`Search/SearchResults.swift` 136–145); Open With uses the current locale, numeric; volumes use `en_US`, numeric.
  So `file2` and `file10` sort differently in a folder and in search results, and a Swedish or Turkish user does
  not get their alphabet's order, as Finder gives.
- Fix: one comparator. Open the ICU collator with the current locale's identifier, numeric, and use it for all
  five. Let the locale be injected so `listing-sort.json` and `search-sort.json` tests keep running with the
  locale they were recorded in (root, and the recorded one); add tests for a non-English locale and for
  `file2`/`file10` in search results. If `search-sort.json` cases change because of numeric ordering, edit them
  by hand.
- English-locale order should be unchanged apart from numeric ordering in search results. Say so to the owner.

Found by both audits. If the owner wants only the smallest version: search results sort by name with numeric
ordering, as listings do, and the locale stays as it is.

### [ ] 8.3. Listings know 10 package extensions, naming knows 37

[Q13]

[verified that the short list has 10]
`Contracts/ItemNames.swift:31` vs `Names/CopyPasteNames.swift:14`. `.rtfd`, `.xcworkspace`, `.photoslibrary`, `.pkg`,
`.sparsebundle` show as folders. *Fix:* one list used by both. This changes what the listing calls those items, so
check which goldens record it (`classify.json`, listing goldens) and stop to ask before changing one.

Paths are under `Sources/FTFoundation`. Do not change the list without the owner's yes.

### [ ] 8.4. Accented letters typed in the list filter miss names stored decomposed

`Formatting/ListFilter.swift:30`, also `Sidebar/SidebarKeyboard.swift:161` and `Ranking/Places.swift:107`.
[Q14]

Paths are under `Sources/FTFoundation`.

### [ ] 8.5. File ▸ Remove from Favorites is never offered for Trash; the context menu offers it

`Commands/CommandAvailability.swift:52, 216-217` vs `ContextMenu/ContextMenuRules.swift:91-94`. [Q15]

Paths are under `Sources/FTFoundation`.

---

## Phase 9. System controls instead of hand-built ones

Decision 1 removes the reason these were hand-built. Every item changes how something looks. For each: build
(`scripts/build-app.sh`), stop, and let the owner try it before the next. Keep the accessibility identifiers the
tests and `tools/capture/elements.json` use. Tests that assert the old look (pixel positions, colours of
hand-drawn parts) go with the control; tests of behaviour stay.

### [ ] 9.1. Sheets and the Info panel use system checkboxes and pop-up buttons

- `BatchRenameCheckbox` (`Sources/FTAppKit/BatchRename/BatchRenameControls.swift` 357–467): `RuntimeConflictAlert`
  already uses the system checkbox. The two `NSPopUpButton` subclasses that redraw everything
  (`BatchRenameControls.swift` 237–351; `CopyPaste/CopyPasteControls.swift` 231–343).
- The identical warning triangle drawn at `CopyPasteControls.swift` 69–85 and `BatchRenameControls.swift`
  740–749: one SF Symbol.
- The four copies of panel chrome, footer line, button row and Tab cycling
  (`Dialogs/AlertCard.swift` 120–130, `GoToFolderBox.swift` 338–347, `CopyPasteSheetView.swift` 91–101, 146–160,
  `BatchRenameSheetView.swift` 439–474, `DialogScrim.swift` 369–386): one shared base.
- Do not replace the in-window dialog framework itself (see "Left out on purpose").

### [ ] 9.2. Settings uses system controls

- Replace with the system control, keeping behaviour: `SettingsPopup` (`Settings/SettingsControls.swift` 296–418)
  and `SettingsAppPopup` (`SettingsPopovers.swift` 262–344, `SettingsPages.swift` 481–544) → `NSPopUpButton`;
  `SettingsCheckbox` (536–577) → checkbox `NSButton`; `SettingsNumberField` (424–532) → `NSTextField` with a
  `NumberFormatter`; `SettingsListView`/`SettingsListRow`/`SettingsListBarButton` (`SettingsLists.swift`) →
  `NSTableView` with drag reordering and a segmented +/− control; row and card layout
  (`SettingsControls.swift` 597–784) → `NSGridView`/`NSStackView`.
- Keep: `SettingsSwitch` (already `NSSwitch`; drop its hand-made focus ring), `AppearancePicker`,
  `AccentSelector`, the shortcut recorder (`ShortcutSettingsView.swift`).
- `SettingsMetrics.swift` shrinks to what is still read.
- Do it one control kind at a time, one commit each.

### [ ] 9.3. Toolbar and menu icons are SF Symbols

- About 48 toolbar glyphs and 30 context-menu glyphs are stroked from path strings
  (`Toolbar/ToolbarIcons.swift`, `ContextMenus/ContextMenuIcons.swift`; 18 icons are drawn in both; eject a third
  time in `Sidebar/SidebarIcons.swift` 85–90). `CLAUDE.md` says to use Finder's symbols, and the sidebar already
  uses SF Symbols for favorites and locations.
- Use `NSImage(systemSymbolName:)`, choosing the symbol Finder uses for the same command. Make one icon enum for
  the commands instead of `ToolbarIconName` and `ContextMenuIconName`. Where no symbol fits, keep the drawing and
  list it in the commit message. `Toolbar/SVGPath.swift` stays only if something still draws from path data.
- Same for the 13 glyphs in `InfoPanel/InfoControls.swift` (`InfoGlyph`) and the five in `Help/HelpSidebar.swift`.

### [ ] 9.4. Hand-drawn text stops imitating a browser's baseline

- `TextBaseline` (`Sources/FTAppKit/Layout/TextBoxField.swift`) moves every hand-drawn line so that its baseline
  lands where a browser would put it, with a `-0.001` adjustment; used by the list labels, `MarkedName`, the icon
  label and `TextBoxCell`. Remove the shift and let AppKit place the text; check rows and icon labels by eye in
  all three views at each size setting.
- Three unproven claims about AppKit drive `PlainLabel`, `SearchTextCell` and colour flattening
  (`Appearance/PlainLabel.swift` 3–5, `ThemedSearchField.swift` 120–135, `ThemedViews.swift` 183–185): "an
  unbordered cell with no field editor draws text in a colour with alpha twice" and "AppKit draws a translucent
  text colour of an attributed string as an opaque one". Write a small test for each claim on macOS 26. Where the
  claim is false, remove the workaround; where true, keep it and leave the test as its proof.

---

## Phase 10. Comments on the app's own terms

- [ ] 10.1 `Sources/FTFoundation`
- [ ] 10.2 `Sources/FTFileSystem` and `Sources/CFileTrail`
- [ ] 10.3 `Sources/FTOperations`
- [ ] 10.4 `Sources/FTAppKit`
- [ ] 10.5 `Tests`: comments
- [ ] 10.6 `Tests`: names of tests and fixtures (step 6)
- [ ] 10.7 Identifiers in Sources (step 7), after [Q16]
- [ ] 10.8 `tools`, `scripts`, `docs`

Do this last so removed code is not rewritten first. The rule is in `CLAUDE.md`. The audit found several hundred
comment lines across all targets, tests, tools and docs that name Electron IPC channels, JavaScript constants and
functions, CSS selectors and properties, "the browser", "the page", "the renderer", "the main process", or carry a
record number.

**Method**

1. Work one target at a time, one commit per folder of a target, comments only: no code change in these commits. The
   diff of each commit must show only comment lines (check with `git diff --stat` and a skim).
2. Rewrite each comment to say what this code does and why, in this app's terms. Do not just delete the foreign name
   and leave a hollow sentence. Where a comment only said "as X does", say the actual rule ("names compare by UTF-16
   code unit, so NFC and NFD spellings are different names").
3. Find them with these, run per folder, then read every hit:
   - channel and event names: `rg -n '[a-z]+:[a-zA-Z]+|filetrail:[a-zA-Z]+|app\.(on|exit|getVersion)|ready-to-show'`
   - constants: `rg -n '\b[A-Z][A-Z0-9]+(_[A-Z0-9]+)+\b'` in comment lines
   - web terms: `rg -n -i 'css|stylesheet|browser|web page|the page|renderer|main process|blink|v8|node|libuv|
     jsx|aria-|data-[a-z]|:focus|:hover|color-mix|--[a-z]+-[a-z]|z-index|line-height|box-sizing|px;'`
   - JavaScript: `rg -n 'localeCompare|toLowerCase|JSON\.stringify|Date\.(now|parse)|prototype\.|=== |typeof |
     new (Date|Error)|path\.(join|resolve|extname|relative)|fs\.[a-z]+|util\.inspect|vitest'`
   - records and history: `rg -n '\((a?\d{2,3}(, ?\d{2,3})*)\)|/0\d\d:|Wave-\d|the original|port[ -]|parity|ui\.md|
     PLAN\.md|section \d'`
   - doc comments that are only a foreign function name: ``rg -n '^\s*/// `[a-zA-Z]+`:'``
4. Known record numbers to remove: `Sources/FTAppKit/Settings/SettingsPopovers.swift:13, 127`,
   `Settings/ShortcutSettingsView.swift:155-156`, `About/AboutWindowController.swift:37`, `Sidebar/SidebarModel.swift:55`,
   `App/AppDelegate.swift:24`, `Sources/FTFoundation/Info/InfoPanelModel.swift:245`,
   `Sources/FTAppKit/Content/ItemGrid.swift:113`. In `Tests/FTAppKitTests`: `Windows/AutomationStepWindowTests.swift:1-2,
   75, 133, 178, 200`, `Windows/TabsComingBackTests.swift:11, 73`, `Settings/ReviewRunnerOrderTests.swift:1`,
   `Settings/ShortcutSettingsTests.swift:307`, `Settings/SettingsWindowTests.swift:565`,
   `BatchRename/BatchRenameInWindowTests.swift:251`, `Clipboard/ClipboardWindowTests.swift:151, 309`,
   `Content/CompactList/CompactListTests.swift:179`, `Content/ReviewRowWidthTests.swift:71`,
   `Dialogs/DialogLookTests.swift:121, 122, 257`, `Menus/MenuCommandRouterTests.swift:21`,
   `Layout/RerunFixTests.swift:1`.
5. Fix the comments found wrong along the way:
   - "100 tabs" at `Sources/FTAppKit/Windows/ExplorerWindows.swift:50` [verified] and `MainWindowController.swift:135`;
     "The 101st tab" at `Tests/FTAppKitTests/Notifications/NotificationsTests.swift:70`. The limit is 25.
   - Doc comments on the wrong declaration: `MainWindowController.swift:616-617, 2152`; `ExplorerWindows.swift:217`;
     `App/AppDelegate.swift:5`; `Sidebar/SidebarModel.swift:55-58`; `Sidebar/SidebarViewController+Window.swift:148`.
   - Comments that contradict the code: `Sources/FTOperations/LocalOperations/LocalOperationHelpers.swift:105`,
     `WriteService/WriteServiceAnalysis.swift:20`, `Coordinator/WriteCoordinator.swift:421`;
     `Sources/FTFoundation/Clipboard/InternalDragAndDrop.swift:65`, `Preferences/AppPreferences.swift:66`,
     `Info/InfoPanelModel.swift:145` (ends mid-sentence), `Commands/CommandAvailability.swift:134`.
   - References to documents that do not exist (`ui.md`, `PLAN.md`, "section 1.3", `run.sh`, `setup.scratch`).
6. Test names are code, not comments: rename the ones that carry the old vocabulary in a separate commit per target
   (`laysThe…OutAsTheStylesheetDoes`, `aFailureSaysWhatNodeSays`, `roundsATieUpAsToFixedDoes`, `matchesTheReference`,
   `readsNodesOwnCodeForAFolderRemovedAsAFile`, `saysNothingOfWhatTheApprovedDeviationsRemoved`, "what the brief asks",
   the volume name "FT Port Test", `ft-parity` in `Tests/FTTestSupport/ExecPlaces.swift`).
7. Identifiers in Sources that carry the old vocabulary are [Q16]; do not rename them without it.
8. `tools/`: `tools/acknowledgements/gen.ts:2-5`, `tools/bench/budgets.json:82`, `tools/fixtures/generate.ts:25`,
   `tools/fixtures/disk-images.sh:4, 6, 17`. `docs/`: `known-issues.md:3`, `battery.md:26`.

When done, `rg -n -i 'electron|port of|the original'` over `Sources Tests tools scripts docs` should return only
`CLAUDE.md`'s own rule and uses of "the original" that mean a source file (e.g. `Sources/CFileTrail/copyfile.c:77`).

More from the first audit:

- Further searches: `app:`, `filetrail:`, `_MS\b`, `[A-Z]{3,}_[A-Z_]{3,}`, `\(\d{2,3}\)$`, "as libuv does",
  "Generated once; now edited by hand".
- Reported concentrations: `Sources/FTFoundation/Preferences/PreferenceTypes.swift`, `Commands/*`,
  `Design/ThemePalette.swift`, `Sources/FTAppKit/Settings/*`, `Windows/*` (32 lines),
  `Sources/FTFileSystem/Search/SearchTypes.swift` (4, 71, 77), `Watch/FSEventsFolderWatcher.swift:6`,
  `System/OpenWithCatalog.swift:37`, `tools/fixtures/generate.ts:25`.
- `JSString`, `JSText`, `NodePath` and `JSRegExp` are names of live types that describe rules the app keeps
  (decision 4): do not rename them.
- Files that 5.10 deleted (`tools/acknowledgements`, `tools/fixtures/disk-images.sh`) need nothing here.

---

## Phase 11. Docs, scripts, tools

### [ ] 11.1. Documents that no longer match the code

[Q17] for the first bullet.

- `docs/known-issues.md` (line 43) says to run `git apply docs/finder-trash-workaround.diff`. The patch fails on
  four of its nine files today. Find the commit it was made against (`git log --follow docs/finder-trash-workaround.diff`),
  and change the instruction to name that commit as the base to check out first. Keep the prose findings.
- `tools/fixtures/README.md` (lines 9–10) describes images that `disk-images.sh` does not make (see 5.10).
- `CLAUDE.md` "Test data" says the goldens were recorded from the earlier app and are frozen. At least
  `help-content.json` has been recorded again from this app's output (commit `8f3746a`). Reword: the goldens are
  expected results kept by hand; some were first recorded from the earlier app.
- `tools/bench/budgets.json` (line 82) and `tools/bench/run.sh` (line 2) cite a `PLAN.md` that does not exist;
  remove the references. `Tests/FTOperationsTests/Execution/PasteThroughputTests.swift:1` cites a throughput
  budget that is not in `budgets.json`; correct the comment.

Found by both audits: the patch was made 48 commits before `c58b3fe` and `git apply --check` fails.

### [ ] 11.2. `docs/battery.md:31` lists the timers that really run

It says other repeating timers run only during an
animation, an open menu or a copy. Also running: a search polls every 0.12 s, and once a second in a background tab
(`Sources/FTAppKit/Search/SearchSession.swift:602-622, 673`); a folder-size calculation polls every 0.2 s
(`FolderSizes/WindowFolderSizes.swift:68`); a marquee drag ticks at 60 Hz; `RecoveryRetry` fires for as long as
crash-journal entries remain (`WriteOperations/AppWriteOperations.swift:93`). Confirm each, then correct the doc.

### [ ] 11.3. `CLAUDE.md` and `README.md` agree with the scripts

Document `--full` or remove it (`scripts/ci.sh:20`);
README mentions `--affected` and `FILETRAIL_GUI_TESTS`; README's "you can change any of them" about shortcuts vs
Undo, Cut and Paste being `fixed: true` (`Sources/FTFoundation/Commands/ShortcutCommandTable.swift:274-278`: confirm
what `fixed` does first). Changes to `CLAUDE.md` need the user's yes.

2.1 and 2.6 already change these files for the warnings claim and `bun`, and 4.1 for the minimum macOS.

### [ ] 11.4. `tools/bench`

`run.sh` cites a `PLAN.md` that does not exist, the committed baseline is over budget on six
metrics, the idle-memory launch can measure the wrong thing (`run.sh:82`: no `--user-data-dir`, no
`FILETRAIL_ALLOW_MULTIPLE`), `run.sh:90` only works from the repo root, and nothing calls it. The `#if RELEASE`
budgets in the bench tests are therefore never enforced. [Q18]

### [ ] 11.5. `tools/fixtures`

`README.md:10` describes images `disk-images.sh` does not make; the script's `clone`
mode has no consumer; `scripts/readme-screenshots.sh:25` builds all three fixture trees when only `lighthouse` is
needed; the fixtures location is spelled three ways (`FILETRAIL_DEV_CACHE`, `FILETRAIL_FIXTURES` in
`Sources/FTAppKit/Automation/Scenario.swift:413`, and hard-coded in `tools/bench`).

`disk-images.sh` and the README lines about it go in 5.10; what is left here is the last two points.

### [ ] 11.6. Small script fixes

- `scripts/build-app.sh:81-82` hides `codesign` output, so a failure stops with no message.
- `scripts/readme-screenshots.sh:33-35` ignores `MACOS_SIGN_IDENTITY` and fails unexplained with no identity.
- `scripts/release.sh:97-103` dies before printing the "gh isn't installed" problem.
- The release-tag regex is duplicated in `scripts/version.sh:10-12` and `scripts/lib/release-lib.sh:2-9`.
- `scripts/hands-on-setup.sh` and `tools/acknowledgements`: see 5.10.

### [ ] 11.7. Say in the docs that file Copy and Cut use the app's own clipboard

- Decision 3 keeps the private clipboard. Add an entry to `docs/known-issues.md`: files copied or cut in File
  Trail cannot be pasted in Finder or other apps, and files copied elsewhere cannot be pasted in File Trail; this
  is by design. Check Help (`HelpTopics.swift`) says nothing that contradicts it.

---

## Phase 12. Wrap-up

### [ ] 12.1. Final checks

- `scripts/ci.sh` (everything) passes with zero warnings in sources and tests.
- `FILETRAIL_LARGE_FILE_TESTS=1 scripts/ci.sh` passes.
- The GUI tests pass with the command from 2.7.
- `scripts/build-app.sh` builds; the app launches; a copy, a cut-paste across two disks, a trash, a batch rename
  and an undo of each work on real files in a scratch folder.
- `scripts/readme-screenshots.sh` runs.

### [ ] 12.2. Keep the decisions, hand over the rest

- Move "Decisions on record", the answers to the open questions (from the Log) and "Left out on purpose" into
  `docs/decisions.md`, with a line under each left-out item that was settled meanwhile. Then ask the owner
  whether this file and the two plans it replaced can be deleted.
- Give the owner a short list for the release notes, in plain language for end users: the minimum macOS, the bug
  fixes a user would notice, sorting in the user's language, the startup disk's real name, the new look of
  Settings and the icons. No commit summaries and no list of known issues.

---

## Must stay

Things that look removable and are not. Do not change these. If an item above seems to require it, stop and ask.

- The coordinator's write slot; hidden-name staging and the journal; `isStagingName`/`isTemporaryName` checks
  before recovery touches anything.
- `renamex_np(RENAME_EXCL)` everywhere with the ask-again loop; `removeEmptyFolder`'s read before `rmdir`.
- Replace's re-check after staging, the counted and lock-scanned permanent delete, and never offering
  delete-for-good on the startup disk or for an unexplained Trash failure (`Native/TrashItem.swift` 56–66).
- The replace-safety predicates evaluated at review and again at run time; `assertNotWrittenByThisPaste`.
- Byte-exact path comparison (`sameText`, `NameKeys.Exact`): Swift's `==` treats NFC and NFD as equal.
- The `copyfile` status callback in `Sources/CFileTrail/copyfile.c`; the large-file tests.
- Undo and Redo as they are; `UndoFuzzTests`, `BatchRenameFuzzTests`.
- `JSRegExp.swift` and `expandReplacement` (decision 4); `NodePath`; `CopyPasteNames.detectCaseSensitivity`.
- The `fd` binary, `FdProcess`'s `posix_spawn`, the trailing `"--"` in the arguments, `HiddenFilter`.
- FSEvents for folder watching; `ExplorerWindows.reconcile()`; `WorkspaceSplitView`/`WorkspaceSplitController`;
  `FileRefusingFieldEditor`; `FirstClickGate`; `SecondInstance`; `RenameDrafts`.
- `ExplorerToolbar`'s `applying`/`commitPending` flags; `ContextMenuSession` holding itself on its menu;
  `holdingTheTab`; `SidebarModel`'s request numbering; `WriteStartingShortcuts.runs(… isRepeat:)`.
- The `density` migration; `PreferencesSanitizer.sanitize`; `@NullEncoded`; the app-state file format.
- The `vtool` restamp in `build-app.sh` unless 4.1 proves it unnecessary; `FTTestSupport` as a regular target;
  the release-script tests; `AppClock` and `FILETRAIL_NOW`.
- The app's own clipboard (decision 3) and the rules that keep it truthful.
- Glass only on toasts, the progress card, plain alerts and the pill; sheets, Go To and alerts with lists or
  fields stay opaque.
- Accessibility identifiers and `accessibilityPerformPress()`; the read-only test seams.
- `adopt`/`absorb` and the `ExplorerWindowLike` generic with `FakeWindow`.
- The rule that no paste review starts while a write runs and that only one runs at a time.
- Coalescing of preference writes to disk while a continuous control is dragged.
- `ElementFinder`, `MouseEvents`, `KeyEvents`, `AutomationPrefs`, `AutomationDraggingInfo`/`AutomationDrag`: many
  tests press things through them.
- The polling of a running search and the background-tab behaviour (one poll a second, search again on return).

## Left out on purpose

Not to be done under this plan. Recorded so the reasons are not lost and the findings are not rediscovered.

- **Batch rename on `NSRegularExpression`.** Decision 4.
- **File clipboard on the system pasteboard.** Decision 3.
- **Sidebar as a real source-list outline** (about 1,000 lines). A redesign with every sidebar interaction test
  redone; needs its own plan.
- **Replacing the in-window dialog framework with `NSAlert` and sheets.** High risk, about 3,800 lines of tests
  drive it; the shared base in 9.1 takes the cheap part.
- **The clipboard popover as an `NSTableView`; the path bar as `NSPathControl`.** Worth doing after 9.1–9.3 show
  how the system controls sit; not specified here.
- **Menu enablement by `validateMenuItem` instead of pushed state.** 6.10 takes the cheap part.
- **Drag tracking by AppKit callbacks** (`draggingEnded`, system spring-loading) instead of timers. Needs hand
  tests of drags from other apps first.
- **One write slot instead of two kept in step by a polling loop**, and the early-event buffers. Sound today;
  the ordering of "operation ended" against "next write may start" is delicate.
- **The six in-memory file systems in the tests.** Consolidating them onto real temporary directories is about
  1,900 lines of test changes with medium confidence.
- **Flushing a cross-disk move before deleting the original.** Today the original is deleted after comparing
  kind and size. Recommended later: one full sync of the destination volume before `removeMovedSources`. Needs
  a decision on the cost.
- **Partial files under 32 MB left behind by a crash.** Needs a measured cost of journaling smaller files.
- **File ids of 2^53 or more treated as unknown.** Needs a check on a FAT image of which ids are really shared.
- **Date and number formats tied to the language, not the region; English words around localized dates.**
- **The default accent as the system accent.**
- **An update mechanism.** There is none; users are not told of new versions.
- **The app log file** (`AppLogger`): nothing in the app reads it; keep it if users are asked to send it.
- **`ResponseCache`'s 3-second lifetime**, `AppStateJSON`'s hand-written writer, the visited-folders ranking
  constants, the 180 ms and 320 ms single-click delays, class-name matching on AppKit's private views.
- **Alerts are not clamped to the window's height** (`Dialogs/AlertCard.swift` 142–149).
- **Small helpers that are similar but not identical** (parent path, leaf name, trimming with different
  whitespace sets, exact path equality, thousands grouping with different locales, key codes, "hold until
  released" test gates, the review-resolve-execute test harness, three seeded generators in tests). 6.9 merges
  only the copies proven identical. Take another only when a bug fix touches it.
- **Test folder and suite names that no longer match their contents** (`RerunFixTests`, `ZZReviewBandMenuTests`,
  `…MatrixTests` with no matrix, path bar tests under `InfoPanel`), and duplicate tests of the same behaviour
  beyond the two exact duplicates in 5.13.
- **About 30 "nothing happened after a fixed sleep" checks; the machine-local goldens** (`kind-strings.json`,
  `folder-size-trees.json`, `search-sort.json`); **tests that depend on installed apps, the system appearance or
  the keyboard layout.** A larger piece of work with little payoff per test.
- **Screenshot sizes in `docs/screenshots`** (about 8.7 MB).

## What the audits did not cover

- `Tests/FTFoundationTests` and `Tests/FTFileSystemTests`: about 75 of 160 files were read in full by the second
  audit; the rest only by mechanical scans (no-assertion bodies, `try?`, sleeps, gates, vocabulary).
- `Tests/FTOperationsTests`: `Analysis/CopyPasteAnalysisTests.swift`, `BatchRename/BatchRenameExecutionTests.swift`
  and `BatchRename/BatchRenamePlanAndRunTests.swift` were skimmed, not read.
- `Sources/FTFoundation/Search/JSLegacyRegExp.swift` was read but its translation rules were not exercised.
- Nothing was run in the app. Every scenario comes from reading code, except 1.2, 1.3 and 1.6, which were
  reproduced outside the repository, and the `fd` command in 1.6.
- The first audit recorded no coverage limits. Treat its claims as read from code, not run, which is why its
  items carry no [verified] label here.

## Log

Record here, with the date: items that did not hold, items skipped and why, the answer to each open question,
anything that differed from the plan, and anything found on the way that is not in this plan.

- 2026-11-10. Phase 1 taken in the first session; it depends on no open question. Baseline `scripts/ci.sh` at
  `c58b3fe` passed (3,877 tests). The plan was untracked in the main checkout; it is committed on the branch.
- 2026-11-10. 1.2 differs from the plan in two ways. (a) A queued folder is opened by its path, but a path of
  `PATH_MAX` or more is opened a part at a time with `openat`: opening by the whole path alone would have broken
  `measuresFoldersWhosePathsAreLongerThanPATHMAX`, which shows folders deeper than 1,024 bytes are meant to be
  measured. (b) `ATTR_CMN_DEVID` was not added: the `fstat` stays, moved into the worker that opens the folder,
  because that open can land on another volume (an automount trigger, a folder replaced since it was listed),
  which a device read at listing time cannot see. A folder found unwalkable after it was queued is marked
  skipped and never put on the finished list, as before. The test needs nested folders: 1,000 empty or
  file-only subfolders passed before the fix, as four workers empty the queue as fast as one listing fills it.
- 2026-11-10. 1.3 also covers the two de-duplicating loops in `treeReloadPaths`, which were quadratic in the
  destinations on the same call. Before the fix the new 20,000-path test did not finish in 10 minutes; after it,
  0.63 s of CPU time in a debug build. Found, not fixed (same shape, next to it): in `ExplorerWriteSession`,
  `leftPaths` filters each left path against `result.replacedPaths` with `contains`, quadratic for a Replace of
  many items.
- 2026-11-10. 1.4 skipped, left for the owner. The finding holds, but the fix as written makes a new fault. `goBack`
  and `goForward` take their target from the history index already moved by a Back still in flight, so two quick
  Backs on [A, B, C] go to B and then A. Restoring the index to `leftPlace.index` when a navigation returns
  `.superseded` would put it back on C after the second Back has moved it to A, whichever read comes back first,
  leaving A on screen with the index on C. A fix that holds: remember the index of the folder on screen while a
  move is ahead of it; restore it when a push, a replace or a read in place (`.none`) starts, and when the current
  navigation fails with the old folder on screen; do nothing on `.superseded`, and leave it as moved when another
  Back, Forward or jump starts.
- 2026-11-10. 1.7 also covers the results a new search keeps from the last one while typing (`keepMatching` in
  `startSearch`): with only `canRefine` changed, typing after Settings turned subfolders off started a new search
  but kept the old subfolder matches on screen. The same remembered options decide both.
- 2026-11-10. 1.8: the box is cleared from the scrim's `onDismiss` (a new `alsoOnDismiss`), not only after
  `dismiss()` in `answer`: the review alert in `CopyPastePresenters` has no window-close closure, and `onDismiss`
  runs on every way the dialog goes. Tested for `ask` (answered, and its window closed) and `askName`; the review
  alert's change is covered only by its existing tests. Noted for 1.7 by its review, not changed: Return on the
  same text with the same scope after a Settings edit still answers "already on screen" without searching again,
  which fits "a Settings edit runs nothing again".
- 2026-11-10. 1.10: `InfoIconView.shown` became `private(set)` as a read-only seam for the test. Found, not
  fixed (neighbouring, outside the item): `rebuildInPlace` doesn't set `name.toolTip` either, so another
  selection of the same shape keeps the previous `nameTooltip`.
- 2026-11-10. The owner: leave 1.4 for now. It stays unticked, with the proposed fix above.
- 2026-11-10. Phase 2 started. Q1: yes, `scripts/release.sh` runs the GUI tests. Q2: as recommended; a recording
  that still cannot run through the engine is deleted with the tests that only describe it.
- 2026-11-10. 2.1: an incremental build does not report warnings again for files it doesn't compile, so
  `ci.sh --full` (which `release.sh` now runs) starts with `swift package clean`. `EmptyPageHost` was not deleted:
  Settings is released when its window closes, so a page built after that can't be ruled out. It became one
  shared instance, which the page's weak reference can keep, in place of a temporary. Whole `--full` run: clean
  build 41 s, tests 52 s, release app 87 s.
- 2026-11-10. 2.7: every GUI-gated test passed before anything changed: 25 tests (1 in FTFileSystemTests, 24 in
  11 FTAppKitTests suites), not about 44. `FirstClickGUITests` and `ListScrollExtentGUITests` were already inside
  `ExplorerWindowGUITests`; only `RealDiskImageTests` and `DiskImageMounterHandOffTests` were missed by the filter.
- 2026-11-10. 2.8: `LargeFileTests.swift` keeps its name: what is left in it is the `LargeFileTests` switch alone.
  The suite's runs went from four bundles to one (12 fewer test runs, 3,889 to 3,877).
- 2026-11-10. 2.9: all 7 `exec-stop` and all 14 `exec-crash` recordings run through the engine and match, so no
  recording was deleted (Q2) and the six shape tests stay, each saying it guards the shape. The crash is injected
  at the journal write the recordings name, as `SwiftBatchRenameRun` already did for batch rename: after it the
  disk, the journal and the record refuse everything, a question asked after it stops the paste (which can't reach
  the disk), and `recoverWrites` runs on what was left. One difference of form only: the recordings give a
  Replace's recovery log `"path": null`, and the app's logger, which takes text alone, leaves the key out; the
  harness writes it as null. The window "staged recorded, old item still at its final name" is "folder Replace by
  copy, crashed after journal write 2". `InterruptedReplaceThroughTheEngineTests` adds a file and a folder moved on
  one disk. Checked that a crash one write later, or a recovery that does nothing, fails them.
- 2026-11-10. 2.11: found, not changed: 24 more `_ = await waitUntil` in 14 files of FTAppKitTests (the
  CopyPaste dialogs and sheet look, the batch rename sheet fixture, InfoViews, Info, ReviewRowWidth, HiddenItemLook,
  TextFitLayout, List, Alert, LocalWriteActions, NativeWindowsGUI, ContextMenuRoutes, ClipboardWindow). Each needs
  reading: some are followed by a check of their own.
- 2026-11-10. 2.9, after its review: the crash tests compare folders whole, file for file, and the harness's disk
  passes `copyMetadataToRunInPlace` through. Known limit, not changed: the crash falls only between journal
  writes, never inside a copy, so a partly written file at the staging path is reached only by the hand-built
  recovery tests (`CopyPasteRecovery.swift` near 255).
- 2026-11-10. 2.12: 919 folders left by earlier runs are in `$TMPDIR` (`filetrail-test-trash-*`,
  `filetrail-selection-writes-*`, `filetrail-drag*`); not deleted. A full run after the change added none.
- 2026-11-10. 2.13: the window's static seams are restored by a test trait (`.restoresWindowSeams`) and not by a
  `defer`, as the tests put them back in an `async` close that a `defer` can't await. `runBatchRename` was never
  put back at all. `AutomationPrefs` (debug only) gained `unregister`, so the handler a test adds goes again.
- 2026-11-10. 2.15: `scenarioTreesBuildHereAsRecorded` was deleted rather than merged: since 2.9 every execution
  and analysis suite runs through an engine whose check compares the recorded `before` with the rest. The replay
  builds no tree and mounts no image. Replay 7.8 s to 1.1 s; the 8 s tree check gone; the bundle's wall time is
  bound by the engine checks (about 10 s), which run in parallel.
- 2026-11-10. 2.10: the analysis of each site was done by three read-only agents in parallel, one per bundle; each
  fix was applied and checked here, and each was seen to fail with the behaviour broken. Did not hold, so left:
  `WriteServicePasteTests.swift:208` (it can fail), `CompactListTests.swift:114` (it can fail),
  `FolderWatchStreamTests` and `FdSearchProcessTests` waits (their callers check the answer). The two rename tests
  that returned early on a disk minding case or accent spelling run on a shared APFS image. `InfoRowView` gained a
  `reducesMotion` seam, so its timer test doesn't depend on the Mac's setting. On APFS a copy is a clone, which
  carries mode and dates by itself: the copy-metadata tests fail only with both the clone and `COPYFILE_ALL`
  taken away.
- 2026-11-10. 2.14: the bundle order in `ci.sh` stays. With FTFoundationTests run beside every bundle the test step
  took 44 s and 47 s against 42 s and 43 s, and one of those runs failed
  `failsWithTheWritesErrnoWhenTheResourceForkCantBeWritten` (copyfile reported success without the fork; it passes
  alone, 5 of 5). That test's flakiness under load is not explained; noted, not changed. The two quit tests use a
  time limit on a wait that never ends by itself, in place of a wall-clock bound.
- 2026-11-10. 2.14, after its review: the two quit tests keep a loose clock bound (10 s) besides the time limit. A
  gate can't tell the 50 ms or 60 s wait they ask for from the quit's own 15 s, which a time limit of a minute lets
  through. That is the one clock bound left by this item, well clear of a busy Mac's delays.
- 2026-11-10. Phase 2 done. Phase 3 answers: Q3 not now (a full disk only stops the run); Q4 yes, flush the
  journal for the moved-item entry only; Q5 as recommended (surplus tabs go to new windows with the tab-limit notice,
  or the drop is refused where AppKit allows).
- 2026-11-10. 3A.7: the answer with no Trash path is now "restored" only when nothing was taken off the item
  (`!lifted.any`), not `false` outright: an unlocked item has nothing to put back.
- 2026-11-10. 3A.8 skipped, waits for the owner: the claim holds (a Replace asked again counts its first copy too,
  so a test saw completed > total), and the fix (take the counts back in `undoStaging`) works, but it changes
  frozen recordings the item doesn't name: in `exec-copy` "Replace on a disk without a Trash, skipped: nothing
  changes" and "Replace on a FAT32 disk without a Trash, skipped: nothing changes", and in `exec-stop` "stopped while
  building a replacement folder: the old folder stays". Their progress events and `result.summary.completedByteCount`
  record the undone copy as done (4 bytes "copied" for a Replace that changed nothing). Fixing needs those cases'
  counts edited by hand.
- 2026-11-10. 3B.3 did not hold; nothing changed. A titled window given a frame far off every screen
  ((20000, 20000), screen nil) was moved onto the main screen by AppKit when shown (`orderFront`, to (1266, 784)),
  checked with a standalone AppKit script on macOS 27.
- 2026-11-10. 3A.3 skipped, waits for the owner: the claim holds (nothing treats ENOSPC as final), but the fix
  changes four tests in `RuntimeSafetyWholeFolderTests.swift` (`WholeFolderTests`) that use a full disk only as "a
  file that can't be written": `copiesNothingOfAFolderWhoseIncompletePackageCantBeClearedAway`,
  `movesNothingOfAFolderSomeOfWhoseItemsCouldntBeCopied`, `copiesNothingOfAPackageSomeOfWhoseItemsCouldntBeCopied`,
  `putsAnOrdinaryFolderInPlaceWithWhatCouldBeCopied` (the last also pins the "put in place with what fitted"
  behaviour the fix reverses). Proposed: those tests use EIO for their failing file, and the item's own tests use
  ENOSPC.
- 2026-11-10. 3A.4 skipped, waits for the owner: the plan's premise is wrong (FAT and exFAT keep extended
  attributes in "._" files; `EmptyFilesOnFATTests` copies one there), and the `copy_status` comment in `copyfile.c`
  says a refused attribute is skipped on purpose (com.apple.provenance, which most files have), only the resource
  fork failing the copy. Files and folders do disagree (a folder whose metadata didn't copy is kept, a file isn't).
  Question for the owner: which rule should win; if "keep the source", compare the source's and the copy's
  attribute names after a move, leaving out those the kernel manages.
- 2026-11-10. 3A.1: an app moved by copy whose original can't be read afterwards is recorded as the copy made (as
  with one still there), so Undo puts the copy in the Trash rather than trying to move it back. Found, not fixed:
  `tryRemoveEmptySourceDirectory` (`ExecutionMoves.swift`) reads an unreadable moved folder as gone in the same way,
  so it is left without a word.
- 2026-11-10. 3A.6 holds only where the item was moved under the hidden name (the catch after the swap). The four
  earlier `try? undoStaging()` sites concern a copy the paste made, whose journal entry is kept and cleared at the
  next start by design; they are left. 3A.9 skipped, waits for the owner: the fix (journal entry removed only after
  the originals, and recovery reporting a staged moving copy found in place) changes `exec-crash.json`, "folder moved
  to another disk, crashed after journal write 3 of 3": in `output.after` and `output.recovery.after` the three
  `source/f`, `source/f/a.txt`, `source/f/b.txt` entries go. Found, not fixed: a Replace by a move to another disk
  has the same silent duplicate (no `movingCopy`, entry removed before `removeMovedSources`).
- 2026-11-10. 3A.5 and 3A.6, after their review: recovery's `moveUnlocked` opens a read-only folder for the move
  (as the paste does), or the folder 3A.5 now leaves read-only could stay hidden where the rename of a read-only
  folder is refused (macOS 14, by the code's own comment; macOS 27 allows it within one folder). The 3A.6 path gives
  the waiting item its lock and mode back too, and says when the old item went to the Trash. Left: its message
  promises the next start even with no journal, which the app always has.
- 2026-11-10. The owner: 3A.3 yes, the four `WholeFolderTests` use EIO for their failing file; 3A.8 yes, hand-edit
  the counts of the three recordings named above; 3A.9 yes, hand-edit the exec-crash case named above; 3A.4 leave as
  is (closed: a refused attribute other than the resource fork is skipped on purpose, and the file's original goes).
- 2026-11-10. 3A.3: not covered, noted: EDQUOT, the EIO an older macOS gives for a full FAT disk, and an ENOSPC
  wrapped in `StagingCleanupError` (its code is nil) don't end the run.
- 2026-11-10. 3A.9, after its review: the move found in place has an outcome of its own (`foundInPlace`), told as
  "what was left of the original is still in …, perhaps not all of it"; its source is read only once its disk has
  answered in time, and an unreadable or unconnected source keeps the record for a retry. Found, not fixed: the
  `staged: true` record of a folder move to another disk isn't flushed, and `discard()` rewrites it unflushed, so a
  power cut can leave a record naming a folder at the final path that isn't the paste's; `executeStagedDirectory`
  never takes back the counts its children added when it discards its copy (as 3A.8 did for a Replace), so a folder
  copy ended by a full disk or a Stop still counts what it wrote; and a new folder inside a merge that a full disk
  ends has no item of its own in the result, as with a Stop.
- 2026-11-10. Flaky, noted: in one run made slow by load (tests 123 s), `ClipboardWindowTests.copyFillsTheClipboardAndTheButtonSaysSo`
  failed at `ExplorerHarness.swift:82` (`waitUntil { read && tab.workspace.isReady }`) after 0.5 s, though that
  wait allows 30 s; it passed on the rerun. Worth a look: the half second doesn't fit the wait's limit.
- 2026-11-10. 3G.1 did not hold; nothing changed. A cut is pasted as a Move To from every place that starts one
  (Paste from the menu, the keys and the right-click menu, a drag that moves, Try Again), so the result sheet says
  "couldn't be moved" and the planned-skip toast "Moved 3 items".
- 2026-11-10. Review of the 3C, 3D, 3F and 3G commits. Changed after it: Show in Finder looks for a link itself, not
  what it points to, so a broken link (which the list shows) is revealed; and a review of a drop from another app
  dismissed while its start is under way (Escape after Start) no longer forgets the drop, which the start then takes
  (no test: nothing can hold a start part way). Found, not fixed:
  - 3F.2: now that the 10 s limit really ends the wait, a change macOS makes after it (if it ever asks the person
    first) is told as "macOS didn't answer." and the lists cached meanwhile stay until the window is next focused.
    Worth trying by hand: Always Open With on a kind, and see whether macOS asks.
  - 3C.5: the jobs keep a finished answer, but `WindowFolderSizes.cancel` still sets the window's entry to idle, so a
    Stop pressed between a job's end and the next poll shows no size until the folder is asked about again.
  - 3D.5: a drop whose review is then cancelled leaves `pendingTreeSelectionPath` set, as Duplicate's does.
  - 3C.3: with Quick Look open while another window becomes key, the panel ends its control and shows no item.
  - 3F.1: a state file that can't be encoded calls `onPersistError` at every later save.
- 2026-11-10. Flaky, noted: `NativeCopyTests.failsWithTheWritesErrnoWhenTheResourceForkCantBeWritten` once copied a
  fork of the free space plus 2 MB onto a full disk image without an error in a whole-suite run; it passed alone three
  times and in the rerun. What APFS gives back after the fill seems to vary with load. It failed the same way in a
  later full run (2 of about 25 whole-suite runs that day), passed 5 of 5 alone, and its code is unchanged on this
  branch.
