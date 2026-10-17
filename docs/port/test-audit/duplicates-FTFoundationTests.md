# Near-duplicate tests in Tests/FTFoundationTests

Read-only audit by reading the tests, the code they call, the original's test files and `docs/port/parity/tests.tsv`. No tests or apps were run and no test was changed. All paths below are under `Tests/FTFoundationTests/`.

## 1. Summary

| | |
|---|---|
| @Test functions reviewed | 606 in 57 files (parameterized `@Test(arguments:)` and golden suites each count as one) |
| Of those, Swift-added (no tests.tsv carrier, no original T- id) | 151 |
| Groups of near-duplicates found | 17 (9 multi-test groups, 8 single-test repeats across files) |
| Tests that could go | 25 (4.1%) |
| Safe removals (do not go below the original's bar) | 12 |
| Removals that need the user's decision (the original has them as separate tests) | 13 |

How "safe" was judged. A removal is safe when either (a) the test has no T- id and nothing in the original behind it (a Swift-added test) and every assertion in it is already made by another test or by a golden, or (b) its T- id is also cited by a surviving test that checks the same behavior. A test whose T- id has no other carrier is never safe, even if it repeats another test's shape.

The shape of what was found. The port mirrors the original one for one, so most repeats are the original's own repeats. The original keeps small variants as separate `it(...)` cases (for example three shortcutTargets cases that reach the same line of `selectionPaths`). Those are groups 1 to 8: removing them goes below the original's count, so they are listed "keep unless the user decides otherwise". Groups 9 to 17 are the real savings.

Citations to update if any safe removal is made: `docs/port/parity/behaviors.tsv` rows B-INFO-192 and B-INFO-193 (group 17) and the evidence column of `features.md` F-042, F-063 (group 10) and F-910 (group 16). `tests.tsv` row T-fc2f1ec9 is `todo` with no Swift test, although two tests cite it (group 8).

## 2. Groups

### Group 1. Open/Edit with the tree pane active and no selected tree path
`Commands/ShortcutTargetsTests.swift`
- :70 `doesNotFallBackToTheCurrentTreePathForOpenWhenTheTreePaneIsFocused` (T-14dfb80a)
- :79 `doesNotFallBackToTheCurrentPathForOpenWhenFocusIsTemporarilyNullAfterTreeFocus` (T-91126de4)
- :97 `doesNotFallBackToTheCurrentPathForOpenWhenFocusIsNullAfterTreeFocus` (T-856b8ed6)
- :106 `doesNotFallBackToTheCurrentPathForEditWithoutAFileSelection` (T-6e6ba032)

Share: `openSelectionPaths` and `editSelectionPaths` both just call `selectionPaths`, whose only relevant branch is `activePane == .tree` with no `selectedTreePath` returning `[]`. All four tests reach that branch and assert `[]`.
Keep: T-14dfb80a (focused pane beats the last-focused one and the content selection is ignored) and T-856b8ed6 (`focusedPane ?? lastFocusedPane` takes the pane from `lastFocusedPane`).
Rest add nothing: T-91126de4 uses tree/tree, so it never has a null focus (its title says it does) and takes the same path as T-14dfb80a. T-6e6ba032 reaches the same function through the Edit wrapper, whose wiring T-ca291e45 (group 3) already shows.
Original: has all four as separate tests (shortcutTargets.test.ts; T-91126de4 and T-856b8ed6 even have the same title there). Original has them separately: keep unless the user decides otherwise. Could go: T-91126de4, T-6e6ba032 (2).

### Group 2. Terminal falls back to the current path when the tree pane is active
`Commands/ShortcutTargetsTests.swift`
- :20 `fallsBackToTheCurrentPathForTerminalWhenTheTreePaneIsFocused` (T-4a5d74d8)
- :29 `fallsBackToTheTreePathForTerminalWhenTheTreePaneIsFocused` (T-9801160c)
- :54 `fallsBackToTheCurrentPathForTerminalWhenFocusIsTemporarilyNullAfterTreeFocus` (T-b9e13056)

Share: `openInTerminalPaths`, active pane tree, no `selectedTreePath`, returns `[currentPath]`.
Keep: T-4a5d74d8 (focused tree beats a last-focused content pane that has a selection) and T-b9e13056 (null focus, uses `lastFocusedPane`).
Rest add nothing: T-9801160c is tree/tree with an empty content selection, the same branch as T-4a5d74d8 with fewer inputs.
Original has them separately: keep unless the user decides otherwise. Could go: T-9801160c (1).

### Group 3. The explicit selected tree path wins
`Commands/ShortcutTargetsTests.swift`
- :36 `prefersTheExplicitSelectedTreePathForTerminalWhenTheTreePaneIsFocused` (T-d34a2656)
- :88 `prefersTheExplicitSelectedTreePathForOpenWhenTheTreePaneIsFocused` (T-0741865c)
- :112 `prefersTheExplicitSelectedTreePathForEditWhenTheTreePaneIsFocused` (T-ca291e45)

Share: same input shape, `[selectedTreePath]` expected. Open and Edit use the same `selectionPaths` branch; Terminal has its own function and branch.
Keep: T-d34a2656 and T-ca291e45. T-0741865c only repeats the branch T-ca291e45 covers, and the Open wiring is shown by group 1.
Original has them separately: keep unless the user decides otherwise. Could go: T-0741865c (1).

### Group 4. Single-panel layout by width
`Help/ResponsiveLayoutTests.swift`
- :8 `returnsWideForLargeSinglePanelLayouts` (T-7750e04f, width 1280)
- :13 `returnsNarrowForMediumSinglePanelLayouts` (T-1c5474fe, width 920)
- :18 `returnsCompactForSmallSinglePanelLayouts` (T-1d40ab78, width 640)
- :23 `switchesAtTheBreakpoints` (Swift-added)

Share: one assertion each, differing only by width. `switchesAtTheBreakpoints` reaches all three results at the boundaries (1100, 1099.5, 760, 759.5, 0), so it covers every branch the three do.
Keep: `switchesAtTheBreakpoints`; if the three are dropped, cite T-7750e04f, T-1c5474fe, T-1d40ab78 on it (or fold the three widths into it).
Original has them separately (responsiveLayout.test.ts, three `it`s): keep unless the user decides otherwise. Could go: the three T- tests (3).

### Group 5. A folder with a package extension keeps its extension at the end
`Names/CopyPasteNamesTests.swift`
- :90 `keepsFolderNamesWholeExceptForBundles` (T-8db3141c; `Tool.app`)
- :97 `keepsTheExtensionAtTheEndForDocumentPackagesToo` (T-940505a6; `Talk.key`, `Trip.photoslibrary`)
- :103 `goesByWhatItIsToldAboutAFolderBeingAPackageBeforeItsExtension` (T-0635b28a; its third line `Backup.sparsebundle`)

Share: `splitNameExtension` tests `packageExtensions.contains(ext)`; `.app`, `.key`, `.photoslibrary`, `.sparsebundle` are members of the same set, so each assertion takes the same branch with another extension.
Keep: T-8db3141c and T-0635b28a (the explicit `isPackage` override is a different branch; its sparsebundle line is a repeat but the test stays).
Rest add nothing: T-940505a6 only adds more members of the same set.
Original has them separately (copyPasteNames.test.ts): keep unless the user decides otherwise. Could go: T-940505a6 (1).

### Group 6. First copy suffix when the destination is free
`Names/CopyPasteNamesTests.swift`
- :85 `usesTheFirstCopySuffixWhenTheDestinationIsStillFree` (T-0b9ea230; `fresh.txt` gives `fresh copy.txt`)
- :77 `keepsNamesThatOnlyLookALittleLikeCopies` (T-58e31428), :90 (T-8db3141c `report.v2`), :126 (T-4e1e808c) all assert a free destination getting ` copy`.

Share: same call, free disk, ` copy` inserted before the extension. T-0b9ea230 is the plain case that the others pass through on the way to their own point.
Keep: the others. Original has them separately: keep unless the user decides otherwise. Could go: T-0b9ea230 (1).

### Group 7. `AppPreferences.patch(from:)` carries values through
`Preferences/PreferencePatchTests.swift`
- :29 `carriesEveryPreferenceAWindowMayChange` (T-32d7e49f)
- :36 `carriesEachGroupOfPreferencesTheOriginalListsAsSent` (T-1f095054, T-7f92bce5, T-53d8323d, T-e6f6decc, T-ef11b04e, T-09050d18, T-c8cd6ef9, T-1bd1f865)
- :62 `carriesEachPreferenceByItselfAndNothingElse` (T-39ae895f)
- :70 `changesNothingWhenNothingIsSent` (T-3437fed8)
- :75 `keepsFalseZeroEmptyAndClearedValuesWhichAreChangesToo` (T-8b4cf80b)
- :93 `dropsKeysThatAreNotPreferences` (T-195759be)

Share: the port's `patch(from:)` is one line, `value.filter { keySet.contains($0.key) }`. The original maps each key explicitly, which is why it tests groups of keys and falsy values; here the passed-through value never matters.
Keep: T-39ae895f (every key alone, default values already include false, 0, null, `[]`, `{}`), T-195759be (unknown keys), T-3437fed8 (empty), T-32d7e49f (key list equals the encoded preferences).
Rest add nothing: the group test (its 8 T- ids are then carried by T-39ae895f) and T-8b4cf80b.
Original has them separately (preferencesPatch.test.ts and bootstrap.test.ts): keep unless the user decides otherwise. Could go: `carriesEachGroupOfPreferencesTheOriginalListsAsSent`, T-8b4cf80b (2 tests, 9 T- ids to re-point).

### Group 8. Layout constants asserted again and again
- `Layout/PaneWidthsTests.swift:14` `definesStableExplorerPaneConstraints` (T-83343b0d)
- `Layout/PaneWidthsTests.swift:28` `pagesTheSidebarTreeByTheRowHeightsTheStylesheetDraws` (cites T-13ea5c0d)
- `Layout/TopToolbarLayoutTests.swift:34` `hasTheSizesTheStylesheetLaysTheToolbarOutFrom` (cites T-fc2f1ec9)
- `ListLayout/DetailsLayoutTests.swift:17` `rowHeightsFollowTheDensity` (T-6f96314a)
- elsewhere: `Layout/ToolbarLayoutGoldenTests.swift:54` `theStylesheetSizesAreTheTokens` (cites T-fc2f1ec9, T-13ea5c0d), `Design/MetricsTests.swift:115` `everyMetricIsTheOriginalValue` (all tables), `Sidebar/SidebarKeyboardTests.swift:218` `pagesByTheRowsOnScreenAndStopsAtTheEnds` (T-13ea5c0d; asserts `regular == 26`, `compact == 21`).

Share: the same numbers (tree row heights 26/21, toolbar gaps and widths, pane limits, details row height) are typed into hand-written tests and checked again in the golden stylesheet test and in MetricsTests.
- `PaneWidthsTests.swift:28` is safe to remove: it is not the tests.tsv carrier of T-13ea5c0d (that is `pagesByTheRowsOnScreen...`), its two assertions are repeated word for word in `pagesByTheRowsOnScreen...`, and the golden and MetricsTests check them too.
- `TopToolbarLayoutTests.swift:34` is safe to remove: the golden stylesheet test cites T-fc2f1ec9 and compares a superset of its seven constants against the recorded values. tests.tsv has T-fc2f1ec9 as `todo`; point it at the golden test.
- `PaneWidthsTests.swift:14` (T-83343b0d) and `DetailsLayoutTests.swift:17` (T-6f96314a) are the only carriers of their T- ids. MetricsTests and the golden check the same values, but they cite neither id. Original has them separately (layoutTokens.test.ts, detailsLayout.test.ts): keep unless the user decides otherwise.
Could go: 2 safe, 2 on the user's decision.

### Group 9. Tree arrow keys tested through two implementations
`Sidebar/TreeViewTests.swift`
- :57 `expandsAndCollapsesTreeNodesOnHorizontalArrows` (T-eaf07a43)
- :70 `navigatesToParentAndRequestsLoadingForUnloadedNodes` (T-05d06d43)
- (:41 `movesThroughVisibleTreeRows`, T-c3c420b1, is not duplicated and stays)

`Sidebar/SidebarKeyboardTests.swift:86` `opensABranchWithRightGoesIntoItAndComesBackOutWithLeft` cites both ids, and tests.tsv already lists it (and `FTAppKitTests/theArrowKeysOpenABranchGoIntoItAndComeBackOut` for T-eaf07a43) as a carrier. It checks the same cases: Right on an unread folder loads, on an expanded one goes to the first child, on a collapsed one with subfolders expands; Left on an expanded one collapses, otherwise goes to the parent, and does nothing at the root.
Note: `TreeView.keyboardAction` has no caller in `Sources` other than its tests. The live path is `SidebarKeyboard.decide`. Removing the two tests leaves only T-c3c420b1 on that dead function; the user may want to delete the function with it and move T-c3c420b1's up/down/home/end cases to `SidebarKeyboardTests`, which already has the same checks in `movesThroughTheRowsAndSkipsTheHeadings`.
Safe removal (T-ids stay carried). Could go: 2.

### Groups 10 to 17. Swift-added tests whose assertions are already made elsewhere
All are Swift-added (no T- id, not the carrier of a T- id in tests.tsv). Safe removals.

10. `Names/NumberedNamesTests.swift:34` `numbersBeforeTheExtension`. The number-names golden (`Tests/Golden/number-names.json`, 220 cases, checked by `addNumberToNameMatchesTheReference` at :22, same F-042 F-063) has `Lisbon.jpg` as file and folder with " " and number 2, and `.env`. Update the F-042/F-063 evidence in features.md.
11. `Design/CSSTokenTests.swift:222` `inventoryColourTableSpotChecks`. `everyTokenHasAnEqualSwiftCounterpart` (:144) compares every palette token against the golden, and the golden holds the four values asserted here, in both themes (bg-base, text-secondary, context-menu-shadow, bg-hover).
12. `Design/CSSTokenTests.swift:217` `spacingScaleAndTypeScaleMatchTheInventory`. `MetricsTests.everyMetricIsTheOriginalValue` asserts the same spacing list and the `toolbar: 32` control height.
13. `Design/AccentPaletteTests.swift:95` `focusRingIsThreePixelsOfAccentAtHalfAlpha`. Covered by `--focus-ring` in `everyTokenHasAnEqualSwiftCounterpart` (default accent, golden value `0 0 0 3px rgba(0, 122, 255, 0.5)`).
14. `Design/AccentPaletteTests.swift:82` `yellowKeepsBlackButtonTextAndWhiteSelectionText`. The accent golden has `#ffc600` in both themes with `onSolid` `#000000`, `solidButton == solid`, `onSelection` `#ffffff`, and `goldenCoversPresetsAndRandomColors` asserts the preset is in it. The comment explaining why yellow is special can move to the golden test.
15. `Design/MetricsTests.swift:153` `metricsAreTheDesignTokens`. `Metrics.init` and `DesignTokens` call the same `.make(density:)` factories, so the equality cannot fail on its own; the values are checked by `everyMetricIsTheOriginalValue`.
16. `Contracts/ContractsNotApplicableTests.swift:13` `theContractLimitsStayAsTheOriginals`. `maxPathsPerRequest == 100_000` is repeated in `ItemNamesTests.swift:70` `limitsAreTheOriginals`, and `ItemNames.maxBytes == 255` is covered by `limitsNamesTo255BytesOfUTF8NotCharacters` (T-9277bcb1, :33). The N/A comment block stays; F-910 evidence in features.md points at the other test.
17. `ContextMenu/ToastsTests.swift:42` `aTwentyEightPointPathBarAndAThirtyPointInfoRowPutTheStackSixtyEightUp`. The same `offsetAboveBars` branch (highest of two bars + 10) as the two-bar case in `theStackRestsTenPointsAboveTheHighestBarAndTwelveFromTheEdgeWithNone` (:31). Removal needs a merge: move the 28/30-point case into that test and re-point behaviors.tsv B-INFO-192 and B-INFO-193 (they name the test).

## 3. Safe removals (12)

Tests that can go without dropping below the original's coverage:

| File:line | Test | Why |
|---|---|---|
| Sidebar/TreeViewTests.swift:57 | `expandsAndCollapsesTreeNodesOnHorizontalArrows` | T-eaf07a43 stays carried by SidebarKeyboardTests:86 (and FTAppKitTests) |
| Sidebar/TreeViewTests.swift:70 | `navigatesToParentAndRequestsLoadingForUnloadedNodes` | T-05d06d43 stays carried by SidebarKeyboardTests:86 |
| Layout/PaneWidthsTests.swift:28 | `pagesTheSidebarTreeByTheRowHeightsTheStylesheetDraws` | Swift-added; assertions repeated in SidebarKeyboardTests:218, the golden and MetricsTests |
| Layout/TopToolbarLayoutTests.swift:34 | `hasTheSizesTheStylesheetLaysTheToolbarOutFrom` | T-fc2f1ec9 stays carried by the golden stylesheet test (ToolbarLayoutGoldenTests:54) |
| Names/NumberedNamesTests.swift:34 | `numbersBeforeTheExtension` | covered by the number-names golden |
| Design/CSSTokenTests.swift:222 | `inventoryColourTableSpotChecks` | covered by every token compared to the golden |
| Design/CSSTokenTests.swift:217 | `spacingScaleAndTypeScaleMatchTheInventory` | repeated in MetricsTests |
| Design/AccentPaletteTests.swift:95 | `focusRingIsThreePixelsOfAccentAtHalfAlpha` | covered by the `--focus-ring` token |
| Design/AccentPaletteTests.swift:82 | `yellowKeepsBlackButtonTextAndWhiteSelectionText` | covered by the accent golden |
| Design/MetricsTests.swift:153 | `metricsAreTheDesignTokens` | both sides call the same factory |
| Contracts/ContractsNotApplicableTests.swift:13 | `theContractLimitsStayAsTheOriginals` | repeated in ItemNamesTests:70 and T-9277bcb1 |
| ContextMenu/ToastsTests.swift:42 | `aTwentyEightPointPathBarAndAThirtyPointInfoRowPutTheStackSixtyEightUp` | same branch as the two-bar case at :31 (merge it; update behaviors.tsv) |

## 4. Needing the user's decision (13)

Original has them as separate tests; removing them goes below the original's count:

- Group 1: T-91126de4 (`ShortcutTargetsTests:79`), T-6e6ba032 (:106)
- Group 2: T-9801160c (`ShortcutTargetsTests:29`)
- Group 3: T-0741865c (`ShortcutTargetsTests:88`)
- Group 4: T-7750e04f, T-1c5474fe, T-1d40ab78 (`ResponsiveLayoutTests:8,13,18`)
- Group 5: T-940505a6 (`CopyPasteNamesTests:97`)
- Group 6: T-0b9ea230 (`CopyPasteNamesTests:85`)
- Group 7: `carriesEachGroupOfPreferencesTheOriginalListsAsSent` (`PreferencePatchTests:36`, 8 T- ids), T-8b4cf80b (:75)
- Group 8: T-83343b0d (`PaneWidthsTests:14`), T-6f96314a (`DetailsLayoutTests:17`)

## 5. Looked at and not flagged

- Distinct branches, even if they look alike: the eight `SizeText.relativeDuration` unit tests (ms, s, min, h, day, month, year, negative), the five `StatusSummary.content` and three `selectionSize` state tests, the three `undoLabels` tests, the three `SizeOrder` modes, the `ShortcutPolicy` filesystem-folder vs favorite lists (different `treeFolderOnlyCommands` branch), the command vs raw-shortcut denylists, the `backEntries` and `forwardEntries` pair.
- Same expected values through separate implementations: `WriteEffects.isAffectedByChange` vs `ChangeMatcher` (T-f9bd792e vs the last lines of T-37d2531e); each has its own code and the random equivalence test ties them together.
- Per-key wiring: T-472f579d (theme) and T-fe1b8d68 (searchPatternMode) both go through the generic `choice(...)`, but each proves its own key is wired.
- Assertion-level repeats inside tests that have other content, so no whole test can go: `AppPreferencesTests:144` repeats the key-set equality of T-32d7e49f; `ToolbarItemsTests:118` repeats two tooltip labels of T-5890f92a; `ContextMenuRulesTests:97` and `:185` both loop the four Trash-hidden actions (same `trashHiddenActions`, different surface path); T-d06fc2bd and T-0cb7701a both check Rename with no selection; T-7c0d1c60 and T-9b208ff7 both check the open-item limit; `TooltipsTests` T-32e945b7 repeats T-77685469's formatting through the other overload.
- Golden suites, randomized equivalence tests (T-ec7ff9f5, T-107fe08c, WriteEffects, ChangeMatcher), and the performance tests were not flagged.
