# Tab Views and Window Views

The plan for saved views of a tab and of a window, beside the folder's view File Trail already has. Workspaces are removed and rebuilt as window views. The design was worked out with the owner on 2026-11-21, with a mock of the menus, the sheets and the Views window; the decisions below are written into [decisions/windows-and-panes.md](../decisions/windows-and-panes.md) and [decisions/views.md](../decisions/views.md) in phase 0.

## Status (2026-11-21)

Built: the model and its rules (phase 1), tab views in the app with the override and the new-tab view (phase 2), window views with workspaces removed (phase 3), the Views window and the Layout menu (phase 4), Help, the palette, the goldens and the decisions (phase 5, but for what is left below). The decisions are in [decisions/windows-and-panes.md](../decisions/windows-and-panes.md) ("Saved views") and [decisions/views.md](../decisions/views.md).

Where the build differs from this plan, each for the reason beside it:

- **The divider's share is 20% to 80%**, typed or as now: the limits a drag of the divider has (`PaneSplit`), so the two agree.
- **Column visibility and order are the app's**, as the List's header sets them; a tab view's columns set them as the header would, and its widths and sizes are the pane's. A pane has no columns of its own to keep.
- **Tab View Options is a sheet**, not a popover that changes the tab as you go: a tab view has a name and is saved once. Its rows are Folder View Options'.
- **Saving under a name another tab view has saves over that one**, which keeps its id, so window views and new tabs that use it use what was saved; the Save button reads Replace, with a line saying so, and no question follows.
- **"Not Used" ends whole** when any setting is changed by hand in the folder; "Tab View First" lets go of the setting changed only.
- **The new-tab view is read as it was saved**: an id that names no tab view does nothing. A preference is read on its own, never by the keys beside it, so it can't be checked against the tab views there.
- **A window view's tab takes its tab view as it is first shown**, the tab view as it was when the window opened.
- **"In This Window" with no key shows beside each of the first five window views**, not in their place with ⌥: AppKit pairs only items whose keys differ by ⌥ alone.
- **Either pane of two can show the viewer** (the owner, 2026-11-21, after trying the first build): View offers Viewer in the left and the right pane's rows, with the viewer bar's Follow and Read or Edit in place of the folder's rows. Only one of the two: the left's when both ask.
- **The window's size is typed between 760 × 480, the smallest an explorer window can be, and the screen's room**, held as each field is left.
- **The sheet's pane rows are headed by the pane**, Left Pane and Right Pane as a chooser, The Pane, or The Active Pane, with a line saying the rows are what the tab view sets there; "Keep for the Left Pane" read as unclear. Folder View Options' fifth row in the List is now "Column Visibility, Order and Sizes", as it keeps the widths too.
- **The menu is Layout**, renamed from Saved Views by the owner.
- **A background tab that follows a renamed folder loses its override**: the pane takes its new place without knowing whether the folder moved or its disk went.

Left: the fuzz test of section E, the tests of real windows of section D, the hand check of section F, and in C: Choose Folder…, a held tab beeping, the gone-folder notice on screen, and Back after a tab view's folders in two panes. The full `scripts/ci.sh` runs once more at the end.

## What changes

- **Folder View** stays as it is: a folder's own settings, laid over the pane while the folder is shown ([decisions/views.md](../decisions/views.md), "A folder can keep its own view" and after).
- **Tab View** is new: a named set of a tab's settings, each kept only if checked, applied once to the tab you're in. What it doesn't keep carries over from the tab, the folders included.
- **Window View** replaces the workspace: a named window made of tab views. It says how many tabs to open, which tab view each one uses (or none), which tab is in front, and, if checked, the window's size, folder tree and Info panel.
- **One menu, Layout,** holds all three, and **one Views window** lists all three, in place of the Folder Views window and Settings → Browsing's list of workspaces.
- Workspaces are removed with no migration: `workspaces` in `app-state.json` is no longer read.

## Decisions taken (2026-11-21)

1. A tab view keeps only what is checked; the rest carries over from the tab it is applied to. Nothing is reset to the app's defaults.
2. Each pane's folder is kept only if checked. Unchecked, the pane stays on its folder.
3. Each pane of a tab view chooses how folders with a view of their own are treated: the folder's view first (as today), the tab view first (the folder's view gives what the tab view doesn't keep), or not used.
4. A tab view can be the one new tabs open with, New Window's first tab included.
5. The folder tree and the Info panel are the window's, so only a window view keeps them. A tab view doesn't.
6. A window view is built from tab views and doesn't repeat their settings.
7. The Tab View and Window View sheets are consistent with Folder View Options (its words, its groups, its rows and their order, the fifth row that follows the view, Reset and All … Views…), without copying it where it doesn't fit: a tab view needs a name, so it is a sheet, not a popover.
8. Group By, Sort By, Folders First, the columns and the sizes offer exactly what Folder View Options offers today, from the same lists in the code.
9. The divider can be kept as even, as the share shown now, as the left pane's width shown now, or as a share typed in.
10. A window view's size can be the size shown now, or a width and height typed in.
11. Keys: ⌥⌘1–⌥⌘5 apply tab views 1–5; ⌃⌘1–⌃⌘5 open window views 1–5 in a new window. "In This Window" has no default key, and can be given one in Settings → Shortcuts. ⇧⌘1–⇧⌘5 were considered and dropped: ⇧⌘3, ⇧⌘4 and ⇧⌘5 are macOS's screenshot keys.
12. Workspaces are removed, not migrated.
13. The menu is **Layout**, after View (the owner, 2026-11-21, after trying Saved Views, its first name). Dropped: Views (beside View it reads like a typo), Workspace, Saved Views, Presets ("preset" is batch rename's word, and a folder's view isn't one), Arrange (Finder's old Arrange By).

## Words

- **Folder View, Tab View, Window View**: one family. The names are proposed, not settled; see "Still open".
- **View** alone still means Icons, List, Compact List or Previews.
- **Tab View Options** and **Window View Options** are the sheets, as Folder View Options is the popover.
- **The first five can be given keys**: Settings → Shortcuts sets them. The Views window says so in those words, not "the first five have keys", because a key can be removed or changed.
- In the code, a tab view's per-pane folder-views choice is `FolderViewsChoice` (`.folderFirst`, `.tabViewFirst`, `.notUsed`), and what it leaves on a pane while active is a `TabViewOverride`.

## The model (FTFoundation)

```swift
/// A tab's settings, each only if kept; nil carries over from the tab.
public struct TabViewKeeps: Codable, Equatable, Sendable {
    public var panes: Int?                       // 1 or 2; nil: the tab view is for the active pane alone
    public var divider: Divider?                 // only with panes == 2
    public var includeHidden: Bool?
    public var left: PaneKeeps?, right: PaneKeeps?   // with panes == 2
    public var pane: PaneKeeps?                  // with panes == 1, or nil panes (the active pane)

    public enum Divider: Codable, Equatable, Sendable {
        case even
        case share(Double)                       // the left pane's share, 0.10...0.90
        case leftWidth(Double)                   // points; the right pane takes the rest
    }
}

public struct PaneKeeps: Codable, Equatable, Sendable {
    @SavedPathIfAny public var folder: String?   // nil: the pane stays on its folder
    public var view: FolderViewKeeps             // the folder view's six settings, as they are
    public var folderViews: FolderViewsChoice?   // nil: .folderFirst
}

public enum FolderViewsChoice: String, Codable, Sendable { case folderFirst, tabViewFirst, notUsed }

public struct TabView: Codable, Equatable, Sendable { public var id, name: String; public var keeps: TabViewKeeps }

public struct WindowView: Codable, Equatable, Sendable {
    public var id, name: String
    public var tabs: [String?]                   // a tab view's id for each tab; nil: a plain new tab
    public var frontTab: Int
    public var size: Size?                       // nil: the size of a new window, as today
    public var folderTreeOpen: Bool?, propertiesOpen: Bool?

    public enum Size: Codable, Equatable, Sendable { case points(width: Int, height: Int, zoomed: Bool) }
}

// AppPreferences: tabViews: [TabView], windowViews: [WindowView], newTabViewID: String?
// OpenTabPreference: lastTabViewID: String? (only to fill in Save Window View; never shown, never a link)
```

- `PaneKeeps.view` is `FolderViewKeeps` unchanged, so its reading, its cleaning of a damaged file, its "a missing part takes its default", and `differences(from:)` are reused, not written again.
- Names follow the workspace rules they replace: unique ignoring case and how an accented letter is stored, up to 80 characters, at most 50 of each kind (`TabViews.limit`, `WindowViews.limit`).
- A window view refers to tab views by id. Renaming a tab view changes nothing in a window view; removing one makes its tabs plain new tabs (see "The Views window").
- Kept in `app-state.json` as `tabViews`, `windowViews` and `newTabViewID`. A file with `workspaces` loads without them, and the key is dropped at the next write.
- Reading is as `Workspaces.sanitize` does today: an entry with no id, a name another has, or nothing that can be applied is left out. Beyond that: `panes` other than 1 or 2 is dropped; `left`/`right` without `panes == 2`, and `pane` with `panes == 2`, are dropped; a share outside 0.10–0.90 is clamped; a width under 1 is dropped; a window view with no tabs is left out, with more than 25 is cut at 25 (the tab limit), and a `frontTab` past its tabs becomes 0; an id that names no tab view reads as nil.

## Applying a tab view

One pure function, tested without windows:

```swift
TabViews.applying(_ keeps: TabViewKeeps, to tab: OpenTabPreference, lastClosedPane: OpenPanePreference?,
                  paneRoom: Double) -> (tab: OpenTabPreference, closed: OpenPanePreference?, overrides: [Int: TabViewOverride])
```

In this order:

1. **Panes.** `panes == 2` on a tab with one opens the second pane as ⌘\ does: `lastClosedPane` if the tab has one, otherwise a copy of the active pane. `panes == 1` on a tab with two closes the pane that isn't active, as ⌘\ does, and returns it as the tab's closed pane, so ⌘\ brings it back as it was. `nil` leaves the panes as they are.
2. **Divider**, only with two panes: `.even` is 0.5; `.share(s)` is `s`; `.leftWidth(w)` is `w / paneRoom`. Each is then held by `PaneSplit` so neither pane is under `PaneSplit.minimumPaneWidth` (280 pt); with less room than two of those, the panes are even, as `PaneSplit` does today. The tab keeps a share, as it does now: a width is turned into a share once, against the window it is applied in.
3. **Hidden files**, if kept.
4. **Each pane's settings.** With `panes == 2`, `left` goes to the first pane and `right` to the second; with `panes == 1`, `pane` goes to the only pane; with `panes == nil`, `pane` goes to the active pane, and the other pane is left alone. For each of the six view settings kept, the pane carries the kept value; for those not kept, it carries what it had. A kept folder that differs from the pane's goes into the pane's Back history; the same folder adds nothing.
5. **Folder views.** For each pane given settings, a `TabViewOverride` is returned when the choice is `.tabViewFirst` or `.notUsed`: the folder the pane is now on, the choice, and which of the six settings the tab view kept.
6. The active pane stays active, and the keyboard stays where it was.

Around it, in the app: a folder that is gone opens the nearest folder above it that is there, and the notice workspaces show today says how many (the code in `Workspaces.replacingGoneFolders` moves to `TabViews`). A tab held by a sheet, a dialog, an alert or a name being edited beeps and nothing changes. The tab's `lastTabViewID` is set.

## What a pane shows: folder views, panes and tab views

This is the part where most of the risk is, and where most of the tests go.

What a pane shows for each of the six settings comes from one of four places:

- **the pane**: what the pane carries from folder to folder. A tab view changes it once, when applied.
- **the folder's view**: the folder's own, or the nearest view above that covers the folders inside (`FolderViews.use(for:)`, "the nearest view wins whole").
- **an unsaved change on screen** in that folder (`FolderViewOnScreen`), until Save, Revert or leaving.
- **the tab view's override**, while the pane is still in the folder the tab view opened.

The rule, written as one pure function so it can be tested as a table:

```swift
PaneViewResolution.shown(carried: FolderViewKeeps, use: FolderViewUse?, onScreen: FolderViewOnScreen?,
                         override: TabViewOverride?, folder: String) -> (keeps: FolderViewKeeps, from: [FolderViewSetting: Source])
```

- With no override, or an override for another folder: what today's code shows. The folder's view, with what is changed on screen laid over it, wins for what it keeps; the pane gives the rest.
- `.tabViewFirst`: for the settings the tab view kept, the pane's value (which is the tab view's). For the others, as with no override.
- `.notUsed`: the pane's value for all six; the folder's view and what is changed of it on screen aren't used.

Today's code lays the folder's view over the pane in `BrowserPane.shownPreferences`, `shownKeeps` and the `shown…` properties (`BrowserPane+FolderView.swift`). Those read through the new function, so there is one place that decides, and the status bar's symbol, Folder View Options and the List's columns follow it.

When an override ends (each one is a test):

- The pane goes to another folder: a click, Back, Forward, Enclosing Folder, Go to Folder, a favorite, the tree, a drop that opens a folder.
- The pane's folder is gone (Trash, eject) and the pane goes up.
- Any Folder View command runs in that pane: Folder View Options opening, Remember, Update, Revert, Reset. The override ends first, so what the command shows and saves is the folder's view, not the tab view laid over it.
- A setting the override covers is changed by hand in that folder (⌘1–⌘4, Sort By, a column, the size slider): that setting leaves the override, and the change is an unsaved change of the folder's view, as today.
- Another tab view is applied to the pane.

What doesn't end it: Refresh; Hidden Files; search results shown and closed again in the same folder (the folder's view comes back after search today, and so does the override); the folder renamed or moved in File Trail (the pane follows it, and so does the override); the folder's view saved, changed or removed from another tab (the override keeps covering what it covers, and the rest follows the new view).

What doesn't carry it: Duplicate Pane, Duplicate Tab, Reopen Closed Tab, Move Tab to New Window, and a session saved at quit. Each shows the folder's view as saved, as decisions/views.md already says for unsaved changes ("A pane or tab opened from another … shows the folder's view as saved").

The status bar's folder-view symbol gets one more state: the tab view comes first, or the folder's view isn't used. It has its own tooltip ("This tab view comes first in “Lisbon” · Folder View Options"). Where the symbol is drawn and how wide it is doesn't change.

## Applying a window view

- **In a new window**: the window opens with the window view's tabs. Each tab starts as a new tab would, from the pane you were in, then has its tab view applied (or none). The front tab is `frontTab`. Size: the kept size, else a new window's size as today. Folder tree and Info panel: kept, else as in the window you opened it from.
- **In this window** (⌥, no default key): the window's tabs close and the window view's open in their place; Reopen Closed Tab brings the closed ones back. The window's size changes only if kept. A window held by a sheet, a dialog or an alert beeps, as a workspace does today.
- A kept size is held inside the screen's visible frame and above the window's minimum size; its place on screen is never kept.
- A tab whose tab view was removed opens as a plain new tab.
- Gone folders, the notice, and the 25-tab limit work as for workspaces today.

## The new-tab view

- Chosen in the Views window's Tab Views pane, "New tabs open with" (None by default).
- Taken by New Tab (⌘T and the tab bar's +) and by New Window's first tab: the tab starts as it does now, then the tab view is applied.
- Not taken by Duplicate Tab, Reopen Closed Tab, Move Tab to New Window, Merge All Windows, a window view's tabs (they have their own), windows restored at launch, or a tab opened for a given folder (Open in New Tab, a folder opened from Finder or the Dock, a drop on the tab bar), where the folder asked for is what was asked for.
- While it is None, "New Window and New Tab open with one pane" holds as it does today.
- Removing the tab view it names sets it back to None.

## The sheets

### Tab View Options

Opened by Save Tab View… (a new tab view, from the tab as it is) and by Edit… in the Views window (a saved one). Each control starts at what this tab shows now; editing a saved one, each control starts at the saved value, and the "as now" choices still read from this tab.

- **Name**, with the saved names listed to choose one to replace, as Save Window as Workspace's prompt lists them today. Saving under a name another tab view has asks before replacing it.
- **Keep for This Tab**: Panes (One, Two); Divider (Even; As Now, 62% / 38%; As Now, Left Pane 420 pt; Custom…, a field for the left pane's share in percent, 10–90); Hidden Files (Shown, Hidden). Divider is dimmed with one pane, not hidden, so the sheet keeps its height.
- **Keep for the Left Pane** and **Keep for the Right Pane** with two panes; **Keep for This Pane** with one; **Keep for the Active Pane** when panes aren't kept. Each has the same rows: Folder; View; Group By with In Order/Reversed; Sort By with Ascending/Descending; Folders First; and a fifth row that follows the view chosen in that group: Column Visibility and Order in the List, Icon Size in Icons, Column Width in the Compact List, Previews in Previews. The controls and their choices are Folder View Options' (`FolderViewPopover.settings(for:)`, `sizeChoices`, `GroupByPreference.menuOrder`, `SortByPreference.menuOrder`), shared rather than repeated.
- **Folder**, once checked, offers the folder each pane shows now ("Downloads, the Left Pane Now"), the other folders you go to often, and Choose Folder…. Unchecked, it reads "Stays on the tab's folder".
- **Folder Views** under each pane's rows: Folder's View First, Tab View First, Not Used, with one line under it saying what the choice does.
- Unchecked rows keep their control, dimmed, as Folder View Options does.
- A line at the foot says in words what the tab view sets and what carries over.
- Buttons: Reset (unchecks everything), All Tab Views…, Cancel, Save.

### Window View Options

- **Name**, as above.
- **Tabs**: Number of Tabs (1–25); a row per tab, "Tab 1", with a pop-up of None (a plain new tab) and every tab view, and a line under it saying what that tab view keeps; Front Tab.
- **Keep for This Window**: Size (As Now, 1280 × 800; Custom…, width and height fields); Folder Tree (Shown, Hidden); Info Panel (Shown, Hidden).
- Saving from a window fills in the tabs: as many as the window has, each with the tab view last applied to it, if one was and it is still saved; otherwise None. Changing the number of tabs keeps the choices of the tabs that remain.
- Buttons: All Window Views…, Cancel, Save.

## The Views window

One window with a toolbar of three panes, as Settings has: **Folder Views**, **Tab Views**, **Window Views**. The window's title is the pane's name, as Settings' is. Each Manage … item opens it on its pane.

- **Folder Views** is today's Folder Views window, moved in unchanged: the tree of folders, Remove, Remove with Subfolders, Remove All…, Open.
- **Tab Views** and **Window Views**: a list with Key (the key it has now, or nothing), Name and What It Keeps. Drag to reorder. Double-click a name to rename it. Buttons: Apply (Tab Views) or Open (Window Views), Edit…, Duplicate, Remove, Remove All…. Under the list: "The first five can be given keys in Settings → Shortcuts."
- Tab Views has "New tabs open with" under its list.
- Removing a tab view that window views use asks first, naming them ("“Compare” is used by “Research” and “Review”. Their tabs will open as new tabs."). This is the one Remove that asks: it changes things that aren't selected and can't be undone. Remove All… asks, as it does for folder views.

## The menu

Layout, a menu of its own after View. The View menu loses its Folder View submenu, and the Window menu loses Workspaces.

- Folder View Options… ⌘J, Remember View for This Folder, Update Folder View, Revert to Saved View, Reset Folder View, Manage Folder Views…: today's Folder View items, under a section heading "Folder View".
- Save Tab View…, the tab views (⌥⌘1–⌥⌘5 on the first five), Manage Tab Views…, under "Tab Views".
- Save Window View…, the window views (⌃⌘1–⌃⌘5), each with an ⌥ item "… in This Window", Manage Window Views…, under "Window Views".

Commands, per [process/commands.md](../process/commands.md): `applyTabView1`–`5` (⌥⌘1–⌥⌘5), `openWindowView1`–`5` (⌃⌘1–⌃⌘5), `openWindowView1InThisWindow`–`5` (none), `saveTabView`, `saveWindowView`, `manageTabViews`, `manageWindowViews`. The palette lists tab views and window views by name ("Apply Tab View: Compare Side by Side", "Open Window View: Research") and leaves out the fifteen slot commands, as it leaves out the workspace keys today. Removed: `openWorkspace1`–`5`, `openWorkspace1InThisWindow`–`5`, `saveWorkspace`, Manage Workspaces….

## Removing workspaces

`Workspace`, `Workspaces` (`Sources/FTFoundation/Workspaces/`), `ExplorerWindows+Workspaces.swift`, the Workspaces menu in `ApplicationMenuBuilder`, Settings → Browsing's list in `SettingsLists`, `PreferenceKey.workspaces` and its reading, their Help lines and palette exclusions, and the suites that test them (`WorkspacesTests`, `WorkspaceStateTests`, `WorkspaceWindowTests`, `WorkspacesInWindowTests`, `SettingsWorkspacesTests`) are replaced by the new code and suites. `WorkspaceView` and `WorkspaceSplit…` in `Sources/FTAppKit/Layout/` are the window's own layout and stay, with `WorkspaceTests` and `WorkspaceGUITests`. The code that carries over (names, limits, gone folders, a held window, the notice) moves; it isn't written again.

## Phases

0. **Decisions and Help.** windows-and-panes.md's Workspaces section is replaced; views.md gains the tab view's folder-views choice and the override's rules; the keys table gets ⌥⌘1–⌥⌘5; "New Window and New Tab open with one pane" gets its exception. The Help topics are drafted.
1. **Model.** `TabViewKeeps`, `PaneKeeps`, `TabView`, `WindowView`, reading and writing, `TabViews.applying`, `PaneViewResolution.shown`, `WindowViews` (names, limits, references). Tests: sections A, B and the fuzz of "Tests" below. Nothing on screen changes yet.
2. **Tab views in the app.** Applying, the override in `BrowserPane`, the status bar's new state, the new-tab view, the Tab View Options sheet, the commands. Tests: C1–C4.
3. **Window views, and workspaces removed.** Opening, the Window View Options sheet, ⌃⌘1–⌃⌘5 moved over, the workspace code and its tests removed in the same change, so no build has both. Tests: C5–C6.
4. **The Views window and the menu.** The Folder Views window becomes a pane; the menu of its own; View ▸ Folder View and Window ▸ Workspaces go. Tests: C7–C8, D.
5. **Finish.** Help, palette, goldens, the GUI tests, a hand check with an `--automation` scenario (`tools/capture/README.md`), and one full `scripts/ci.sh`.

Each phase ends with `scripts/ci.sh --affected` (one run at a time on this Mac), and phase 5 with the full run.

## Tests

The aim: every source a pane's setting can come from, every way an override starts and ends, and every way a tab or window is opened, each pinned by a test that names it. Most of it is pure and fast; the app-level tests use the windowless harness `FolderViewTests` and `WorkspacesInWindowTests` use today (`ExplorerHarness`).

### A. The model (FTFoundation, pure)

- **Reading and writing**: every field round-trips; each optional field missing reads as "not kept"; an unknown field is passed over; each damaged case in "The model" reads as said there (panes 3, left without two panes, share 1.4, width 0, a window view with 0 and with 30 tabs, a front tab past the end, an id that names nothing, a duplicate name, a duplicate id, a name of 81 characters, the 51st entry). A file with `workspaces` loads without them, and the next write has no `workspaces`.
- **Names**: unique ignoring case and accent encoding (the `Workspaces` name tests move over for both kinds); renaming to a name another has is refused with its message.
- **`TabViews.applying`, panes**: the table of the tab (one pane, two panes) × `panes` (nil, 1, 2) × the closed pane (none, one) × the active pane (left, right). Each row checks the panes after, which is active, which pane was closed and returned, and that ⌘\ data is what it was.
- **Divider**: `.even`, `.share` at 0.10, 0.5, 0.90; `.leftWidth` at 200, 420 and 2000 pt against pane rooms of 500, 560, 900 and 1800 pt. Each row checks the share against `PaneSplit`'s holding (280 pt each side; even below 560 pt). The divider is untouched with one pane.
- **Pane settings**: for each of the six settings, kept and not kept, on the left, the right and the active pane. Group's reverse is kept only with a grouping, as `FolderViewKeeps` does. Sizes are kept per density, as a folder view keeps them.
- **Folders and Back**: a kept folder that differs is one Back entry; the same folder is none; a folder in each pane is one entry in each.
- **Gone folders**: the nearest folder above that is there; Home when none is; the count for the notice; a disk that doesn't answer in time keeps its folder (as `ScreenGeometry.keepsWaitingTabs` does today).
- **Window views**: tabs resolved by id; a removed id is a plain tab; the front tab held to the tabs; the size held to a visible frame and the minimum size (a table of screens and sizes); the tree and Info panel kept or carried.
- **References**: removing a tab view names the window views that use it, and leaves nil in their tabs; renaming changes nothing in them; Duplicate gives a new id and "Name copy", "Name copy 2".
- **The new-tab view**: an id that names nothing is None.

### B. What a pane shows (the golden)

`PaneViewResolution.shown` is checked against `Tests/Golden/view-resolution.json`, kept by hand as the goldens are ([decisions/code.md](../decisions/code.md), "Goldens are expected results kept by hand"), with bases and changes as in `Tests/FTTestSupport/GoldenChanges.swift`. Each case names, for each of the six settings, the value shown and where it came from (pane, folder view, change on screen, tab view).

The folder's view, the bases:

1. No view anywhere above.
2. Its own view, keeping View only.
3. Its own view, keeping all six.
4. A view from its parent with Apply to Subfolders, keeping View and Sort By.
5. A parent covering the folders inside, and the folder's own view (its own wins whole).
6. A parent covering the folders inside, and the folder's empty view with Apply to Subfolders on (the branch stops using it: no view).
7. A grandparent covering the folders inside, and a parent with its own view that doesn't cover them (the grandparent's is used).
8. Its own view with an unsaved change of View on screen.
9. No view, with an unsaved view on screen that waits for Save.

Each base with each change:

- a. No override.
- b. `.folderFirst` (the same as a, checked so).
- c. `.tabViewFirst` keeping View only.
- d. `.tabViewFirst` keeping View and Sort By.
- e. `.tabViewFirst` keeping all six.
- f. `.tabViewFirst` keeping only the folder (none of the six).
- g. `.notUsed`.
- h. Any override, but for another folder (inactive).

That is 72 cases. The pane's own values are chosen to differ from every folder view's in every setting, so each case shows where each value came from. The golden is read by the owner as the table of rules; a change to the rules changes it by hand.

### C. In the app (windowless harness)

C1. **Applying a tab view**

- No folders kept: the panes stay where they are, the settings change, Back has nothing new.
- Folders kept: the panes go there, and Back in each pane returns.
- One pane to two: the pane closed before comes back as it was (folder, view, selection, scroll). Two to one: the pane not active closes, and ⌘\ brings it back.
- Active pane only: with the right pane active, only the right pane changes.
- Divider: a share; a left width with the folder tree shown and hidden (the left pane is the same width both times); a custom 10% in a narrow window is held at 280 pt.
- A tab held by a sheet, a dialog or a name being edited: a beep, and nothing changes.
- A folder that is gone: the nearest one above, and the notice.
- The keys ⌥⌘1–⌥⌘5 apply by the list's order; a key changed in Settings → Shortcuts applies; a sixth tab view has no key.

C2. **Folder views and the override**, each from a pane in a real tab:

- Folder's view first into a folder with its own view: the folder's view shows; leaving, the pane shows the tab view's values.
- Tab view first into a folder with its own view keeping View and Sort By, the tab view keeping View only: View from the tab view, Sort By from the folder.
- Tab view first into a folder covered from above (Apply to Subfolders): as with its own view.
- Not used: the folder's view is ignored, and the status bar's symbol shows its new state with its tooltip.
- Each way an override ends, one test each: a click into a folder, Back, Forward, Enclosing Folder, Go to Folder, a favorite, the tree, the folder moved to the Trash, each of the five Folder View commands, a hand change of a covered setting (that setting only ends; the others stay covered), another tab view applied.
- Each way it doesn't end, one test each: Refresh, Hidden Files, search shown and closed, the folder renamed in File Trail, the folder moved in File Trail, the folder's view saved from another tab, removed from another tab, changed from another window.
- Back into the folder after leaving: the folder's view shows (the override doesn't come back).
- Into a folder inside it: that folder's own rules, no override.
- Not carried: Duplicate Pane, Duplicate Tab, Reopen Closed Tab, Move Tab to New Window, and a quit and launch. Each shows the folder's view as saved.
- Two panes on the same folder, one with an override: each shows its own.
- Folder View Options opened in an overridden pane: the override ends first; the popover shows the folder's view; Save saves the folder's values, not the tab view's.
- Remember View for This Folder after a tab view applied with tab view first: what is remembered is what is on screen once the override ended.
- "A setting a folder starts to keep is given back to the pane": after a tab view, Remember gives the pane back the tab view's value, not the one from before it.
- Sizes: a tab view keeping Icon Size, a folder keeping its size, and density changed between; each of folder first, tab view first and not used.

C3. **The new-tab view**: ⌘T, the + button and New Window take it; Duplicate Tab, Reopen Closed Tab, Move Tab to New Window, Merge All Windows, a window view's tabs, windows restored at launch, Open in New Tab, a folder opened from outside the app and a drop on the tab bar don't; removing it sets None; the 25-tab limit holds.

C4. **Save Tab View**: the sheet's first values are the tab's; editing shows the saved values with "as now" from this tab; the fifth row follows the View chosen in its group; Divider is dimmed with one pane; Custom accepts 10–90 and refuses others; Reset unchecks everything; an empty name can't be saved; a name another has asks before replacing, and Cancel there changes nothing; the 51st is refused with its notice; the saved keeps are exactly what was checked.

C5. **Window views**: open in a new window with three tabs (a tab view with folders, one without, none); a tab view edited after the window view was saved is used as edited; a removed tab view opens a plain tab; the front tab; the size as now, typed, and held to the screen; the tree and Info panel kept and carried; ⌥ replaces this window's tabs and Reopen Closed Tab brings them back; a held window beeps; gone folders and the notice; ⌃⌘1–⌃⌘5 by order; "in This Window" has no key until one is given, and then works.

C6. **Save Window View**: as many tabs as the window, each with its last tab view when it is still saved; changing the number of tabs keeps the others' choices; the summary; replacing by name asks; the 51st is refused.

C7. **The Views window**: each Manage item opens its pane; the title follows the pane; Folder Views behaves as today (`FolderViewTests`' window tests move here); reorder changes the keys shown and what ⌥⌘1 applies; rename refuses a name taken; Duplicate; Remove of a tab view in use asks and names the window views, and Cancel changes nothing; Remove All… asks; Edit opens the sheet and Save comes back to the list; Apply and Open; "New tabs open with".

C8. **The menu and the commands**: the new menu's items and order in `ApplicationMenuLayoutTests`; View has no Folder View submenu and Window has no Workspaces; the ⌥ items; dimmed items while blocked or with no folder (`CommandAvailability`); `shortcut-resolution.json` with ⌥⌘1–⌥⌘5, ⌃⌘1–⌃⌘5 and none for in-this-window; `command-availability.json`; `help-content.json`; the palette lists the views by name and excludes the slot commands (`CommandPaletteTests`, `CommandPaletteMenuTests`); `HelpContentTests`.

### D. Real windows (`FILETRAIL_GUI_TESTS=1`, suites ending in `GUITests`)

- The Tab View Options sheet keeps its height whatever View is chosen in each group, and with one or two panes.
- The Window View Options sheet with 1 and with 25 tabs (it scrolls; its buttons stay in view).
- The Views window's three panes, the title following, and the toolbar's selection.
- ⌥⌘1 and ⌃⌘1 pressed in a real window.

### E. Fuzz (pure, as the undo and batch-rename fuzz tests)

Random sequences of: apply a tab view (random keeps and choice), go to a folder, Back, Forward, open search and close it, Refresh, a Folder View command, a hand change of a setting, save or remove a folder's view (own or covering), Duplicate Pane. After each step:

- every setting shown has exactly one source, and it is the one `PaneViewResolution.shown` gives;
- an override exists only while the pane is on its folder;
- after leaving that folder, nothing in the pane depends on the tab view except what the pane carries.

A small number of cases in every run, more in a release, from a seed of the day, with `VIEW_FUZZ_CASES` and `VIEW_FUZZ_SEED` to run a seed again, as `UNDO_FUZZ_CASES`/`UNDO_FUZZ_SEED` do.

### F. By hand

An `--automation` scenario (`tools/capture/README.md`) that saves a tab view, applies it into a folder with its own view in each of the three choices, saves a window view and opens it, and is checked on screen by whoever builds it, as [principles.md](../principles.md) asks.

## Still open

1. **Views or Layouts** for Tab View and Window View. Proposed: Views, as Folder View has already shipped and "folder layout" reads as how files are kept on disk.
2. **Folder: "Same as the other pane".** A choice besides a fixed folder that opens the right pane on whatever the left pane shows when the tab view is applied, for comparing. It is the only "follows what is on screen" choice that differs from leaving Folder unchecked.
