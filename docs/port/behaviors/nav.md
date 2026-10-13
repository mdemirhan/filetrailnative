# B-NAV: Navigation, history, Back/Forward, Go menu, startup and folder memory

Improvements this area belongs to: A6, A8, A14.

What it does beyond Finder, in code terms:
- Every tab owns a history list and index (`historyPaths`, `historyIndex`) plus a per-folder "view memory" (selection and `.content-scroll` offsets). Back, Forward and the hold-menu jump redraw a folder exactly as it was left, and forget memories of folders that dropped out of the history.
- Back/Forward buttons open a Safari-style hold menu (350 ms hold or right-click, 12 rows, keyboard driven) listing where each step leads.
- Keyboard movement is view-aware (details, compact list columns, icon rows), keeps its place when the selected items vanish (`gapIndex`), pages by "one line less than fits", and scrolls only as far as needed (`useRevealIndex` plus per-view reveal math) without fighting a scroll position that Back restored.
- Reloads are quiet and guarded: request ids drop stale answers, a view epoch keeps one tab's answers out of another, a folder that vanished falls back to the nearest existing ancestor, and an unreadable-but-present folder stays on screen with its error.
- Startup restores tabs, tree roots and favorite selection, and a folder counts as "visited" for the Go To box only after 5 s on screen or use.

Paths in Evidence are relative to `apps/desktop/src/renderer/` unless they start with `shared/`. Abbreviations: NC = hooks/useExplorerNavigationController.ts, EN = lib/explorerNavigation.ts, SN = lib/startupNavigation.ts, FVM = lib/folderViewMemory.ts, RI = hooks/useRevealIndex.ts, GM = lib/goMenuPlaces.ts, FVT = lib/folderVisitTracker.ts, HM = lib/historyMenu.ts, HB = components/HistoryButton.tsx, PU = lib/pathUtils.ts, SH = hooks/useExplorerShortcuts.ts, AC = hooks/useExplorerActions.ts, TB = hooks/useExplorerTabs.ts, ET = lib/explorerTabs.ts, CS = lib/contentSelection.ts, SP = lib/shortcutPolicy.ts, CP = components/ContentPane.tsx, APP = App.tsx, RCA = lib/rendererCommandAvailability.ts, IG = lib/iconGridLayout.ts, FL = lib/flowListLayout.ts, LF = lib/listFilter.ts, FW = hooks/useFolderWatch.ts, EW = components/ExplorerWorkspace.tsx.

"Push", "replace" and "skip" are the three history modes of `navigateTo` (NC:1050). "Folder tree" means the sidebar tree of file-system folders; "Favorites" and "Locations" are sidebar sections.

## 1. History list model

| ID | Behavior | Evidence | Test ids |
|---|---|---|---|
| B-NAV-001 | Each tab has its own history: an ordered list of folder paths and a current index. A tab that starts at a folder through startup has `[startupPath]` and index 0 (the first load is a "replace" on an empty list, which creates the list). | NC:324-334, APP:1960 | T-d8fbdd46 |
| B-NAV-002 | A "push" navigation (double-click or Return on a folder, tree or sidebar click, path bar click, Enclosing Folder, Go menu place, Go to Folder, Home, reveal-in-folder into another folder) cuts off every entry after the current index, appends the new folder and moves the index onto it. | NC:315-322 | T-578cd148 |
| B-NAV-003 | Push does not de-duplicate: pushing the folder that is already current (for example Go > Applications while in /Applications, or clicking the current folder in the tree) appends a second identical entry, so Back then lands on the same folder. | NC:317-320 | - |
| B-NAV-004 | A "replace" navigation overwrites the entry at the current index (or creates `[path]` when the list is empty) and leaves the index alone. It is used by reload-type reads: Refresh (⌘R), changing the sort, toggling Folders First, toggling hidden files, startup, reveal-in-folder when the file's folder is already shown, Home when already at Home, and the Info panel's path link when it points at the current folder. | NC:324-334, NC:1865, NC:2020, NC:2037, NC:1775, NC:787, APP:2589 | T-1e882d85 |
| B-NAV-005 | A "skip" navigation does not touch the history list or index. Back, Forward, hold-menu jumps, tab re-activation and the quiet reloads (watcher, tab coming back) use it. | NC:735-768, NC:1938, NC:1984 | T-6d636796 |
| B-NAV-006 | A folder is added to the history only after its listing has arrived and been applied, so a push to a folder that cannot be listed (with no `persistOnError`) adds no entry and leaves the previous folder, entry and index unchanged. | NC:1144, NC:1214-1215 | - |
| B-NAV-007 | Navigations started from the sidebar (Favorites, Locations, Trash) and a startup favorite use `persistOnError: true`: a folder that fails to list is still opened (empty list plus the error text) and the history is updated with it. | NC:1187-1212, NC:1492-1511 | - |
| B-NAV-008 | The history list has no length limit; only the hold menu is capped (12 rows per direction). | NC:315-335, HM:17 | T-389442af |
| B-NAV-009 | `canGoBack` is `historyIndex > 0`; `canGoForward` is `historyIndex >= 0 && historyIndex < historyPaths.length - 1`. The Back and Forward toolbar buttons are disabled when false, and the Back/Forward menu commands are unavailable. | APP:2038-2039, RCA:253-256, EW:1151 | T-6d636796 |
| B-NAV-010 | ⌘T makes a new tab on the same folder with a fresh history `[currentFolder]` at index 0, nothing selected, list scrolled to the top and an empty view memory; Back in it has nowhere to go. | TB:470-495 | T-aa6d3211 |
| B-NAV-011 | Open in New Tab (folder alias, context menu, ⌘-double-click) starts the new tab with an empty history (`[]`, index -1); loading its folder then pushes it, giving `[folder]` at index 0. | TB:498-515 | T-ce789a8a |
| B-NAV-012 | A reopened closed tab keeps only its folder and view settings: history becomes `[folder]` at index 0, and its selection, view memory and search are gone. | ET:249-258 | T-6d407a9e |
| B-NAV-013 | Switching tabs keeps each tab's history, index and view memories in its snapshot; switching back restores the same list and index. | TB:258-259, TB:329-331 | T-aa6d3211 |

## 2. Back, Forward and jumping through the history

| ID | Behavior | Evidence | Test ids |
|---|---|---|---|
| B-NAV-014 | Back is ⌘[ or ⌘← (menu Go > Back, toolbar Back click). With index greater than 0 it moves the index to index-1 immediately (before the folder is read) and opens that folder in "skip" mode with view restore. | NC:735-744, shared/shortcuts.ts:43-48, SH:528-534 | T-6d636796 |
| B-NAV-015 | Forward is ⌘] or ⌘→ (menu Go > Forward, toolbar Forward click). With a next entry it moves the index to index+1 immediately and opens that folder in "skip" mode with view restore. | NC:746-755, shared/shortcuts.ts:50-55, SH:536-542 | T-6d636796 |
| B-NAV-016 | Back at the first entry, or Forward at the last, does nothing: no navigation, no error, the folder and index stay. | NC:736-739, NC:747-750 | T-6d636796 |
| B-NAV-017 | Back and Forward move only within the list; the entries ahead of or behind the index stay in the list (they are not removed) until a push cuts the forward part. | NC:735-755 | T-578cd148 |
| B-NAV-018 | After opening a different folder from the middle of the history, the entries that were ahead are gone: Forward goes to the new folder only, and Back returns to where the push was made. | NC:315-322 | T-578cd148 |
| B-NAV-019 | Back and Forward never count as a folder visit for the Go To box (only "push" arrivals do). | NC:1145-1149 | T-0540857f |
| B-NAV-020 | Back and Forward always select the folder's row in the folder tree (not a Favorites row), switch the left subview to "tree", and expand the tree down to it. A folder first reached through a Favorite is therefore shown selected in the tree when returned to. | NC:1157-1178 | - |
| B-NAV-021 | Back and Forward leave search results: when search results are showing and the new folder arrives, the results are hidden and the search field is cleared, unless a reload explicitly keeps them. | NC:915-924 | T-26fc62ad |
| B-NAV-022 | Back or Forward to a folder that no longer exists or cannot be read opens nothing (no ancestor fallback, no `persistOnError`): the previous folder stays on screen, `directoryError` and `locationError` are set to the error message, and the history index has already moved. | NC:740-743, NC:1180-1215 | - |
| B-NAV-023 | A navigation answer that arrives after a newer navigation was started (different request id) is dropped completely: it does not update the listing, the history, the loading flag or the tree selection. | NC:1098, NC:1119-1121, NC:1181-1183, NC:1217-1219 | T-3de1e419 |
| B-NAV-024 | An answer that arrives after another tab came to the front (view epoch changed) does not select tree rows, expand the tree further, or touch history for the tab on screen. | NC:197-200, NC:1162-1166, NC:1428 | T-0cd8f183 |

## 3. Back/Forward hold menu

| ID | Behavior | Evidence | Test ids |
|---|---|---|---|
| B-NAV-025 | Pressing the primary mouse button (button 0) on Back or Forward and holding 350 ms (`HISTORY_MENU_HOLD_MS`) opens a menu of folders; the press is ignored while the menu is already open and for other buttons. | HB:9, HB:168-179 | T-01a9e06b |
| B-NAV-026 | The menu appears under the button at left = the button's left edge and top = the button's bottom + 6 px, and is kept inside the viewport. | HB:55-63, HB:46 | - |
| B-NAV-027 | Releasing the press, leaving the button, or cancelling the pointer before 350 ms cancels the hold: no menu opens and the click steps once. | HB:180-182 | T-943ef637, T-b9cc1ec4 |
| B-NAV-028 | A right-click (context menu event) on Back or Forward opens the menu at once and prevents the system context menu. | HB:183-187 | T-84e77094 |
| B-NAV-029 | The click that ends a hold-opened menu does not step Back/Forward; the menu stays open. The "opened by hold" flag is cleared when the menu closes, so a hold that ended away from the button cannot swallow the next click. | HB:39, HB:80-86, HB:188-192 | T-01a9e06b |
| B-NAV-030 | Clicking the button while its menu is open closes the menu and does not step. | HB:193-196 | - |
| B-NAV-031 | The menu is not opened when there are no entries (button disabled or no history in that direction). | HB:55-59 | T-2cb340ef |
| B-NAV-032 | Back lists history indices index-1 down to 0 (nearest first); Forward lists index+1 up to the last. Each list holds at most 12 rows (`HISTORY_MENU_LIMIT`). | HM:17-45 | T-8f3fa1a7, T-87426be6, T-389442af |
| B-NAV-033 | A row shows two texts: the folder's name as the sidebar labels it ("Home" for the home folder, "Applications", "Trash", "Macintosh HD" for `/`, otherwise the last path component), then a detail: the containing folder with the home folder abbreviated to `~` (for example `~`, `~/src`, `/Users`), `/` for a top-level folder such as /Applications, and empty for `/`. The row's tooltip is the full path. | HM:47-55, lib/favorites.ts:237-252, lib/places.ts:191-196, HB:222-232 | T-8f3fa1a7, T-5b67fbc3 |
| B-NAV-034 | Choosing a row (click) closes the menu and jumps to that history index in "skip" mode with view restore, without adding history; choosing the current index does nothing. | NC:759-768, HB:226-229 | T-01a9e06b, T-5b67fbc3 |
| B-NAV-035 | After a jump, the folders it passed over stay in the history in the opposite direction's menu: jumping back two entries leaves both ahead. | NC:759-768 | T-5b67fbc3 |
| B-NAV-036 | When the menu opens the first row is active; ArrowDown/ArrowUp move the active row with wrap-around (count modulo); hovering a row makes it active. The keyboard focus stays where it was (the list or the sidebar); rows have no tab stop. | HB:44, HB:120-124, HB:216-225 | T-84e77094 |
| B-NAV-037 | Return or Space picks the active row, Escape or Tab closes the menu; any other key without ⌘, ⌃ or ⌥ is swallowed (default prevented, propagation stopped) so the file list does not see it. | HB:112-135 | T-84e77094 |
| B-NAV-038 | A key pressed with ⌘, ⌃ or ⌥ closes the menu and is not swallowed, so the command still runs. | HB:113-116 | - |
| B-NAV-039 | The menu closes on a pointer press outside the menu and button, on window resize, on window blur (window inactive), and when the history changes underneath (entry count or first entry path changes). | HB:75-78, HB:99-146 | T-84e77094 |
| B-NAV-040 | The menu is a portal on `document.body` with class `toolbar-menu history-menu`, `role="menu"` and accessible name "Back history" or "Forward history"; rows are `role="menuitem"`, the active one has `aria-current="true"`. | HB:204-221 | T-01a9e06b |
| B-NAV-041 | The off-screen measuring copy of the toolbar (`interactive=false`) renders a plain disabled-aware button that does nothing on click or right-click. | HB:149-155 | T-36bede3d |
| B-NAV-042 | The tooltips are "Back (⌘[)", "Forward (⌘])" and "Enclosing Folder (⌘↑)" with the current shortcut. | EW:1135-1190, lib/tooltips.test.ts:32-34 | - |

## 4. Folder view memory (selection and scroll on Back/Forward)

| ID | Behavior | Evidence | Test ids |
|---|---|---|---|
| B-NAV-043 | Whenever a navigation targets a folder different from the one on screen, the folder being left is first remembered: its selection (paths, anchor, lead) and the `.content-scroll` element's `scrollTop` and `scrollLeft` (0 when no scroller). | NC:1089-1091, NC:1014-1033 | T-6250e1a8 |
| B-NAV-044 | Nothing is remembered when the folder is left while search results are showing, or when no folder is on screen. | NC:1016-1018 | - |
| B-NAV-045 | The memory is keyed by folder path, replaces an earlier memory for the same folder, and keeps only folders that are in the tab's history at that moment (plus the folder just left). A folder no longer reachable by Back or Forward is forgotten. | FVM:14-33, NC:1031 | T-2e08aed7 |
| B-NAV-046 | A memory is applied only when the navigation asks to restore the view: Back, Forward, hold-menu jumps and a tab being shown again. Opening a folder any other way (double-click, tree click, ⌘↑, Go menu) starts with nothing selected and the list at the top. | NC:1133-1141, NC:1089 | T-6250e1a8 |
| B-NAV-047 | Back to a folder restores the exact set of selected items with the same anchor and lead path. | NC:1134-1138 | T-6250e1a8 |
| B-NAV-048 | The restored selection is checked against the freshly read listing: items that no longer exist are dropped (the lead and anchor fall back to the last remaining item); if none remain, nothing is selected. No neighbouring item is selected in their place on Back. | NC:1135-1138, CS:27-56 | T-5e21e75c, T-7b475603 |
| B-NAV-049 | The restored selection carries no `gapIndex`, so the first arrow key after such a Back starts from the first item, not from where the removed items stood. | NC:1135-1138, CS:35-41 | - |
| B-NAV-050 | The restored scroll offsets (top and left) are written to the list's scroll element in a layout effect right after the folder is drawn, before the window paints, for Details, Compact List and Icons alike. | NC:1036-1048, NC:1139-1140 | T-bcd1990e |
| B-NAV-051 | The view's keep-selection-in-view logic does not undo a restored scroll: after Back the selected item may stay off screen if that is where the list was scrolled. | RI:56-59, CP:1236-1263 | T-bcd1990e |
| B-NAV-052 | Without a memory for the folder (never left, or dropped from history), Back shows it with nothing selected and the list at the top. | NC:1133-1134 | - |
| B-NAV-053 | Back does not restore a typed list filter: the filter is dropped whenever the folder or the kind of list (folder or one search) changes. | NC:636-647 | - |
| B-NAV-054 | The per-folder memories travel with the tab: they are saved in the tab's snapshot and put back when the tab is shown. A new tab (⌘T) starts with none. | TB:286, TB:331, TB:488 | T-aa6d3211 |

## 5. Enclosing folder

| ID | Behavior | Evidence | Test ids |
|---|---|---|---|
| B-NAV-055 | ⌘↑ (menu Go > Enclosing Folder) with the file list focused (or no pane focused) pushes `parentDirectoryPath(currentPath)`. | SH:553-562, SH:1415-1425 | T-e07c2ef1 |
| B-NAV-056 | The toolbar's Enclosing Folder button (aria-label "Enclosing Folder") pushes the parent of the current folder. | EW:1177-1188 | T-15e73fcb |
| B-NAV-057 | `parentDirectoryPath`: `/` has no parent (null); a top-level folder such as `/Users` has parent `/`; empty and repeated slashes are ignored. | EN:7-16 | T-4ab16ef0 |
| B-NAV-058 | The toolbar button is disabled, and the command unavailable, when no folder is shown or the folder is `/`. In the file list the parent of a disk root such as /Volumes/Backup is /Volumes (the content ⌘↑ does not stop at a volume root). | EW:1183, RCA:257-258, EN:7-16 | - |
| B-NAV-059 | After going to the enclosing folder nothing is selected and the list is at the top (the child you came from is not selected). Back from there restores the earlier folder's selection and scroll. | SH:553-562, NC:1133-1141 | T-6250e1a8, T-e07c2ef1 |
| B-NAV-060 | With the tree focused, ⌘↑ selects the tree's parent folder row (push) instead: for a file-system row it opens `parentDirectoryPath`, even above the tree root (the tree then re-roots), and it stops at a volume root (`/` or `/Volumes/X`). | NC:1558-1575, SH:544-551 | T-5acdef9e |
| B-NAV-061 | In the tree, ⌘↑ does nothing for a Favorite or Location row and in the separate Favorites subview. | NC:1560-1566 | - |
| B-NAV-062 | The menu command Enclosing Folder chooses between these two by the focused pane: tree focused uses the tree parent, otherwise the file-list parent. | SH:1415-1425 | T-5acdef9e |
| B-NAV-063 | In search results ⌘↑ opens the parent of the folder under the results (the search origin folder shown by `currentPath`), not the parent of the selected result. | SH:553-562 | - |

## 6. Opening folders and items from the file list

| ID | Behavior | Evidence | Test ids |
|---|---|---|---|
| B-NAV-064 | Double-clicking a folder, or Return / ⌘↓ / ⌘O on a single selected folder (Return opens when the Return-key setting is "open"; with the "rename" setting Return renames and ⌘O or ⌘↓ open), pushes it. | AC:3229-3237, SH:946-975, SH:566-583 | T-6d636796 |
| B-NAV-065 | Opening several selected items (more than one path) hands each one to macOS in order (`system:openPath`), folders included; only a single selected entry goes through the navigate-into-folder logic. | AC:3325-3347 | T-113332f0 |
| B-NAV-066 | More than the open-item limit (`openItemLimit`) selected items shows a notice and opens nothing. | AC:3329-3332 | - |
| B-NAV-067 | An app or package (`bundle`) opens in its own app instead of being entered; Show Package Contents in its context menu pushes into it. | AC:3230-3233, AC:3030-3035 | T-329e368a |
| B-NAV-068 | A folder alias (`symlink_directory`) is resolved with `path:resolve` and its target folder is pushed; if the lookup fails nothing happens and nothing is shown. | AC:3238-3247 | T-6d8a0ef5, T-19c1846b |
| B-NAV-069 | If another tab came to the front while an alias was being resolved (view epoch changed), the folder is not opened. | AC:3239-3243 | - |
| B-NAV-070 | A file alias (`symlink_file`) is resolved and its target opened in its default app; an unresolvable alias opens nothing. | AC:3248-3254 | T-c4e8b2e2, T-19c1846b |
| B-NAV-071 | Opening a file or app counts as "using" the folder for the Go To box (the pending visit counts as a stay). | AC:3286-3288, NC:994-996 | T-7d304c05 |
| B-NAV-072 | A disk image (.dmg) opens by mounting it and opening its volume in a new window, or a new tab when Settings says so; the current tab does not navigate. Failure shows a dialog "The disk image “name” couldn’t be opened." and a hand-off to DiskImageMounter opens nothing. | AC:3286-3322 | T-712b64dd, T-111e25b3, T-213e5bdd, T-a4670ebf, T-aa290e2d |
| B-NAV-073 | Open in New Tab for a folder alias opens a tab on the alias's target. | AC:3263-3277 | T-ce789a8a |
| B-NAV-074 | In search results Return opens each selected result with `openPaths` (the "edit in text editor" activation action does not apply). | AC:4340-4348 | - |
| B-NAV-075 | Reveal in Folder on a search result: pushes the result's parent folder (replace when it is already the current folder), selects the result, then focuses the file list. If the navigation fails nothing is selected. | AC:2747-2766 | - |
| B-NAV-076 | The path bar's crumbs push the clicked folder; in search results the path bar ends in the selected result, and clicking that last crumb opens the result like a double-click. | APP:2412-2421 | - |
| B-NAV-077 | The Info panel's path link pushes that folder (replace when it is the current folder). | APP:2588-2590 | - |

## 7. Sidebar and folder tree navigation

| ID | Behavior | Evidence | Test ids |
|---|---|---|---|
| B-NAV-078 | Clicking a file-system folder row in the tree selects it, switches the left subview to "tree" and pushes the folder. | NC:1514-1520, NC:1440-1456 | - |
| B-NAV-079 | Folder rows that are symlinks navigate with `syncTree: false`, tree selection "preserve" and `persistOnError: true`, and cannot be expanded: toggling and Right-arrow ignore them. | NC:1446-1454, NC:1458-1462, NC:1713-1715 | - |
| B-NAV-080 | Clicking a Favorite selects the Favorite row (and switches to the "favorites" subview when Favorites are separate) and pushes its folder with `persistOnError`; the tree keeps its root unless the folder is outside it. | NC:1500-1511 | - |
| B-NAV-081 | Clicking a Location (Macintosh HD, another disk, the Trash) keeps that Location row selected, pushes its path, and resets the tree to the place's own top: Home when the place is inside Home, otherwise the volume root (`/` or `/Volumes/X`); the tree is left as is when already rooted there. | NC:1486-1498, NC:998-1010, lib/explorerAppUtils.ts:701-708 | - |
| B-NAV-082 | The Trash, gone to from the sidebar or the Go menu, leaves the tree unchanged (it is not a folder the tree shows) but selects its Location row and pushes history. | NC:1094-1097 | T-1993a471 |
| B-NAV-083 | A Trash that macOS refuses to list (EPERM) still opens: the list area shows "File Trail needs Full Disk Access to show the Trash" with an "Open Privacy Settings" button instead of the raw error. | NC:1187-1197, CP:2392-2405 | T-e1ce4669 |
| B-NAV-084 | The Favorites and Locations headings are never selected: clicking one, or paging, arrowing or typing past it, does not change the folder on screen; arrow keys and paging skip them. | NC:1480-1484, NC:1634-1636, NC:485-490 | - |
| B-NAV-085 | The Locations heading click uses "skip" history mode but, being a heading, returns before navigating. | APP:2324-2326, NC:1482-1484 | - |
| B-NAV-086 | Every selection move in the tree is itself a navigation: ArrowUp, ArrowDown, Home, End, Page keys and type-to-select each push the newly selected folder (history grows with each key press). | NC:1696-1705, NC:1664-1679, NC:514, NC:722-731 | - |
| B-NAV-087 | ArrowUp/ArrowDown in the tree move one visible row (Up clamps at the first row, Down at the last); Home and End select the first and last visible row. | NC:1680-1705, NC:1664-1679 | - |
| B-NAV-088 | ArrowRight on a folder row: not loaded yet loads and expands it (no navigation); loaded but collapsed with children expands it; expanded with children selects the first child (push); Favorites, Locations and symlinks do nothing. | NC:1707-1732 | - |
| B-NAV-089 | ArrowLeft on an expanded row with children collapses it; otherwise it selects the parent folder (push); at the tree root or a volume root it does nothing; Favorites and Locations do nothing. | NC:1735-1756 | - |
| B-NAV-090 | With Favorites in a separate subview, Up/Down move through the Favorites and then the (expanded) Locations rows; Down from the last one moves to the first tree row (subview becomes "tree"); Up from the first tree row moves to the last Favorites/Locations row; Left/Right do nothing; Home/End select the first/last. | NC:1580-1630, NC:1636-1651, NC:1682-1695 | - |
| B-NAV-091 | Return on the tree (and ⌘↓): a Favorite or Location navigates; a file-system folder toggles expansion (loads first if unloaded) rather than navigating, because selecting the row already navigated; a symlink navigates. | NC:1522-1556, SH:921-927 | - |
| B-NAV-092 | ⌘O with the tree focused navigates (push) to the selected Favorite or file-system folder instead of opening it externally. | SH:1115-1126 | - |
| B-NAV-093 | Typing in the tree (printable non-space character, no ⌘/⌃/⌥) builds a query; each key restarts a 1000 ms (`TREE_TYPEAHEAD_RESET_MS`) idle timer that clears it; the first visible row whose lowercase trimmed label starts with the query is selected and pushed. In the separate Favorites subview only Favorites and Locations are searched. | NC:685-733, NC:2414, lib/typeahead.ts:7-9 | T-eb1d7cfe |
| B-NAV-094 | The typeahead query is cleared when the focused pane changes or loses focus. | NC:2117-2125 | - |
| B-NAV-095 | The tree lists children without hidden items unless Show Hidden is on, but a hidden folder on the path to the current folder is forced visible (only that one child); a package on the path to the current folder is added in name order (once). The `/Volumes` folder is left out unless hidden files are shown. | NC:1262-1376, EN:55-113 | T-431cfb70, T-56d4103f, T-223415d5, T-4becddde |
| B-NAV-096 | Opening a folder expands each ancestor between the tree root and the folder (loading them in order), loads the folder's own children only if it was expanded (or on forced reload), and stops if the tab is no longer on screen. | NC:1394-1438, EN:20-50 | T-620275a3, T-8012dbd4, T-07c435a7 |
| B-NAV-097 | A folder outside the current tree root re-roots the tree: Home when the folder is inside Home, otherwise its volume root. A tree rooted at `/` holds only folders on the startup volume. | NC:1401-1412, lib/explorerAppUtils.ts:694-708 | - |
| B-NAV-098 | "Use as Tree Root" (⌘⇧R) roots the tree at the selected folder (the folder-tree selection, a selected folder in the list, or a right-clicked folder, by focus) and opens it (push, or replace when already current). | NC:772-785, SH:287-317 | - |
| B-NAV-099 | Home (⌘⇧H, Go > Home) roots the tree at the home folder and opens it (push, or replace when already at Home); it does nothing until the home path is known. | NC:787-789, SH:760-766 | - |
| B-NAV-100 | The Page keys in the tree move the selection (and navigate by push) by one page less one row; the tree scrolls only when the new row is outside the pane, by the distance between the old and new rows. Row heights are 26 px (21 px compact). | NC:482-516, lib/layoutTokens.ts:16-23 | T-dec54fc2 |
| B-NAV-101 | Hiding the folder tree while it has the keyboard moves focus to the file list. | APP:889-893 | - |
| B-NAV-102 | Tab (without ⌘, ⌃, ⌥) toggles focus between the tree and the file list: from the tree to the list; from the list to the tree if the tree is open, otherwise it stays in the list. | SH:360-402 | - |

## 8. Go menu, Go to Folder, Home

| ID | Behavior | Evidence | Test ids |
|---|---|---|---|
| B-NAV-103 | The Go menu places Documents, Desktop, Downloads and Library resolve to `<home>/Documents` etc. and open as a plain folder navigation (push); the tree is only re-rooted if the folder is outside it. | GM:20-53, SH:1280-1287 | T-108c669a |
| B-NAV-104 | Go > Applications opens `/Applications` as a plain folder (push). | GM:44-46, SH:1285-1287 | T-108c669a |
| B-NAV-105 | Go > Macintosh HD and Go > Trash open as sidebar Locations (as clicking those rows does): `/` and `<home>/.Trash`, with the Location row selected and the tree reset to the place's top. | GM:41-43, GM:50-52, SH:1282-1283, APP:1573 | T-108c669a |
| B-NAV-106 | The home-based Go places (Documents, Desktop, Downloads, Library, Trash) are unavailable until the home path is known; Macintosh HD and Applications are always available. | GM:36-53, RCA:227-234 | T-e67aa010, T-9e77156e |
| B-NAV-107 | The Go place commands have no default keyboard shortcut. | shared/shortcuts.ts:72-120 | - |
| B-NAV-108 | ⌘K and ⌘⇧G (Go > Go to Folder…) open the Go to Folder box: the active element is blurred, the explorer view is shown, the previous location error cleared, no pane is focused and the dialog opens. | shared/shortcuts.ts:107-112, APP:2119-2127 | - |
| B-NAV-109 | Submitting a path trims whitespace, expands `~` and `~/…` to the home folder (only when home is known; `~user` is not expanded), pushes it as a "Go To" visit, and closes the box only if the folder opened. | NC:2049-2070, PU:17-28 | - |
| B-NAV-110 | A path that cannot be opened keeps the box open and shows the error message; a Go To submit has no `persistOnError` and no ancestor fallback. | NC:2054-2066, NC:1180-1215 | - |
| B-NAV-111 | A previously visited folder chosen in the box that no longer exists (properties lookup says missing) is removed from the visited list; one that failed for another reason (permission, disk not connected) is kept. | APP:2163-2180 | - |
| B-NAV-112 | While the Go to Folder box is open (and any action notice or copy/paste dialog is open) every navigation command is blocked: Back, Forward, Enclosing Folder, Home, the Go places and Refresh. | SP:260-278, SP:310-316 | T-c6b12327, T-16e0aa3f |

## 9. Loading, empty and error states of the folder on screen

| ID | Behavior | Evidence | Test ids |
|---|---|---|---|
| B-NAV-113 | While a navigation that is not quiet runs: the loading flag is true, and `directoryError` and `locationError` are cleared. The previous folder's listing stays on screen until the new folder's listing arrives; `currentPath` changes only on arrival. | NC:1099-1132 | - |
| B-NAV-114 | "Loading…" is shown only when the loading folder has no entries on screen and loading lasts longer than 400 ms (`FOLDER_LOADING_DELAY_MS`). | CP:2355-2385 | - |
| B-NAV-115 | A quiet navigation (watcher, tab coming back) neither raises the loading flag nor clears the error beforehand; the error is cleared only when the answer arrives successfully. | NC:1104-1110, NC:1122-1125 | - |
| B-NAV-116 | An empty folder shows "Empty folder"; when hidden files are off and the folder holds N hidden items it shows "Empty folder · N hidden item(s)" ("1 hidden item", "3 hidden items"). | CP:2442-2468, APP:529-534 | - |
| B-NAV-117 | When no folder is selected (the tree selection was cleared) the list shows "Select a folder to see what’s in it." and the folder, entries, details, search results and Info panel are emptied. | CP:2456-2461, NC:310-313, NC:847-876 | - |
| B-NAV-118 | A folder that fails to read shows "Couldn’t open this folder" followed by the error text. | CP:2406-2412 | T-e1ce4669 |
| B-NAV-119 | A read error counts as "folder gone" only when the message starts with `ENOENT:` or `ENOTDIR:`, or starts with "Path is not a directory: "; the same words later in the message (inside the path) do not count, and EACCES/EPERM are not "gone". | EN:296-298 | T-4dd670bb, T-ab3e5d2f |
| B-NAV-120 | `persistOnError: "unlessGone"` opens an unreadable folder (listing replaced by an empty list and the error) but opens nothing for a gone folder, so the caller can try the folder above. | NC:1187-1192 | T-e1ce4669 |
| B-NAV-121 | `navigateToNearestExistingFolder` tries the folder, then each ancestor up to `/` (nearest first); the first that opens wins. Ancestors are opened in "replace" mode (the dead folder's history entry is overwritten) and with default options (selection cleared, search results left); it stops if a newer navigation took over. | NC:1902-1926, ET:223-231 | T-654ba719, T-d5f7b879 |
| B-NAV-122 | Startup that cannot read its folder (and is not a favorite) falls back to Home with the tree rooted at Home (not to the nearest existing ancestor); a startup favorite uses `persistOnError` and shows its error. | APP:1960-1995 | - |
| B-NAV-123 | Clearing the tree selection (nothing selected in the sidebar) empties the content pane and leaves search mode. | NC:310-313, NC:863-866 | - |

## 10. Reading a folder again (Refresh, sort, hidden files, outside changes)

| ID | Behavior | Evidence | Test ids |
|---|---|---|---|
| B-NAV-124 | ⌘R / View > Refresh in a folder first clears the main-process caches (`app:clearCaches`; a failure is logged and ignored), then reads the folder again in "replace" mode with `keepSelection` and `keepSearchResults`, forcing the tree to reload. The selection stays. | NC:1836-1872, SH:595-609 | T-1e882d85, T-676daa6c |
| B-NAV-125 | With search results showing, ⌘R runs the search again and does not clear caches or re-read the folder. | SH:1256-1262, SH:602-612 | T-1d9870a1 |
| B-NAV-126 | A Refresh that finds a different folder being opened (pending navigation to another path) leaves it alone after clearing caches, and a Refresh that finds another tab came to the front stops. | NC:1851-1863 | T-3de1e419 |
| B-NAV-127 | Choosing a sort key reads the folder again ("replace") in that order. The same key flips the direction; a new key starts descending for Modified and Size and ascending for Name and Kind. The folder stays on screen and the choice is saved for the tab and for new tabs. | NC:2002-2029 | T-4023bc38, T-bae92ca4 |
| B-NAV-128 | Toggling Folders First re-reads the folder ("replace") with the flag flipped. | NC:2031-2046 | T-c45c82d1 |
| B-NAV-129 | Sort and Folders First commands are unavailable, and do nothing, while search results are showing; the folder underneath is not re-read. | RCA:245-251, SH:1397-1402 | T-26fc62ad |
| B-NAV-130 | Toggling hidden files (⌘⇧.) flips the setting, reinitialises the tree for the current folder (unless the selected tree row is a Favorite or symlink) and re-reads the folder ("replace"). | NC:1764-1786 | T-4e880a90 |
| B-NAV-131 | With search results showing, toggling hidden files re-reads the folder underneath but keeps the results on screen; the search itself runs again. | NC:1759-1786 | T-c05f1d45 |
| B-NAV-132 | A folder re-read without `keepSelection` (sort change, Folders First, hidden toggle, Go To the same folder) clears the selection; a re-read with `keepSelection` (Refresh, watcher, tab coming back) keeps the selected items that still exist. | NC:937-954 | T-1e882d85 |
| B-NAV-133 | A folder re-read that finds the same items in the same order with the same details keeps the very same listing objects on screen (so nothing is redrawn); only items whose fields changed are replaced. | NC:898-914, EN:300-337 | T-444bcc56, T-28f2d6e2, T-4b092cae |
| B-NAV-134 | Changes made outside the app to the folder on screen are read quietly (no Loading…): selection, search results, tree and the Info panel's target are kept; the items reported as changed have their details read again. | NC:1962-2000 | T-bfbc3d06 |
| B-NAV-135 | An outside change to a folder that is no longer the one on screen is ignored; one that arrives while a navigation to another folder is pending is treated as handled; one that arrives while the same folder is being read answers "not yet" and is retried after 250 ms. | NC:1966-1975, FW:5-6 | T-b8561d78, T-fc102300 |
| B-NAV-136 | Outside changes are held back and read once together after release while: another main view is open, the explorer focus is suppressed, a copy/paste dialog, a Go to Folder box, an alert or a context menu is open, a write operation is running, or a drag is active. | APP:1397-1408, FW:11-16 | T-bfbc3d06 |
| B-NAV-137 | More than 1000 changed items, or any change reported for "anything", makes the whole listing's details be read again. | FW:7-8, FW:40-48 | T-277f84be, T-73c88821 |
| B-NAV-138 | When the folder on screen is deleted while shown, the next watcher reload falls back to the nearest existing ancestor (opened in "replace" mode, selection not kept); an unreadable folder stays with its error. | NC:1984-1993, NC:1902-1926 | T-d5f7b879 |
| B-NAV-139 | A folder renamed or moved by another window's finished operation makes the tab on screen re-read at the new path in "replace" mode: only the current history entry is rewritten. | AC:978-989 | - |
| B-NAV-140 | Items that a finished write operation took out of the folder (trash, delete, move away) leave the selection at once, before the folder is read again, so the list does not scroll to a vanished item. | AC:812-833 | T-51260c52 |
| B-NAV-141 | Items pasted into the folder being opened are selected when it arrives: those present in the new listing become the selection (anchor the first, lead the last). | NC:925-954 | - |
| B-NAV-142 | After a re-read, the Info panel and Info row ask for their item again (immediately for a folder read by the app; after an outside change only if the shown item may have changed: the shown path is in the changed paths, or it is the folder itself and the listing changed). | NC:955-982 | - |

## 11. Keyboard selection in the file list

| ID | Behavior | Evidence | Test ids |
|---|---|---|---|
| B-NAV-143 | With the file list focused, ArrowUp/Down/Left/Right, Home and End (no ⌘, ⌃, ⌥) move the selection; with an empty list they do nothing. Plain arrows replace the selection with the new item; ⇧+arrow extends the range from the anchor to the new lead. | SH:874-919 | T-7216f450 |
| B-NAV-144 | Home selects the first item and End the last, in every view. | EN:146-151 | - |
| B-NAV-145 | Details view: Up and Left go to the previous item, Down and Right to the next; clamped at the ends, no wrap. | EN:176-181 | T-7216f450 |
| B-NAV-146 | Compact List view (items flow in columns): Up/Down move one item; Left/Right move by the number of rows per column, clamped to the first or last item. | EN:202-211 | T-7216f450 |
| B-NAV-147 | Icons view: Left/Right move one item (continuing into the next or previous row); Up moves one row up (stays put on the first row); Down moves one row down; from above a shorter last row, Down goes to the last item; on the last row it stays. | EN:185-200 | T-70433c0d |
| B-NAV-148 | The number of columns used for arrows and paging is the view's current layout (rows per column for List, icons per row for Icons, 1 for Details). | SH:896-899, EW onLayoutColumnsChange, CP:1225-1228 | - |
| B-NAV-149 | With nothing selected, any arrow key selects the first item (index 0); the keys Home/End still go to first/last. | EN:153-156 | T-8888c974 |
| B-NAV-150 | When every selected item left the list (moved to the Trash, deleted), the selection becomes empty but remembers `gapIndex` (how many earlier surviving items there were; capped at the list length). | CS:5-8, CS:27-41, CS:58-71 | T-c7532927 |
| B-NAV-151 | With a `gapIndex`, Down/Right (and in Details/List the key that moves by one) selects the item that took the gone item's place; Up/Left selects the one before it, clamped to the list; in Icons, Up/Down step a row and in List, Left/Right step a column, counted from that place. | EN:153-171 | T-58ce0423 |
| B-NAV-152 | The `gapIndex` stays as long as the selection remains empty; an explicit selection replaces it. | CS:34-41 | T-c7532927 |
| B-NAV-153 | PageUp and PageDown (default keys) move the selection one page; Ctrl+U and Ctrl+D move half a page; ⇧ with a paging key extends the selection by the same move (unless ⇧+key is itself a command). | shared/shortcuts.ts:144-153, SH:89-99, SH:775-805 | - |
| B-NAV-154 | A page is `max(1, floor(viewport / lineExtent) - 1)` lines, half a page `max(1, floor(floor(viewport / lineExtent) / 2))`; at least one line fits (size 0 counts as one). | EN:218-225 | T-dec54fc2 |
| B-NAV-155 | A line is a Details row (28 px; 24 px compact), an Icons row (116 px; 94 px compact), or a Compact List column (292 + 18 = 310 px; 252 + 18 = 270 px compact) whose viewport width is `clientWidth - 20 + 18`. | NC:526-540, lib/detailsLayout.ts:21-23, IG:34-52, FL:9-26 | - |
| B-NAV-156 | The page move changes the index by `lines x itemsPerLine`, clamped to the first/last item (an icon keeps its column), and reports how many lines it actually moved. | EN:230-252 | T-bfae9359, T-d17ebdc9 |
| B-NAV-157 | The list scrolls by `movedLines x lineExtent` only if the destination item is not fully in view as the list is scrolled now; otherwise the list stays still. | NC:568-571, NC:437-465 | - |
| B-NAV-158 | With nothing selected a page key acts like Down (forward) or Up (back) of the arrow keys, gap-aware, and does not scroll by itself. | NC:553-563 | - |
| B-NAV-159 | A page key that cannot move (same index with a single item selected, empty list, no pane scroller) does not consume the key (default not prevented), so the native scroll can happen. | NC:565-567, SH:775-785 | - |

## 12. Keeping the selection in view

| ID | Behavior | Evidence | Test ids |
|---|---|---|---|
| B-NAV-160 | The lead item (or the item being renamed) is scrolled into view when it becomes the lead (click, arrows, reveal), when it first appears in the list, when another sort order is chosen, when a rename starts, and when a refused rename name asks again. | RI:20-31, RI:46-52 | T-bcd1990e |
| B-NAV-161 | When only the list changed around the lead (an item added elsewhere, sizes re-sorting, a date changed) the lead is brought into view only if it was in view at its old position and its index changed; otherwise the scroll is left alone. | RI:53-55 | T-51260c52 |
| B-NAV-162 | When only the layout changed (resize, rows per column), the lead is revealed unless the list was scrolled by more than 1 px since the last time; this lets a scroll restored by Back or a tab coming back win. | RI:56-59 | T-bcd1990e |
| B-NAV-163 | While the lead item is not in the list (index -1) nothing is revealed; it is revealed when it appears. | RI:48-50 | - |
| B-NAV-164 | Details view reveal: a row above the viewport scrolls so its top is at the top edge; a row below scrolls so its bottom is at the bottom edge; a row fully in view does not scroll. Row height 28 px (24 px compact). | CP:1639-1650, lib/detailsLayout.ts:22-23 | - |
| B-NAV-165 | Icons view reveal is by row: the first row reveals to scrollTop 0; the last row includes the bottom padding; a row taller than the viewport shows its top; a fully visible row does not scroll. | IG:62-89 | T-2c12de45, T-ac5c7f93, T-7baaab02, T-4ce6d4ac, T-a9405ac4, T-a1d93055 |
| B-NAV-166 | Compact List view reveal is horizontal: the column is `floor(index / rowsPerColumn)`; a column left of the viewport scrolls so its left edge shows, one beyond the right scrolls just enough to show its right edge, a visible column does not scroll, and the result is clamped to `0..maxScrollLeft`. | FL:38-68, CP:1236-1263 | T-99e7a81a, T-48e5acb1, T-53ebfc45, T-ac80a981, T-3e02a4a6 |
| B-NAV-167 | The List and Icons reveal waits until the pane has a measured size (height greater than 0, width greater than 0); before that an item would sit in a column of its own. | CP:1243-1248, components/IconGridView.tsx:296-302 | - |
| B-NAV-168 | All reveal checks use a 1 px tolerance. | RI:57-58, components/IconGridView.tsx:307-313 | - |

## 13. Typing in the file list (filter) and Quick Look space

| ID | Behavior | Evidence | Test ids |
|---|---|---|---|
| B-NAV-169 | A printable single character (not space, no ⌘/⌃/⌥) typed with the file list focused is added to the filter text; the list narrows to names that contain the text (case-insensitive, order kept) and selects the first name that starts with the text, otherwise the first match, otherwise nothing. | NC:585-608, LF:7-45, lib/typeahead.ts:7-9 | T-74e6332c, T-0d4539c1 |
| B-NAV-170 | Backspace removes the last typed character and leaves the selection where it is; Esc, or the clear button, clears the filter and keeps the selection so it can be seen among its neighbours. | NC:610-621, SH:807-827 | - |
| B-NAV-171 | Space is part of the filter text while a filter exists and the last filter input was less than 1000 ms ago (`LIST_FILTER_SPACE_WINDOW_MS`); after that Space is Quick Look. There is no timer that clears the filter. | NC:623-630, LF:1-6 | - |
| B-NAV-172 | The filter belongs to its list: it is dropped when the folder, or the kind of list (folder or a particular search), changes; a tab shown again brings back its own filter with its own list. | NC:636-662 | - |
| B-NAV-173 | If something outside the filter becomes the selection lead (a pasted, renamed or revealed item) while the filter is active, the filter is cleared so the item is visible. | NC:664-683, AC:803-808 | - |
| B-NAV-174 | With a filter narrowing the list to nothing, the list says "No items match “query”". The count reads "N items", or "M of N items" while some are hidden ("1 item"). | CP:546-549, LF:56-59 | T-f76d7a77 |

## 14. Startup and restoring the session

| ID | Behavior | Evidence | Test ids |
|---|---|---|---|
| B-NAV-175 | A folder the app was launched with (from Finder, a drop on the icon) always wins over the saved session: it is the start folder, with no favorite selected, and the tree root is Home when the folder is inside Home, otherwise the folder's volume root. | SN:40-47, SN:5-28 | T-d612583c, T-ae917c88 |
| B-NAV-176 | With "restore session" off, or with no saved last folder, a single view opens at Home with the tree rooted at Home and no favorite selected, regardless of any saved tree root. | SN:49-62 | T-d3b23be1 |
| B-NAV-177 | With "restore session" on, the start folder is the saved last visited folder. | SN:49-52 | T-5c8a8dd9 |
| B-NAV-178 | The restored tree root is the saved root when it is Home; or `/` when it is `/` and the start folder is on the startup volume; or a hand-picked root (not `/`) when the start folder is that root or inside it. Otherwise it is Home when the start folder is inside Home, else the start folder's volume root. | SN:5-28 | T-5c8a8dd9, T-d09ea64b, T-68eb3d87, T-b8580b99, T-b43fba42 |
| B-NAV-179 | Macintosh HD holds only its own folders: a saved root `/` with a start folder on another disk (/Volumes/X) becomes that disk's root. | SN:11-18 | T-d8fbdd46 |
| B-NAV-180 | The saved favorite selection is restored only when its path equals the start folder exactly. | SN:67-70, SN:108 | T-d0468635 |
| B-NAV-181 | With "restore session" on and saved tabs, every saved tab opens at its own folder with its own view mode, search view mode, sort, hidden-files, Folders First and sidebar section states; the active tab is `min(savedActiveIndex, lastIndex)`. | SN:150-170 | T-d8fbdd46, T-0a1f16d6 |
| B-NAV-182 | A saved tab without a path opens at Home with a Home-rooted tree. | SN:102-104 | T-0a1f16d6 |
| B-NAV-183 | When the window is given its tabs (`restoreTabs`, a window opened while the app runs or tabs merged or moved in) it opens them whatever the "restore session" setting says. | SN:150, SN:118-123 | T-bd036e34 |
| B-NAV-184 | Without saved tabs, or with restore off, one tab opens from the single-folder rules above with the global view settings. | SN:150-167 | T-25e74d78 |
| B-NAV-185 | A launch folder that is already a restored tab's folder activates that tab; otherwise it is appended as a new tab, made active, rooted by the launch rules (not the saved root). | SN:171-184 | T-ff6743f1 |
| B-NAV-186 | A saved favorite that has been removed since is opened as the plain folder; Favorites that were just set up on a first launch are shown open. | APP:1920-1927 | - |
| B-NAV-187 | The tab on screen is loaded first (tree initialised at its root, folder read in "replace" mode, favorite row selected when restored, with the tree's root children loaded first for a favorite); the other tabs are read only when they are first shown. | APP:1930-1995, TB:748-780 | T-116b9db2 |
| B-NAV-188 | A restored background tab whose folder properties lookup says "missing" is dropped from the tab strip (unless it was shown meanwhile, when it finds the nearest existing folder itself). | TB:781-805 | T-ba0fcc0a |
| B-NAV-189 | Tab commands (switching, closing, new tab) do nothing until the first folder has been read (preferences ready), while a dialog is open, or while another main view (Help, Settings) is shown. | TB:391-395 | T-981b1ce5, T-70f2c752 |
| B-NAV-190 | The session saved for the next launch holds the current folder, the selected Favorite (only when it equals the current folder), the tree root, the open tabs and the active index; search options are deliberately not saved. | APP:1724-1732, TB:1166-1183 | T-7b3e0b35 |
| B-NAV-191 | A restored tab, when shown, puts keyboard focus back into the pane that tab last had (tree or list); a fresh tab focuses the list. | TB:857-866 | T-2ddaf09f |

## 15. Tabs and navigation

| ID | Behavior | Evidence | Test ids |
|---|---|---|---|
| B-NAV-192 | Each tab keeps its own folder, selection and history; leaving a tab saves selection, scroll offsets (list, tree, sidebar sections), filter text, tree nodes and view memories, and showing it restores them. | TB:249-288, TB:808-832 | T-aa6d3211, T-064e9e51 |
| B-NAV-193 | Switching tabs stops answers still on their way: the view epoch is incremented, pending directory and Info requests are invalidated, and tree requests and in-flight metadata are forgotten; a tree saved while loading is settled so it never waits forever. | TB:292-299, ET:197-210 | T-0cd8f183, T-2404af85 |
| B-NAV-194 | A tab whose view was captured is re-read in place when it comes back (quietly; selection, search results and place in history kept), and its list and tree scroll are restored before the window paints. | TB:808-870, NC:1932-1953 | T-9bca212e |
| B-NAV-195 | A tab whose folder was removed meanwhile opens the nearest existing ancestor when it comes back (history entry replaced); one whose folder merely cannot be read stays on that folder showing the error. | TB:866-880, NC:1938-1946 | T-d5f7b879, T-e1ce4669 |
| B-NAV-196 | A folder renamed or moved by any window takes background tabs along: the tab's folder, every history entry, the tree root and the selected file-system tree row are rewritten (the deepest matching move wins); its cached listing is dropped when its folder moved. | ET:346-385, TB:905-935 | T-7f43e078, T-1fff82ea, T-7174190f |
| B-NAV-197 | An unmounted disk closes every tab showing it (including background tabs; they are not offered by Reopen Closed Tab) and closes the window when all tabs were on it; if tabs cannot change now (a dialog is open) the tab on screen goes Home by push and background tabs go Home with the disk's history entries removed and Home appended. | APP:1213-1237, TB:963-993, ET:321-343 | T-d1308c95, T-4d1a03d4, T-ec5e59a2, T-29bd3543, T-594eb68d |
| B-NAV-198 | A drag that springs a tab into folders and ends without a drop puts the tab back: the folder, history and sidebar selection return to where the drag began (the folder restored with its view). | APP:1303-1331, TB:996-1030 | - |
| B-NAV-199 | Tabs on folders with the same name are labelled with their parent folder ("name — parent") so they can be told apart; tabs on the same folder keep the same label. | ET:289-302 | T-84234a52 |

## 16. Visits counted for the Go To box

| ID | Behavior | Evidence | Test ids |
|---|---|---|---|
| B-NAV-200 | A folder picked in the Go To box counts as a visit of kind "goTo" immediately. | FVT:47-53 | T-e100b72c |
| B-NAV-201 | A folder opened any other way by "push" becomes pending and counts as a "stay" once it has stayed on screen 5000 ms (`FOLDER_STAY_MS`) or been used (a file opened, paste, a write started). | FVT:3-5, FVT:53, FVT:60-62 | T-5f1923af, T-7d304c05 |
| B-NAV-202 | Leaving a pending folder before that (another arrival, or a different folder shown by Back or another tab) counts it as "passThrough". | FVT:47-59 | T-0540857f |
| B-NAV-203 | Closing the window with a folder still pending counts it as "passThrough". | FVT:63-65, NC:991 | T-b692dcd0 |
| B-NAV-204 | Back, Forward, jumps and reloads never start a visit; each recorded visit is sent with `places:recordVisit` and a failure is ignored. | NC:1145-1149, NC:985-990 | - |

## 17. Info panel and Info row following navigation

| ID | Behavior | Evidence | Test ids |
|---|---|---|---|
| B-NAV-205 | The Info panel and Info row show the item at: the explicit target if one was set (from "Show Info"), else the selection lead, else the folder on screen. | NC:2312, APP:537-539 | - |
| B-NAV-206 | Any navigation clears an explicit Info target, except reloads that ask to keep it (outside-change reload). | NC:1101-1103, NC:1990 | - |
| B-NAV-207 | Properties are requested 80 ms after the target changes (`INFO_FETCH_DELAY_MS`), cancelling the earlier timer, so holding an arrow key does not ask for every item passed. | NC:2318-2344, NC:2415 | - |
| B-NAV-208 | The last 200 item properties are cached: moving back to an item shows its cached properties at once without a loading state, and they are asked for again in the background; a failed lookup removes the cached entry and clears the panel. | NC:2314-2318, NC:2328-2337, NC:2416-2426 | - |
| B-NAV-209 | Properties are fetched only while the Info panel or the Info row is open and a folder is on screen. | NC:2309-2311 | - |

## 18. Search mode versus folder mode

| ID | Behavior | Evidence | Test ids |
|---|---|---|---|
| B-NAV-210 | Search results are showing only when the committed query is non-empty and results are visible; arrows, paging and Return then act on the result rows, and the view mode is the separate search view mode. | NC:234-237, SH:884-895 | - |
| B-NAV-211 | Opening any folder (a navigation without keep-results) hides the results and clears the search field. | NC:915-924 | T-26fc62ad |
| B-NAV-212 | Leaving the search results does not remember a folder view (the results are not the folder). | NC:1016-1018 | - |
| B-NAV-213 | Esc in the file list while results show hides them and focuses the list. | SH:1599-1603 | - |
| B-NAV-214 | Folders do not spring open under a held drag over search results. | APP:1306 | - |
| B-NAV-215 | A folder reloaded for sort, Folders First or hidden changes leaves search results alone; sort and Folders First are unavailable in search. | NC:1759-1786, RCA:245-251 | T-26fc62ad, T-c05f1d45 |

## 19. Dialogs, text fields, write operations, window state

| ID | Behavior | Evidence | Test ids |
|---|---|---|---|
| B-NAV-216 | In the Help or Settings main view, explorer navigation commands (Back, Forward, Enclosing Folder, Home, Go places) are blocked. | SP:260-307 | T-494df166 |
| B-NAV-217 | While an alert (action notice) is open, Escape or Return dismiss it, Tab and unmodified keys are swallowed, and no navigation shortcut runs. | SH:1492-1507, SP:276-278 | T-c6b12327 |
| B-NAV-218 | While a text field has the keyboard (the inline rename field, the search field, the path bar's field, the Go to Folder box), unmodified navigation keys belong to the field and keyboard shortcuts of the window are ignored; keys that move a caret (⌘←, ⌘→, ⌘↑, ⌘⌫) stay with the field even when the menu sends the command. | SH:1511-1518, SH:1086-1100, shared/shortcuts.ts:846-860 | T-f573c5d9 |
| B-NAV-219 | ⌘[ and ⌘] are not caret keys, so Back and Forward still run from the menu even while a text field has the keyboard. | shared/shortcuts.ts:848-860, SH:1086-1100 | - |
| B-NAV-220 | Composing text with an input method (IME) is never treated as a navigation key. | SH:1479-1481 | - |
| B-NAV-221 | A running write operation does not block Back, Forward, Enclosing Folder or opening folders; it only holds back watcher reloads, and Refresh is not write-locked. | APP:1397-1408 | - |
| B-NAV-222 | Escape closes an open context menu before anything else; a context menu being open holds watcher reloads. | SH:1508-1511, APP:1400-1403 | - |
| B-NAV-223 | After a dialog or menu closes with no pane focused, focus returns to the pane last used (the list by default), unless a text field, the search field or a pending search pointer press has focus. | NC:2138-2173, lib/explorerPaneFocus.ts:3-27 | - |
| B-NAV-224 | Navigation never moves keyboard focus by itself; focus moves only in the cases listed (Reveal in Folder focuses the list, restored tabs refocus their pane, tree hiding moves to the list). | NC:1050-1224, AC:2765 | - |
| B-NAV-225 | Programmatic pane focus yields to a focus the person gives meanwhile (clicking an item) when it is a restore (`unlessFocusMoves`), and is repeated on a second frame to catch a pane rendered meanwhile. | NC:244-290, state/explorerStores.ts:152-181 | - |
| B-NAV-226 | While the window is inactive (blurred) the Back/Forward hold menu closes; no other navigation state changes with window focus. | HB:139-140 | - |

## Open questions

1. Back or Forward to a missing folder (section 2): the code leaves the old listing and sets `directoryError`, and `ContentState` renders the error if it is set even when entries exist. It is unclear whether the stale rows stay visible under or are replaced by "Couldn’t open this folder". Needs a run of the original to confirm.
2. `goBack` and `goForward` read `historyIndex` from the render that created them. Two presses inside one render (no render between) would both target the same entry. Not covered by a test.
3. Whether a sort change, Folders First toggle or hidden toggle really drops the selection: the code (`applyDirectorySnapshot` without `keepSelection`) clears it, but the comment in `useRevealIndex` says the selection is "kept in view when the list comes back sorted". May only describe search-result sorting. Verify in the built original.
4. Push does not de-duplicate (clicking the current folder adds an equal history entry). Looks unintended but is current behavior; confirm before porting as-is or listing as a deviation.
5. Whether the watcher is also held while an inline rename is being typed: the `useFolderWatch` comment says so, but `held` in `App.tsx:1397-1408` lists `explorerFocusSuppressed` and not the rename state. Confirm which flag covers it.
6. `⌘←`/`⌘→` are Back/Forward alternates yet are caret keys; with a text field focused the menu path ignores them but the raw path also returns early. Confirm in the original that ⌘[ with a rename field open leaves the rename (the rename dismissal on navigation was not traced).
7. Window inactive: no code outside the history menu reacts to blur, but whether Electron's focus change affects the folder watcher in the main process was not traced (main process is outside this area's files).
8. `Use as Tree Root` target resolution (`resolveRootTreeTargetPath`) was only read at the call site; its exact priority between the focused pane, last focused pane, context menu, selected folder and current path should be specified from `lib/` before porting.
9. Hold-menu `useKeepInViewport` rules (margins) were not read; the 6 px gap below the button is exact, the clamp distances are not.
