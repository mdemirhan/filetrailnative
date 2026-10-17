# Near-duplicate audit: windowless tests in Tests/FTAppKitTests

Read-only audit. No test was run, none was changed or removed. All paths are under `Tests/FTAppKitTests/`. Line numbers
are the `@Test` line. The original is `/Users/tcmudemirhan/src/tsproj/filetrail`; T- ids are from
`docs/port/parity/tests.tsv`.

## 1. Summary

| | |
|---|---|
| `@Test` functions in the scoped files (before the gate exclusion) | 350 |
| Reviewed (the one gated `PageWindowsTests.opensOneWindowOfEachKind...` excluded; the gated GUI suites were never opened) | 349 (of them 100 have no T- id) |
| Groups of near-duplicates or overlapping tests found | 14 |
| Tests that could go, safe (nothing falls below the original's coverage) | 7 |
| Tests that could go, optional (bar-safe, but a small unique assertion or the only test of a one-line wiring goes with them) | 5 |
| Tests that fold into a parameterized test with the same T- ids (the original has them as separate tests; nothing removed) | 21 tests in 5 groups |
| Non-gated tests that show a window or make the app active | 1 certain, 1 borderline |

How "scoped files" was read: every file under Tests/FTAppKitTests except NativeWindowsGUITests, ToolbarGUITests,
ContextMenuGUITests, SidebarGUITests, NotificationsGUITests, InfoGUITests, ListGUITests, ToolbarStateGUITests,
WorkspaceGUITests and ReviewRowWidthTests. `Help/PageWindowsTests.swift` also holds `HelpMenuTests` (2 tests, in scope).
The Automation tests (28) have no original; they are the port's own tooling and were only checked for overlap with each
other.

Findings that shaped the grouping:
- Several T- ids are cited by two Swift tests because the Swift port split one original test across layers
  (QuitCoordinator vs ExplorerWindowController, key vs routing in the menu). 16 ids are cited by more than one test.
  Where the second test adds nothing, it is in section 3.
- `tests.tsv` is out of step with the Swift comments for 48 of the 286 T- ids cited in scope: they are still `todo`
  (or `ported` with no swiftTest) although a test cites them. Examples: T-cc926cf5, T-1849bac0, T-3ab16b37,
  T-a7b14a6b. Not part of the ask, but it affects any removal that needs the tsv updated.

## 2. Groups

Each group: tests (file:line, name, T- ids), what they share, which one to keep, and whether the original has them
separately.

### G1. LaunchContext: a target that is not a usable folder
- `App/LaunchContextTests.swift:72` `ignoresNonDirectoryTargets` (T-6201497f)
- `App/LaunchContextTests.swift:78` `ignoresMissingFolderTargets` (T-9d38cc4a)

Shared: same `resolve(["filetrail","--folder",x], isDirectory: { _ in false }) == nil`; only the path string differs
("file.txt" vs "missing"). No new branch.
Keep: `ignoresMissingFolderTargets`, with one more input.
Original has them separately (two `it` blocks in launchContext.test.ts): keep unless the user decides otherwise.

### G2. StartupTabs: the single-view resolution (nine tests, one helper)
- `Windows/StartupTabsTests.swift:37` `keepsAHandPickedTreeRootWhenTheLastVisitedFolderIsInsideIt` (T-5c8a8dd9)
- `:44` `keepsAHandPickedTreeRootThatIsTheLastVisitedFolderItself` (T-d09ea64b)
- `:50` `usesHomeAsTheTreeRootWhen...InsideHomeButOutsideTheSavedRoot` (T-68eb3d87)
- `:56` `usesSlashAsTheTreeRootWhen...AboveHome...` (T-b8580b99)
- `:62` `usesThePersistedSlashRootWhenRestoringAPathInsideHome` (T-b43fba42)
- `:69` `usesTheExplicitStartupFolderInsteadOfTheLastVisitedFolder` (T-d612583c)
- `:77` `usesHomeAsTheTreeRootWhenTheExplicitStartupFolderIsInsideHome` (T-ae917c88)
- `:85` `startsAtHomeWhenTheLastSessionIsNotReopened` (T-d3b23be1)
- `:93` `restoresASelectedFavoritePathWhenTheRestoredFolderExactlyMatchesIt` (T-d0468635)

Shared: each calls `single(restore:last:favorite:root:startupFolder:)` and `expect(tab, path:, root:, favorite:)`;
they differ by input rows. Most hit a distinct branch of the root decision, so this is a table, not a pure
duplicate. The closest pair is T-5c8a8dd9 and T-d09ea64b (last folder inside the root vs equal to it).
Keep: all, as one parameterized `@Test(arguments:)` that keeps the nine T- ids in the comment.
Original has them separately (nine `it` blocks in startupNavigation.test.ts): keep unless the user decides otherwise.

### G3. ToolbarIcon: "distinct icons" pairs
- `Toolbar/ToolbarIconTests.swift:67` `rendersDistinctIconsForCopyVsCopyPath` (T-93d6707c)
- `:79` `rendersDistinctIconsForEditVsRename` (T-f9b932ba)
- `:53` `rendersSpecializedShapesForListDetailsSearchClearAndStopIcons` (T-09f56d9d) is the same shape over five names.

Shared: `signature(a) != signature(b)`. Keep: any one form, parameterized over the pairs.
Original has them separately (ToolbarIcon.test.tsx): keep unless the user decides otherwise.

### G4. Tooltip scheduler: show and hide on hover
- `Tooltips/TooltipSchedulerTests.swift:68` `showsAControlsTitleAfterThePointerRestsOnIt` (T-9e960311)
- `:77` `findsTheTitleFromAnIconInsideTheControl` (T-cc926cf5)
- `:87` `takesTheTitleOffWhileHoveringAndPutsItBackAfterwards` (T-1849bac0)
- `:172` `leavesFileAndFolderRowsLabelledButtonsAndRowControlsToThemselves` (T-bea514b5)

Shared: in AppKit the DOM-specific cases collapse. T-cc926cf5 is `hover(trash)` twice then wait (the first test plus one
`box.shown == ["Trash"]`). T-1849bac0 is hover, leave, wait, nothing shown (also what `waitsAgain...` and
`hidesWhenAKey...` do). T-bea514b5 is `hover(nil)` then nothing, plus a type check. Also `:149` loops the same
`dismiss()` assertion three times with identical steps.
Keep: `:68`, `:87`; the other two add little.
Original has them separately: keep unless the user decides otherwise.

### G5. Menu router: another window focused, or no explorer window
- `Menus/MenuCommandRouterTests.swift:182` `doesNothingWithNoExplorerWindowToSendTo` (T-1b991ea9): no `#expect` at all
- `:191` `withNoExplorerWindowOpensOneForNewWindowAndTheGoMenusPlaces` (T-5fa81f0e): its "Back" step also does nothing
- `:214` `leavesTheExplorerAloneWhenAnotherWindowIsFocused` (T-a26df59b): Go > Back, explorer gets nothing
- `:164` `hasTheHostOpenANewWindowWhileAnotherWindowIsFocused` (T-3c672ecf): also chooses Go > Back, asserts `front.performed.isEmpty`

Shared: the two pairs repeat the same assertions on the same path. Keep: `:191` and `:164` (they assert); fold
`:182` and `:214` into them.
Original has them separately (four `it` blocks in appMenu.test.ts): keep unless the user decides otherwise.

### G6. Settings menu item (original has ONE test)
- `Menus/ApplicationMenuLayoutTests.swift:209` `keepsSettingsOnItsFixedKey` (T-96221c32)
- `Menus/MenuCommandRouterTests.swift:226` `opensTheSettingsWindowDirectlyWhenTheHostProvidesIt` (T-96221c32)
- `Menus/ApplicationMenuLayoutTests.swift:72` `namesTheAppItselfRatherThanItsPackage` (T-4478f617)

Shared: appMenu.test.ts has one `it` ("opens the Settings window directly", lines 462-475) that checks the accelerator
and the click. The Swift port split it. `keepsSettingsOnItsFixedKey` asserts `accelerator == "Command+,"` (already at
`:84` of `namesTheAppItself...`) and `target === router` (already asserted by `choose()` in the routing test).
Keep: `:226` and `:72`. Remove `:209` (safe, section 3).

### G7. Help menu opens Help (port-only repeat of a ported test)
- `Help/PageWindowsTests.swift:35` `theHelpMenuOpensHelpOnThePageItNames` (no T- id; HelpMenuTests)
- `Menus/MenuCommandRouterTests.swift:251` `opensHelpsWindowFromAnyWindowOnTheKeyboardShortcutsPageForThatItem` (T-6ec0c9ff)
- `Menus/ApplicationMenuLayoutTests.swift:18` `laysTheMenusOutTheWayAMacAppDoes` (T-b65028eb) has the Help titles.

Shared: the port-only test builds the same menu, chooses the two Help items, and asserts `opened == [nil, .shortcuts]`
and the two titles; both assertions are in the ported tests. Keep the two ported tests. Remove `:35` (safe).
Original: the port-only test has no counterpart there.

### G8. Closing the last window asks first (original has ONE test)
- `App/QuitWhileBusyTests.swift:221` `asksBeforeClosingTheLastWindowStopsACopyAndKeepsWorkingWhenToldTo` (QuitCoordinatorTests, T-0e9eff11)
- `Windows/ExplorerWindowControllerTests.swift:364` same name (T-0e9eff11)

Shared: explorerWindowController.test.ts has one `it` (lines 746-770). The controller test is its port and runs the
real QuitCoordinator. The coordinator-level one asserts the same buttons, keep-working and stop outcomes through
`askToStopOperation`. Its other two assertions are covered elsewhere: the "If you close the window now" detail by
`QuitWhileBusyTests.swift:70` (T-3a562d4c), and "rename asks nothing" by `ExplorerWindowControllerTests.swift:489` (T-f882affc).
Keep: the controller test. Remove `QuitWhileBusyTests.swift:221` (safe).
Related, kept: `QuitWhileBusyTests.swift:182` and `ExplorerWindowControllerTests.swift:392` (both T-8e5a9006) overlap on
"second quit while the question is open", but the coordinator test also asserts `first == .keptWorking` and the
forward hook, so they stay.

### G9. A preference change reaches the appearance
- `Appearance/PreferenceChannelTests.swift:46` `aChangeOfTheWindowsOwnSessionIsNotToldToTheApp` (no T- id)
- `Windows/ExplorerWindowOrderTests.swift:108` `keepsAWindowsOwnKeysToItAndTellsTheOtherWindowsOnlyTheSharedOnes` (T-f1cf1841)
- `Appearance/AppearanceModelTests.swift:164` `followsTheThemeAndAccentOfAPreferenceChange` (no T- id)
- `Appearance/PreferenceChannelTests.swift:19` `aChangeOfThemeAndAccentReachesTheAppearance` (no T- id)

Shared: the first test's head (a window-only key such as treeWidth stays out of the patch, `senderID` kept) is
T-f1cf1841. Its tail (an unrelated change leaves the look alone) is the first half of `AppearanceModelTests:164`, and
weaker (the model starts `.dark` and stays `.dark`). `:19` is the only test of the channel feeding the real model, so
it stays. Keep: `ExplorerWindowOrderTests:108`, `AppearanceModelTests:164`, `PreferenceChannelTests:19`.
Remove `PreferenceChannelTests:46` (safe).

### G10. Accent validation (port-only pair)
- `Appearance/AppearanceModelTests.swift:97` `acceptsAPickedAccentOnlyAsAHexColor` (no T- id, B-DLG-236)
- `Appearance/AppearanceModelTests.swift:137` `ignoresAccentsThatAreNotHexColors` (T-bede3752)

Shared: both call `model.apply(accent:)` with bad values and expect the old accent. `:97` has six rejects plus trim and
lower-casing; `:137` has three rejects plus "a model started with a bad accent has the default". Note T-bede3752 in the
original is "no-ops cleanly when no DOM is available", so neither test has a real original counterpart.
Keep: `:97`, with the "started with a bad accent" line folded in. `:137` could go after that (optional).

### G11. Accent hex asserted three times, and a placeholder
- `Appearance/AppearanceModelTests.swift:241` `theFavoriteIconsAreTheAccent` (T-a7b14a6b, marked N/A in its comment)
- `Appearance/AppearanceModelTests.swift:76` `usesOneAccentEverywhere` (T-3ab16b37), whose last line is the same
  `red.accent.solid.hexString == "#e8729a"` on the same literal
- `Appearance/AppearanceModelTests.swift:257` `hasNoRootElementToMount` (T-38688505, T-479129a0, both N/A in tests.tsv):
  the body is `#expect(true)`

Keep: `:76`. Remove `:241` and `:257` (safe). tests.tsv still lists T-a7b14a6b as `todo`; point it at `:76` or mark it
N/A when removing.

### G12. Automation tooling: scenario files
- `Automation/ScenarioTests.swift:64` `everyCheckedInScenarioParses`
- `Automation/AutomationStepsTests.swift:164` `everyScenarioIsTaggedAndNamesKnownElements`

Shared: both list the top-level `*.json` of `tools/capture/scenarios` and parse each; both assert
`steps.contains(.snapshot(name: "main"))`. The second adds tiers, features and element names (and requires
`files.count >= 20` against `>= 10`). Keep the second. Remove `ScenarioTests.swift:64` (safe).
Pairs looked at and kept, because each step type is a new branch: `ScenarioTests:12` vs `AutomationStepsTests:21`
(parse), and `ScenarioTests:54` vs `AutomationStepsTests:93` (reject).
Original: none; port tooling.

### G13. Help: choosing or asking for a topic clears the search, and one-line wiring
- `Help/HelpViewTests.swift:183` `choosingATopicLeavesSearchResults` (T-edac6214), via `clickTopic`
- `Help/HelpViewTests.swift:213` `aTopicAskedForReplacesTheSearchAndTheScroll` (no T- id, B-DLG-249), via `show(topic:)`:
  the same assertions (`query.isEmpty`, page title, `currentTopic`); `topicClicked` goes to the same path
- `Help/PageWindowsTests.swift:102` `aTopicAskedForShowsInTheOpenWindow` (no T- id): `HelpWindowController.show(topic:)` is
  `helpView.show(topic:)`, and the test only checks `activeTopic`
- `Help/PageWindowsTests.swift:90` `customizeOpensSettingsOnTheShortcutsTab` (no T- id): `HelpWindowController` only sets
  `helpView.onCustomizeShortcuts`, and `HelpViewTests.swift:109` (T-2e306242) already performs that button

Keep: `:183`, `:109`. The three port-only tests (`:213`, and the two in PageWindowsTests) could go (optional): the only
thing lost is proof that the controller forwards `show(topic:)` and the callback.
Original: the port-only tests have no counterpart.

### G14. Launch context given to a window as it is made
- `Windows/ExplorerWindowControllerTests.swift:140` `givesTheLaunchFolderToTheWindowAsItIsMade` (comment cites N/A T-e48c6be2, T-29244b8d)
- `Windows/ExplorerWindowControllerTests.swift:125` `opensAWindowWhereTheLastOneClosedToRunACommandChosenWithNoneOpen` (T-04c9c8d8)
- `Windows/ExplorerWindowControllerTests.swift:12` (T-2fbcbb64) asserts the same context through `launchContext(for:)`

Shared: `launches[recordID] == ExplorerLaunchContext(...)`, differing only by the input (startup folder vs initial
command). A slightly different path (`openStartupWindows` vs `openDefaultWindow`), so optional, not safe.
Keep: `:125`, `:12`. `:140` could go (optional).

### Looked at and kept (not groups)
- Same T- id, different code: ShellActions vs ExplorerWindowController for T-12d3f71a, T-a6795006, T-55a74b0a, T-f65a90ad.
  `ShellActionsTests.swift:32` `opensNoWindowWhileQuitting` (T-1e0a75b0) looked redundant with T-de9e432d, but it is the
  only test of the `!shutdownInProgress` guard on the bring-to-front branch of `ShellActions.activate`.
- `InfoViewsTests.swift:51` and `:200` (300 ms spinner): two views, two code paths.
- `Theme.selection` tests (`WindowActivityTests.swift:70`, `:88`, `:94`) and `ContentModelTests.swift:102`: `RowColors.make`
  has its own logic; only one assertion (`== accent.selectionBg`) repeats.
- `AcknowledgementsWindowTests.swift:94` repeats the Escape-closes check of `AboutWindowTests.swift:137` (T-0ec7feeb)
  inside a bigger test; the window-size assertions are unique. Trim the Escape lines if wanted.
- Weak, not duplicate: `InfoViewsTests.swift:51` ends with `... || true` (cannot fail); `GeometryDumpTests.swift:87`
  only asserts two `nil`s; `SidebarModelTests.swift:211` has `a || b` in one `#expect`.

## 3. Safe removals

Removing these cannot go below the original's coverage: the port-only ones repeat a ported test, the split ones leave
the original's one test fully covered.

| # | Test (file:line) | T- ids | Covered by |
|---|---|---|---|
| 1 | `Help/PageWindowsTests.swift:35` `theHelpMenuOpensHelpOnThePageItNames` | none | `MenuCommandRouterTests.swift:251` (T-6ec0c9ff) and the Help titles at `ApplicationMenuLayoutTests.swift:18` |
| 2 | `Menus/ApplicationMenuLayoutTests.swift:209` `keepsSettingsOnItsFixedKey` | T-96221c32 | `ApplicationMenuLayoutTests.swift:72` (accelerator) and `MenuCommandRouterTests.swift:226` (target and routing) |
| 3 | `Appearance/PreferenceChannelTests.swift:46` `aChangeOfTheWindowsOwnSessionIsNotToldToTheApp` | none | `ExplorerWindowOrderTests.swift:108` (T-f1cf1841) and `AppearanceModelTests.swift:164` |
| 4 | `Automation/ScenarioTests.swift:64` `everyCheckedInScenarioParses` | none | `AutomationStepsTests.swift:164` |
| 5 | `App/QuitWhileBusyTests.swift:221` `asksBeforeClosingTheLastWindowStopsACopyAndKeepsWorkingWhenToldTo` | T-0e9eff11 | `ExplorerWindowControllerTests.swift:364`, `:489`, and `QuitWhileBusyTests.swift:70` |
| 6 | `Appearance/AppearanceModelTests.swift:257` `hasNoRootElementToMount` | T-38688505, T-479129a0 (N/A) | nothing to cover: the body is `#expect(true)`; keep the N/A comment lines elsewhere |
| 7 | `Appearance/AppearanceModelTests.swift:241` `theFavoriteIconsAreTheAccent` | T-a7b14a6b (N/A, tsv says todo) | `AppearanceModelTests.swift:76` asserts the same value |

Optional removals (bar-safe, but each takes a small unique assertion or the only test of a wiring line with it; the
user decides):

| # | Test (file:line) | Why optional |
|---|---|---|
| 8 | `Appearance/AppearanceModelTests.swift:137` `ignoresAccentsThatAreNotHexColors` (T-bede3752) | fold its "started with a bad accent" line into `:97` first |
| 9 | `Help/HelpViewTests.swift:213` `aTopicAskedForReplacesTheSearchAndTheScroll` | same outcome as `:183` (T-edac6214) |
| 10 | `Help/PageWindowsTests.swift:102` `aTopicAskedForShowsInTheOpenWindow` | the only proof the controller forwards `show(topic:)` |
| 11 | `Help/PageWindowsTests.swift:90` `customizeOpensSettingsOnTheShortcutsTab` | the only proof the controller forwards the Customize callback |
| 12 | `Windows/ExplorerWindowControllerTests.swift:140` `givesTheLaunchFolderToTheWindowAsItIsMade` | covers the startup path of `createWindow`, same shape as T-04c9c8d8 |

Counting: 7 safe, plus 5 optional (rows 8 to 12). Tests that fold into a parameterized test without removing a T- id: G1, G2, G3, G4, G5 (2 + 9 + 3 + 3 + 4 = 21 tests).

## 4. Non-gated tests that show a window or make the app active

Searched the in-scope files for `orderFront`, `makeKeyAndOrderFront`, `orderBack`, `NSApp.activate`, `.activate(`, `runModal`,
`beginSheet`, `showWindow`, `postEvent`, `CGEvent`, and checked the helpers they call (`WindowTestKit`, `MenuTestSupport`,
`makeOffscreenWindow`) and the Sources they reach (`PageWindow.present` and `AppDelegate` are not reached; the
`QuitCoordinator` tests install a `showStopQuestion` hook, so no alert runs).

1. Certain: `Automation/AutomationStepsTests.swift:327` `findsElementsByNameTextAndPlace` calls `window.orderBack(nil)` at
   `:334` (undone by `orderOut` in a `defer` at `:335`). That puts a 400 by 300 borderless window on screen behind the other
   windows for the length of the test. It does not activate the app. The test is not gated (it is only under `#if DEBUG`).
   Fix: drop `orderBack`; `ElementFinder.find` should work on an unshown window, or gate the test with
   `FILETRAIL_GUI_TESTS`.
2. Borderline: `Menus/ApplicationMenuSyncTests.swift:120` `countsASheetAsItsExplorerWindow` calls
   `a.window?.beginSheet(sheet) { _ in }` at `:124` on a window that was never ordered front. A sheet on a hidden parent
   is not normally drawn, so this probably shows nothing, but it is the one remaining AppKit window-system call in the
   windowless set. Fix if wanted: assert the sheet-to-parent lookup without `beginSheet`, or gate it.

Nothing else found: no `NSApp.activate`, `runModal` or posted events in scope. `ShellActionsTests` calls
`ShellActions.activate(...)`, which is a function of that name on a fake host and does not touch NSApp. `NSEvent`s in
`InfoViewsTests.swift:357`, `ToolbarDrawingTests.swift:74` and `AutomationStepsTests.swift:370` are built and handed to a
method, never posted. `AppearanceModelTests.swift:215` and `AutomationStepsTests.swift:220` set `NSApp.appearance`, which
is not activation. All other windows come from `makeOffscreenWindow()` or `NSWindow(... defer: true)` and are never ordered
front.
