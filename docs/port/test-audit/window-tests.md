# Window tests audit: keep, convert, drop

This is a read-only audit. Nothing was run and no test was changed. It covers every test gated by `FILETRAIL_GUI_TESTS` and decides, for each one, whether it stays an on-screen (e2e) test, becomes windowless, or is dropped. The goal is UI testing at the scale of the original app, which has 31 Playwright e2e tests that run only in CI.

## Completeness check

`grep -rn FILETRAIL_GUI_TESTS Tests Sources` finds three gates:

- the `@Suite` on `NativeWindowsGUITests`;
- the `@Suite` on `ExplorerWindowGUITests`;
- the one `@Test` in `PageWindowsTests`.

`ExplorerWindowGUITests` is extended by 9 nested suites: Toolbar, ToolbarState (it extends `ExplorerWindowGUITests.ToolbarGUITests`), ContextMenu, Sidebar, Notifications, Info, List, Workspace and ReviewRowWidth. That is the 11-file list in the brief, and no other FTAppKitTests file is gated.

- **Count:** the gated tests number **77**, not about 85. The DEBUG-only `automationStepsActOnTheTabInFrontAfterTheTabsChange` is one of them.
- **Not gated:** `ReviewRowWidthTests.swift` also holds `ReviewStaleDetailsTests` (2 tests). They are not gated and are not counted here. `PageWindowsTests.swift` holds 6 more tests that are not gated.
- **Outside the list:** a fourth gate sits in a different target: `Tests/FTFileSystemTests/DiskImages/DiskImageMounterHandOffTests.swift` (1 test, which launches Apple's DiskImageMounter). ui-check.js runs `swift test --filter FTAppKitTests`, so this test **never runs at a checkpoint**. It is listed at the end and is not in the totals.

## What the evidence shows

- **The menus are views, not real menus.** The toolbar's menus (`AppMenuPresenter`), the path bar's folder menu and the progress and notification cards are subviews added to the window's `contentView`. No test opens a real `NSMenu`. The context-menu tests build the `NSMenu` and call its delegate (`menuWillOpen`, `menuDidClose`, `menuNeedsUpdate`) by hand.
- **Most tests drive the views directly.** They call `accessibilityPerformPress()`, `onPress`, `onClick`, `onChoose`, `onSort`, `onDrag`, `pressHandle` or `pointerMoved`. They do not send events through the window, and all of these calls work on a window that is never ordered front.
- **Only a few tests deliver events through the window.** These use `window.sendEvent`, `makeFirstResponder` or the field editor:
  - the history menu's ↓ and Return keys;
  - Escape closing a menu;
  - right-clicks on the toolbar;
  - a real drag in Customize Toolbar, and the focus ring it leaves;
  - the sidebar's arrow keys;
  - Space for Quick Look;
  - the path editor.
- **Only window and tab management really needs windows on screen.** This means native tab groups, the tab bar, the Window menu, sheets, frames restored after a relaunch, and closing windows. NativeWindowsGUITests and the gated PageWindows test do this.
- **Many UI cases were unit tests in the original.** Most of the toolbar, sidebar, context-menu, list and notification cases port the original's jsdom component tests (`*.test.tsx`), not its e2e specs. The original ran them without a window.
- **Several cases are already covered without a window:**
  - FTFoundation's `ContextMenuGoldenTests`, `ContextMenuRulesTests`, `ToastsTests`, `TopToolbarLayoutTests`, `ToolbarLayoutGoldenTests`, `PaneWidthsTests` and `DetailsLayoutTests`;
  - FTAppKit's `SidebarModelTests`, `InfoViewsTests`, `ExplorerTabsTests`, `ExplorerWindowControllerTests` (with `FakeWindow`) and `StartupTabsTests`.

### How to convert (shared approach)

1. **Add a windowless harness.** Add a variant of `ExplorerHarness` that never calls `ExplorerTabGroup.show()`. A group that is never shown keeps its tabs, and each tab keeps its `NSWindow`, but nothing is put on screen. The harness then:
   - builds the startup tab, either through `ExplorerWindows` with a "don't present" seam, or with `MainWindowController(tab:frame:)` directly through `@testable`;
   - waits on `workspace.isReady` instead of `window.isVisible`;
   - lays out with `contentView.layoutSubtreeIfNeeded()`, as `harness.layout` already does.
2. **What still works without showing the window.** `setContentSize` still posts `didResizeNotification`, so the menus close on a resize as they do now. `window.sendEvent` still reaches the first responder. If an Escape sent through `sendEvent` fails in a converted test, call `AppMenuPresenter.shared.close()` or the customizer's cancel directly.
3. **Where tests only need a model or controller.** Some tests only need the model or the controller, such as `ToastCenter`, `ProgressCardModel` and `ContextMenuCoordinator` on a tab. Those don't need a window at all.

## 1. Summary

| File | Tests | Keep | Convert | Drop |
|---|---:|---:|---:|---:|
| Windows/NativeWindowsGUITests.swift | 15 | 12 | 1 | 2 |
| Toolbar/ToolbarGUITests.swift | 10 | 2 | 7 | 1 |
| Toolbar/ToolbarStateGUITests.swift | 5 | 2 | 3 | 0 |
| ContextMenus/ContextMenuGUITests.swift | 10 | 0 | 8 | 2 |
| Sidebar/SidebarGUITests.swift | 8 | 1 | 5 | 2 |
| Notifications/NotificationsGUITests.swift | 7 | 1 | 5 | 1 |
| InfoPanel/InfoGUITests.swift | 7 | 1 | 5 | 1 |
| Help/PageWindowsTests.swift (gated case only) | 1 | 1 | 0 | 0 |
| Content/ListGUITests.swift | 6 | 1 | 3 | 2 |
| Layout/WorkspaceGUITests.swift | 5 | 1 | 4 | 0 |
| Content/ReviewRowWidthTests.swift (gated suite) | 3 | 0 | 3 | 0 |
| **Total** | **77** | **22** | **44** | **11** |
| *Outside the list:* FTFileSystemTests/DiskImages/DiskImageMounterHandOffTests.swift | 1 | 1 | 0 | 0 |

That is **22 kept, below the 30 to 50 aimed for.** The evidence doesn't justify more than that: besides the windows and tabs, most tests check layout, cell contents or state through direct calls. If you want 30, the 8 tests that come closest are listed under "Borderline" at the end. Each would move from convert to keep.

## 2. Every test

### Windows/NativeWindowsGUITests.swift

| Test | Decision | Reason | Covered by (drop) |
|---|---|---|---|
| opensTabsMovesOneToAWindowOfItsOwnAndMergesTheWindowsBack | keep | Native tab groups: New Tab, Move Tab to New Window, Merge All Windows. Matches the e2e test windows.spec "moves a tab to a window of its own". | |
| closesAndReopensTabsAndStepsThroughThem | keep | Native tab selection, ⌘W, and ⇧⌘T on a real tab group. | |
| bringsBackEachWindowsPlaceTabsAndWhichWasInFrontAtTheNextLaunch | keep | Frames on screen, the window in front, quit and relaunch. Matches windows.spec "brings back each window's place". | |
| duplicatesATabWithItsHistoryRightAfterItAndInFrontButNoTabPastTheLimit | keep | File › Duplicate Tab through the menu router into a native tab group, with the tab limit. | |
| namesEachWindowInTheWindowMenuAfterItsTabsLabelAndTheToolbarAfterItsFolder | keep | AppKit's Window menu only lists windows that are ordered in. | |
| automationStepsActOnTheTabInFrontAfterTheTabsChange (DEBUG) | drop | Tests the capture harness's runner, not the app. | Scenarios 26 and 33 (Window › Show Previous Tab) and acceptance a14 drive the runner across tab changes and fail if it follows the wrong tab. |
| opensNoMoreThanAHundredTabsAndSaysSo | drop | ⌘T and Duplicate Tab both go through the same check, `ExplorerTabGroup.hasRoomForTab`. | duplicatesATab…PastTheLimit (kept) checks the limit and the notice. NotificationsGUITests.theTabLimitNoticeIsAnInfoToastInTheWindow (converted) checks the text. Scenario 158 also covers it. |
| opensWindowsOnTheFolderOnScreenAndBringsBackThoseOpenAtQuit | keep | File › New Window, Open in New Window, close, quit and relaunch. Matches windows.spec "opens windows on the folder on screen". | |
| staysOpenWithNoWindowAndOpensOneWhereTheLastOneClosed | keep | The app with no window, a Dock reopen, and a Go menu item opening a window. Matches windows.spec "stays open with no window". | |
| tabsFollowAFolderRenamedOrMovedByAnyWindow | keep | Tabs in two windows follow a move, and the background tab reloads when its native tab is selected. The rules alone are in ExplorerTabsTests. | |
| tabsOnAnUnmountedDiskCloseAndAWindowAllOnItCloses | keep | A disk going away closes tabs and a whole window. This is window management on real groups. | |
| tabsOnAnUnmountedDiskGoHomeWhileASheetIsOpen | keep | Needs a sheet attached to an on-screen window (`isBlocked`, the busy answer to a merge). | |
| showsTheTabBarWithMoreThanOneTabAndOpensTabsAfterTheOneOnScreen | keep | The system tab bar showing and hiding, and its "+" button (`newWindowForTab`). | |
| savesTheTabsInTheOrderOfTheTabBar | convert | It calls `group.replaceTabs` directly and then reads the store. Run it on a group that is never shown. | |
| restoredTabsWaitUnreadUntilShownAndOnesWhoseFolderIsGoneAreDropped | keep | A restored background tab loads only when its native tab is selected. This is part of the relaunch flow. | |

### Toolbar/ToolbarGUITests.swift

| Test | Decision | Reason | Covered by (drop) |
|---|---|---|---|
| drawsTheItemsInTheirSavedOrderAndLeavesOutAnEmptyClipboardButton | convert | rowKeys, capsule edges and the clipboard count after layout. Use the windowless harness. | |
| hidesTheItemsNearestTheEndInANarrowWindowAndListsThemUnderTheOverflowButton | convert | `setContentSize` with layout, then the » menu view through `accessibilityPerformPress`. Works on a window that is never shown. | |
| togglesSayWhatAClickWillDoAndButtonsRunTheirCommands | convert | Tooltips, isOn and enabled states after `accessibilityPerformPress`. The window is never shown. | |
| switchesTheViewFromTheMenuAndBackFromTheToolbar | convert | `perform` and the segment press, then `viewState`. | |
| choosesAutoLightOrDarkFromTheThemeButtonsMenu | convert | The menu view's titles, then a choose, then the store. | |
| listsTheViewOptionsAndSortsFromTheSortMenu | keep | Toolbar menus opened and closed, Escape sent through the window, choices applied. This is the toolbar's menu flow (scenarios 55 and 56). | |
| stepsOnAClickAndListsTheFoldersWhenHeld | keep | Back held down with real timing, then ↓ and Return in the menu through the window, then a jump through the history (acceptance a08, scenario 58). | |
| editsTheToolbarInPlaceFromThePanelAndTheKeyboard | convert | `customizer.handleKey` and the panel callbacks are direct calls. Use the windowless harness. | |
| movesAddsAndTakesOffItemsByDragging | convert | `pressHandle`, `pointerMoved` and `pointerUp` are direct calls in window coordinates, which works on a window that is never shown. ToolbarState.showsTheFocusRing… (kept) does the real drag. | |
| offersCustomizeToolbarOnARightClickOfTheTitle | drop | It calls `title.rightMouseDown` directly. | ToolbarState.leavesARightClickOnAnItemAlone (kept) right-clicks the title through the window and checks the menu is ["Customize Toolbar…"]. Fold this test's `choose` and `customizer != nil` lines into it. |

### Toolbar/ToolbarStateGUITests.swift

| Test | Decision | Reason | Covered by (drop) |
|---|---|---|---|
| leavesARightClickOnAnItemAlone | keep | Real right-click events through `window.sendEvent`, hit-tested across the toolbar's items. | |
| titlesTheToolbarWithTheSearchedFolderInSearchMode | convert | The title text and Sort's enabled state when `searchRootPath` is set. | |
| keepsTheSortAndViewOptionsMenusOpenWhileTheWindowIsResized | convert | `setContentSize` posts `didResizeNotification` without the window on screen. It then checks the menu's frame and whether the menu exists. | |
| disablesTheViewSwitchSortAndCommandsWhileCustomizing | convert | Enabled states only. | |
| showsTheFocusRingOnlyForTheKeyboardAndTheHoverRingWhereADragEnds | keep | A real mouse-down, drag and mouse-up through the window, then the first responder and a key. This is the only real drag in Customize Toolbar (acceptance a10). | |

### ContextMenus/ContextMenuGUITests.swift

None of these opens a menu. Each one builds the `NSMenu` with `contentMenu(for:)` or `sidebarMenu(for:)` and calls its delegate or `sendAction` by hand. Scenarios 11 and 150 to 155 choose items through the real native menus.

| Test | Decision | Reason | Covered by (drop) |
|---|---|---|---|
| aFilesMenuListsOnlyWhatCanBeDoneToIt | drop | Duplicates the menu's item list. | FTFoundation ContextMenuGoldenTests.everyMenuListsTheItemsOfTheOriginalInItsOrder, ContextMenuRulesTests.theMenuOfAFileHasTheOriginalsGroups… and aTextFileShowsEdit…. The `NSMenu` build path stays covered by the converted tests below. |
| aFolderHasNewTabsAndPasteAndTheBackgroundHasTheFolderOnScreen | convert | `validateMenuItem` for Paste and New Folder on the session. The tab is loaded but never shown. | |
| viewAsTicksTheCurrentViewAndSortByTheCurrentOrderAndPickingOneApplies | convert | Item states, then `sendAction` to the tab. | |
| everyItemHasAFourteenPointTemplateIconAndTheTrashItemIsRed | convert | Item images and attributes. It's the only check of the icons and the red Trash item. | |
| theShortcutsShownAreTheKeysThatWouldDoTheSameNow | convert | `keyEquivalent`s on the built menus. | |
| openWithListsTheDefaultPinnedAndOtherAppsAndOptionTurnsItIntoAlwaysOpenWith | convert | `menuNeedsUpdate` with a stubbed lookup, the alternate item, then `sendAction`. | |
| tooManyItemsAndAFailedLaunchAreToldInANotice | convert | Coordinator calls with a notice spy. | |
| terminalFinderAndCopyPathAreDoneThroughTheSystem | convert | Calls with an opener spy and the toast entries. When converting, use a private `NSPasteboard`: it now writes to the user's real clipboard. | |
| changesOutsideWaitWhileAMenuIsOpen | convert | The delegate's open and close, then `folderChangesHeld`. | |
| aNativeMenuClosesWhenAnotherWindowOrAppIsClickedAsTheSystemDoes | drop | It doesn't click anywhere. It only calls `menuWillOpen` and `menuDidClose`. | changesOutsideWaitWhileAMenuIsOpen (converted) runs the same lifecycle. Add its `contextMenus.current == nil` check there. |

### Sidebar/SidebarGUITests.swift

| Test | Decision | Reason | Covered by (drop) |
|---|---|---|---|
| drawsFavoritesInTheirOwnSectionAboveTheFoldersOrAsRowsOfTheTree | convert | The cells' labels after layout. Use the windowless harness. | |
| rowsHaveTheOriginalsHeightIndentAndPadding | convert | Cell frames after layout. | |
| theChevronExpandsAFolderAndAnAliasHasNone | drop | It calls `model.toggleByHand` directly. | theArrowKeysMoveOpenAndCloseBranchesInTheFocusedSidebar (kept) opens Alpha and sees Inner. SidebarModelTests.theArrowKeysOpenABranch… also covers it. |
| theArrowKeysMoveOpenAndCloseBranchesInTheFocusedSidebar | keep | Focuses the sidebar, then sends arrow keys through the window to it (acceptance a02, scenario 82). | |
| aHeaderOpensAndClosesItsSectionAndKeepsItsChevronWhileClosed | convert | A model toggle, then which cells are on screen. | |
| aDiskThatCanBeEjectedHasAnEjectButtonAndOtherPlacesHaveNone | convert | Subviews and tooltips of cells, with volumes overridden. | |
| aRightClickRingsOnlyThatRow | convert | It calls `outline.menu(for:)` directly, then checks the model's selection and `menuTarget`. | |
| pressingEmptySpaceClearsTheSelection | drop | A one-line delegate call that forwards to the model. | SidebarModelTests.clearingTheSelectionLetsGoOfTheFolderOnScreen. |

### Notifications/NotificationsGUITests.swift

| Test | Decision | Reason | Covered by (drop) |
|---|---|---|---|
| notificationsStackAtTheBottomRightNewestLowestWithTheirMark | convert | Card frames in the overlay, measured against the path bar after layout. | |
| eachNotificationGoesAfterFourSecondsAndNoMoreThanThreeShow | drop | Model timing on a clock moved by hand. | ToastsTests.dropsTheOldestVisibleToastWhenAFourthToastIsQueued and keepsEveryNotificationOnScreenForFourSeconds. The cards following the entries is covered by the converted noNotificationComes… and the stack test. Scenario 156 also covers it. |
| noNotificationComesWhenTheyAreTurnedOffAndThoseShowingGo | convert | A preference change, then the toast entries and the cards. | |
| theTabLimitNoticeIsAnInfoToastInTheWindow | convert | `showNotice`, then a toast entry. It's the only check of that wiring (the kept window test stubs `showNotice`). | |
| theProgressCardComesAfterTheDelayAndShowsWhatRunsAndStops | convert | The card model, its frames and texts, and the Stop callback. | |
| anOperationOverBeforeTheDelayShowsNoCard | convert | The progress model only, with no window needed. | |
| spacePreviewsTheSelectedItemWithQuickLookAndSpaceAgainClosesIt | keep | Space sent through the window to the focused list, opening and closing Quick Look (scenario 159, acceptance a13). | |

### InfoPanel/InfoGUITests.swift

| Test | Decision | Reason | Covered by (drop) |
|---|---|---|---|
| thePanelAndTheRowDescribeTheSelection | convert | Field texts after selection and layout. | |
| severalItemsAreSummedUpInBothViews | drop | Duplicates the view tests. | InfoViewsTests.severalItemsAreSummedUp and severalItemsShowTheCountAndTheFolderSize. The selection wiring is covered by thePanelAndTheRow… (converted). Scenarios 140 and 146 also cover it. |
| showInfoPointsThePanelAtAnUnselectedItem | convert | `showInfo`, then texts. When converting, add the missing `harness.close()`: the test now leaves its window and temporary folder behind. | |
| calculateSizeMeasuresTheSelectedFolders | convert | Commands, then `folderSizes` state and texts (acceptance a11). | |
| aSeparatorsMenuStepsSideways | convert | `onClick` and `onChoose` on the folder menu view, which is in the window, then the folder shown. | |
| theEditorOpensOnTheCurrentPathAndEscapeClosesIt | keep | The path editor takes the first responder and the field editor, with the caret at the end, and Escape closes it. | |
| returnGoesToTheTypedPath | convert | The editor's `control(_:textView:doCommandBy:)` is a direct call. The field editor also works in a window that is never shown. Otherwise call the commit directly. | |

### Help/PageWindowsTests.swift (gated case only)

| Test | Decision | Reason | Covered by (drop) |
|---|---|---|---|
| opensOneWindowOfEachKindAndRemembersHelpsPage | keep | Help, About and Acknowledgements opened and reopened (one window of each), then closed, and Help reopens on its last page. This is window management. | |

### Content/ListGUITests.swift

| Test | Decision | Reason | Covered by (drop) |
|---|---|---|---|
| drawsTheRowsAndTheHeader | convert | Row and header frames and texts after layout. | |
| aNarrowPaneDropsColumnsFromTheRight | drop | Duplicates the layout tests. | DetailsLayoutTests.columnsDropFromTheRightOneAtATime and fittingLeavesTheOtherSavedWidthsAlone. The rows following the pane is covered by rowsFollowAWiderPane (converted). Scenario 87 also covers it. |
| headerClicksSort | drop | It calls `cell.onSort` directly. | DetailsLayoutTests.headerClicksSortLikeTheOriginal (the same order rules, Created and Permissions not sortable). Scenario 94 does a real header click. |
| separatorsResizeTheColumns | convert | `onBegin`, `onDrag`, `onNudge` and `onFit` are direct calls, followed by checks of the widths and preferences. | |
| aChangeOutsideKeepsTheSelection | keep | The flow of folderWatch.spec "shows items made, renamed and removed outside the app, keeping the selection", in a shown window. It reloads with `tab.refresh()`, not the watcher (see section 3). | |
| theStates | convert | The empty, error and Full Disk Access state views, through the controller. | |

### Layout/WorkspaceGUITests.swift

| Test | Decision | Reason | Covered by (drop) |
|---|---|---|---|
| hidesTheFolderTreeGivingItsRoomToTheListAndTheToolbar | convert | Workspace cell frames after layout. | |
| slidesTheInfoPanelInAndOutOverTheContent | convert | Slide state and frames. If the slide's completion doesn't fire when the window isn't on screen, keep it instead. | |
| squeezesThePanesInANarrowWindowAndKeepsTheChosenWidths | convert | Widths after `setContentSize`, then `keyDown` called directly on the resizer. | |
| drawsNoLinesTheOriginalDoesNotHave | keep | The window's own frame as the window server shows it: style flags, the traffic lights' place and the title bar band. It's the in-process smoke check of the explorer shell. | |
| leavesTheScrollersToTheSystemsOverlayScrollers | convert | One property check on the scroll views. | |

### Content/ReviewRowWidthTests.swift (the gated `ExplorerWindowGUITests.ReviewRowWidthTests` suite)

| Test | Decision | Reason | Covered by (drop) |
|---|---|---|---|
| rowsFollowAWiderPane | convert | A row frame after `setContentSize` and layout. | |
| theSizeCellClipsItsBar | convert | It needs no window at all (`SizeCellView().clipsToBounds`). Move it out of the gated suite. | |
| aFolderWatchChangeKeepsItsChangedPaths | convert | `folderChanged`, then `pendingChange`. This is state only. | |

### Outside the list: FTFileSystemTests/DiskImages/DiskImageMounterHandOffTests.swift

| Test | Decision | Reason | Covered by (drop) |
|---|---|---|---|
| handsAnImageToTheRealDiskImageMounter | keep | Hands an image to Apple's DiskImageMounter app, which shows a window of its own. It's the only proof of that hand-off. Add it to ui-check's checkpoint command (it is not in `--filter FTAppKitTests`). | |

## 3. The original's 31 e2e tests

| Original spec › test | Kept tests that cover the same flow |
|---|---|
| smoke.spec › built app launches, shows the File Trail window, and renders the explorer shell | Every kept NativeWindowsGUITests test launches the windows in process, and WorkspaceGUITests.drawsNoLinesTheOriginalDoesNotHave checks the shell's frame. No kept test launches the built `.app`. Scenario 50 (T-01d79486) does. |
| windows.spec › opens windows on the folder on screen, and brings back those open at quit | opensWindowsOnTheFolderOnScreenAndBringsBackThoseOpenAtQuit |
| windows.spec › brings back each window's place and which was in front | bringsBackEachWindowsPlaceTabsAndWhichWasInFrontAtTheNextLaunch, and restoredTabsWaitUnreadUntilShown… |
| windows.spec › moves a tab to a window of its own, and merges the windows back | opensTabsMovesOneToAWindowOfItsOwnAndMergesTheWindowsBack |
| windows.spec › pastes in one window what was copied in another | **None.** Not ported yet: paste belongs to P5-08 and P3-05, which are still to do. Scenario 38 exists. |
| windows.spec › stays open with no window, and opens one where the last one closed | staysOpenWithNoWindowAndOpensOneWhereTheLastOneClosed |
| folderWatch.spec › shows items made, renamed and removed outside the app, keeping the selection | ListGUITests.aChangeOutsideKeepsTheSelection, **in part**. It makes and removes items but renames none, and reloads with `tab.refresh()`, not the folder watch. The watch itself is in FTFileSystemTests/Watch, scenario 20 and acceptance a17. |
| folderWatch.spec › shows a file's new size when it grows outside the app | **None.** ReviewStaleDetailsTests (windowless) covers part of the reload rules. |
| fileOperations.spec (8): copies and pastes into the same folder · duplicates with ⌘D · renames with F2 · new folder named in its row · ⌘⌫ to the Trash · cut and paste into another folder · asks about a name taken, keeps both · refuses a taken name, keeping the field open | **None.** Not ported yet: P3-06 and P5-08, both still to do. Scenarios 12, 13 and 17 and acceptance a04 exist. |
| batchRename.spec (7): adds text · adds a number to a name another file has · passes names along · names by date created, numbering repeats · swaps two names · changes only the case on a disk that ignores case · keeps the settings and presets after quit | **None.** Not ported yet: P3-08, with the sheet in P6-03. Acceptance a12 exists. |
| undo.spec (3): undoes and redoes a rename from the Edit menu · puts an item back from the Trash · undoes typing in the rename field, never the files | **None.** Not ported yet: P3-07. Acceptance a05 exists. |
| dragIn.spec (3): moves files dragged in from another app, and Undo takes them back · copies from an app that only lets its files be copied · takes no files on the path bar, nor items already in the folder | **None.** Not ported yet: P5-08. |
| quit.spec › quitting while a folder is measured ends the process at once | **None.** No GUI test and no service test. P3-05 owns it. |
| quit.spec › quitting while a search runs leaves no fd behind | No GUI test. It is covered without a window by FdSearchProcessTests.quittingWhileASearchRunsLeavesNoFdBehind. |

**Coverage:** of the original's 31 e2e flows, the kept tests cover:

- **4 fully:** the four windows.spec flows that have been ported.
- **2 in part:** smoke, and the first folderWatch flow.
- **25 not at all.** Most of these are 23 flows whose work packages haven't been built yet: file operations, batch rename, undo, drag-in and quit. One of those 23, the quit-during-search flow, is already covered by a test that needs no window. The other two are the paste between windows (also not ported yet) and a file's size growing outside the app.

When those work packages land, each flow should get one e2e test. If every flow gets one, the kept set comes to about 45 to 50.

## 4. Expected run time of the kept set (an estimate)

**This is an estimate.** Nothing was run, and no earlier log records times for the gated tests. It is worked out from the tests' structure:

- **Each test.** It opens a window, lists a small temporary folder and polls every 25 ms until it is ready. That takes about 0.3 to 0.8 s per window.
- **NativeWindowsGUITests (12 kept).** They open 2 to 4 windows each, and three of them quit and relaunch. Estimate 1.5 to 3 s each, about **20 to 35 s** in all.
- **The other 10 kept FTAppKitTests.** One window each. `stepsOnAClick…` adds a 350 ms hold and a 450 ms sleep, and the Help/About/Acknowledgements test opens three page windows. Estimate about **10 to 15 s** in all.
- **DiskImageMounter hand-off.** It starts an app and waits 500 ms. Estimate 2 to 4 s.
- **Total.** About **35 to 55 s** of tests, run one at a time. On top of that comes building the test bundle (tens of seconds, incremental) and process start-up.
- **Failure case.** A failing wait times out after 5 s (200 × 25 ms), so a run with failures takes longer.
- **Compared with now.** The 77 gated tests today come to roughly 1.5 to 2.5 min by the same reckoning.
- **Note for ui-check.** It runs `--filter FTAppKitTests` with the gate on, which also runs every windowless FTAppKitTests test. Once the kept tests are the only gated ones, a narrower filter (or a tag such as `.e2e`) keeps the checkpoint run to just these.

## Borderline: the next 8 tests to keep if you want 30

These are marked convert above. They are the ones closest to an e2e test:

1. **ToolbarGUITests.togglesSayWhatAClickWillDoAndButtonsRunTheirCommands**: toolbar buttons running their commands.
2. **ToolbarGUITests.movesAddsAndTakesOffItemsByDragging**: the drags of acceptance a10.
3. **ToolbarGUITests.editsTheToolbarInPlaceFromThePanelAndTheKeyboard**: Customize Toolbar from the keyboard.
4. **InfoGUITests.aSeparatorsMenuStepsSideways**: the path bar's menu (a08).
5. **InfoGUITests.calculateSizeMeasuresTheSelectedFolders**: a11.
6. **WorkspaceGUITests.slidesTheInfoPanelInAndOutOverTheContent**: animation timing.
7. **ToolbarStateGUITests.keepsTheSortAndViewOptionsMenusOpenWhileTheWindowIsResized**: a live resize.
8. **NativeWindowsGUITests.savesTheTabsInTheOrderOfTheTabBar**: the tab bar's order.
