# Behavior rules: Info panel, Info Row, path bar, status bar, automatic folder sizes, size bars (B-INFO)

Improvements it belongs to: A8, A11.

What this area does better than Finder, in code terms:
- The Info panel and the Info Row never blank when you move: `resolveInfoItem` draws a preview from the file list at once (name, icon, kind, size, dates of listed items) and swaps in full properties when they arrive, with an 80 ms pause so held arrow keys ask for nothing, a 200-item properties cache and a refresh only when what is shown may have changed.
- One folder-size engine serves every view: a renderer cache that asks the main process about every folder a render shows, repaints at most every 100 ms, forgets exactly the sizes a write could have changed (including the Trash), and measures several folders as one run.
- The one folder selected in the home folder is sized automatically (500 ms after it stays selected, low priority, stopped when you move on), and a selection of many items is summed with Finder-style counts; sizes show in the Info panel, the Info Row, the path bar's status text, the Size column and as bars behind sizes.
- The path bar replaces Finder's status bar: item or selection count and size on the right, and every separator opens a menu of the sibling folders for sideways steps; middle segments collapse behind "…" by measured width.

Paths are relative to `apps/desktop/src/renderer` in `/Users/tcmudemirhan/src/tsproj/filetrail` (pinned `e4d0872`) unless they start with `main/` (then `apps/desktop/src/main/bootstrap/`). Test ids are from `docs/port/parity/tests.tsv`.

## 1. What the info views describe (target and preview)

| ID | Behavior | Evidence | Test ids |
|---|---|---|---|
| B-INFO-001 | The Info panel and Info Row describe one target path, chosen in this order: the explicit "Show Info" override, else the selection's lead path (the last item clicked or moved to), else the folder on screen. When no folder is open (current path is empty) there is no target and both show nothing. | App.tsx:537-539 | - |
| B-INFO-002 | With nothing selected the views describe the folder on screen: name is the last path component ("Macintosh HD" for "/"), kind "Folder", not hidden, not a link. | infoPreview.ts:47-56; InfoRow.tsx:47 | T-19c2787c |
| B-INFO-003 | For a listed target the preview carries the listing's name, extension, kind, hidden and link flags; its kind label is the metadata's kind label if the listing has loaded one, else the fallback label; created, modified, size and permissions come from list metadata when loaded, else null; size status is "deferred" when there is no metadata. The preview is marked pending. | infoPreview.ts:21-44 | T-f59e299b |
| B-INFO-004 | When the fetched properties belong to the target path, they replace the preview and the pending mark clears. Properties of any other path (the previously shown item) are ignored, so a stale item is never shown for the new target. | infoPreview.ts:18-20 | T-1a0ba4b2 |
| B-INFO-005 | A target that is neither in the shown entries nor the folder on screen (a tree folder not yet fetched, an item just removed) resolves to nothing: the panel shows its empty text (or nothing while loading), the Info Row falls back to the folder on screen. | infoPreview.ts:24-26 | T-c1ae5c70 |
| B-INFO-006 | In search mode the preview looks the target up in the search results, not the folder listing; the folder-listing metadata map is still the one read for preview fields. | App.tsx:545 | - |
| B-INFO-007 | The fallback kind label before the system's description is known: directory "Folder"; link to a folder "Alias Folder"; bundle "Application" when the extension is "app", else "Package"; link to a file "Alias"; any other file "<EXT> File" with the extension upper-cased, or just "File" with no extension. | infoPreview.ts:60-72 | T-714e79e7 |
| B-INFO-008 | Selecting anything (any content selection change) clears the explicit Show Info override, so the views follow the selection again. Navigating to another folder clears it too, unless the navigation asks to keep it. Switching tabs clears it and also blanks the shown properties and loading flag. | useExplorerActions.ts:1233; useExplorerNavigationController.ts:1102; useExplorerTabs.ts:350-352 | - |
| B-INFO-009 | "Show Info" on an item (context menu) opens the Info panel if it is closed, makes that path the override target even if the item is not selected, and fetches its properties at once with no 80 ms pause, showing the loading state until they arrive. | useExplorerActions.ts:2768-2793 | - |
| B-INFO-010 | "Show Info" from empty space in the list targets the folder on screen. From a sidebar folder or favorite it targets that folder. Show Info is not blocked while a file operation runs. | useExplorerActions.ts:2849-2850, 2903-2907, 2839 | - |
| B-INFO-011 | Properties of a target that fails to load clear the shown properties and log "Info Panel load failed"; the preview from the list (if any) stays on screen; no error text is shown. | useExplorerNavigationController.ts:2330-2337 | - |

## 2. Fetching, caching and refreshing item properties

| ID | Behavior | Evidence | Test ids |
|---|---|---|---|
| B-INFO-012 | Properties are fetched only while the Info panel or the Info Row is open and a folder is shown. With both closed nothing is requested. One fetch serves both views. | useExplorerNavigationController.ts:2308-2311 | - |
| B-INFO-013 | A fetch starts 80 ms after the target last changed (INFO_FETCH_DELAY_MS); a retarget inside that window cancels the timer, so holding an arrow key through a list requests nothing for the items passed. | useExplorerNavigationController.ts:2319-2344, 2415 | - |
| B-INFO-014 | Properties of up to 200 recently shown items are cached by path. Returning to a cached item shows its cached properties at once, with the loading flag off, and still asks again in the background in case it changed. | useExplorerNavigationController.ts:2304, 2314-2318, 2416 | - |
| B-INFO-015 | The properties cache is oldest-first: storing an item moves it to the newest place and the oldest entries beyond 200 are dropped. A failed fetch removes that path's cache entry. | useExplorerNavigationController.ts:2418-2427, 2331 | - |
| B-INFO-016 | A response for a request that is no longer the latest is cached but not shown; the loading flag clears only when the latest request ends. | useExplorerNavigationController.ts:2324-2341 | - |
| B-INFO-017 | Reloading the folder on screen (new sort, paste, refresh, change on disk) keeps the shown info on screen and asks for the properties again instead of blanking until the selection changes. | useExplorerNavigationController.ts:962 | T-321434ce |
| B-INFO-018 | After a change made outside the app, the properties are asked again only when what is shown may have changed: always when the changed-path list is unknown; otherwise, if the shown path is the folder itself, only when the listing changed (items came or went); if it is an item, only when the changed paths include it. A reload that changes nothing sends no request. | useExplorerNavigationController.ts:966-982 | T-cb87a875 |
| B-INFO-019 | While the properties are loading for a cached or listed item, the view shows the cached/preview data and the pending marks of the panel apply (see 3); nothing jumps position. | App.tsx:540-558 | T-08ec3aa8 |

## 3. Info panel shell (header, empty and loading states)

| ID | Behavior | Evidence | Test ids |
|---|---|---|---|
| B-INFO-020 | Header reads "Info" with a close button labelled "Hide Info Panel"; its tooltip is "Hide Info Panel" followed by the toggle's shortcut. Clicking it closes the panel (turns the preference off). | GetInfoPanel.tsx:143-159; App.tsx:2587 | T-209d6f52 |
| B-INFO-021 | While the first item loads (loading and no item) the panel body is empty: no "Loading…" text and no empty-state text. After 300 ms a small spinner (labelled "Loading info") appears in the header. | GetInfoPanel.tsx:118, 200; 678 | T-b2656378 |
| B-INFO-022 | With no item and not loading the body reads "Select a file or folder to show its info." and the spinner is gone. | GetInfoPanel.tsx:200-204 | T-b2656378 |
| B-INFO-023 | While the shown item is a pending preview, the header spinner also appears after 300 ms; it disappears when real properties arrive. A spinner is never shown for a wait shorter than 300 ms. | GetInfoPanel.tsx:118 | T-08ec3aa8 |
| B-INFO-024 | Values still on their way keep their rows with a muted dash "—" so nothing moves when they arrive: while pending, a null created date, null modified date, null permissions and a null file size show "—". | GetInfoPanel.tsx:376-379, 479-480, 515-519 | T-08ec3aa8 |
| B-INFO-025 | When properties are final (not pending) and a value is missing: dates read "Not available", permissions read "Unavailable", all muted. | GetInfoPanel.tsx:462-484; formatting.ts:3-10 | T-85c8fc6c |
| B-INFO-026 | The panel is draggable-width between 260 and 480 px (default 320) and slides in/out (see 14). Its content scrolls (overlay scroll); the Open With menu closes when it scrolls. | layoutTokens.ts:5-6; GetInfoPanel.tsx:522 | T-22636c8b |

## 4. Info panel content for one item

| ID | Behavior | Evidence | Test ids |
|---|---|---|---|
| B-INFO-027 | Hero block: the item's icon (loaded lazily), the name (full name as tooltip), and a subtitle "<Kind> · <size>"; the size part is omitted when no size is known yet. | GetInfoPanel.tsx:523-543 | T-209d6f52 |
| B-INFO-028 | Subtitle size part: for a volume root, "<free> available" when known; for a folder or package, the calculated size only once ready (bytes only, no detail); for a pending item with no size, nothing; otherwise the formatted size. Example "Markdown document · 2.0 KB". | GetInfoPanel.tsx:503-513 | T-b9e1ffc4 |
| B-INFO-029 | Information rows appear in this order: Kind, Opens with (files only, see 6), Size (or Capacity, Available, Used for a volume root), Created, Modified, Permissions, Where. The last row has no divider. | GetInfoPanel.tsx:408-502 | T-209d6f52 |
| B-INFO-030 | Kind shows the item's kind label as given. Created and Modified use the locale's medium date with short time (for example "Mar 2, 2026 at 10:30 AM"). | GetInfoPanel.tsx:410-469; formatting.ts:11-14 | T-209d6f52 |
| B-INFO-031 | Permissions shows the owner's access in words ("Read & Write", "Read only", "Write only", "No access", from the owner r and w bits) and beside it the three-digit octal code; the code's tooltip is the nine-letter string (mode 644 gives "644" with tooltip "rw-r--r--"). Only the low nine permission bits count. | GetInfoPanel.tsx:471-483, 711-725; formatting.ts:117-138 | T-4e902491, T-209d6f52 |
| B-INFO-032 | A file's Size row shows the formatted size; status "deferred" reads "Not yet available", "unavailable" or null reads "Unavailable". | formatting.ts:81-92; GetInfoPanel.tsx:380 | T-209d6f52 |
| B-INFO-033 | Size formatting counts in steps of 1,000 (1 KB is 1,000 bytes, matching Finder): below 1,000 it is "<n> B"; otherwise KB, MB, GB, TB, PB with one decimal below 9.95 and none from 9.95 up ("9.9 KB" but "10 KB"); a value that would round to 1000 steps up to the next unit ("999.7 KB" shows as "1.0 MB"). | formatting.ts:93-106 | T-513524fc |
| B-INFO-034 | The Where row shows the containing folder's name as a link-like button (tooltip: the full path); "/" is labelled "Macintosh HD". Clicking navigates to that folder (replace when it is the folder on screen, else push). A root with no parent shows "—" muted. | GetInfoPanel.tsx:487-501, 727-738; App.tsx:2589-2591 | T-209d6f52 |
| B-INFO-035 | Links to folders and links to files are shown with the file-style Size row (the link's own size), not the folder-size cell. | GetInfoPanel.tsx:359; explorerAppUtils.ts:589 | T-beb94f48, T-cb2d45b7 |

## 5. Folder size cell (Info panel and Info Row)

| ID | Behavior | Evidence | Test ids |
|---|---|---|---|
| B-INFO-036 | Only real folders ("directory") and packages ("bundle", such as .app) get folder-size controls. Links to folders and links to files do not: they are sized as the link itself. | explorerAppUtils.ts:589-591 | T-42401906, T-beb94f48, T-cb2d45b7 |
| B-INFO-037 | Unknown size (idle): the Info panel shows a button "Calculate" in a muted value; the Info Row shows a button "Calculate size". Packages show this too, never "Not yet available". | GetInfoPanel.tsx:797-801, 372; InfoRow.tsx:221-225 | T-066643da, T-ef42cbb6, T-467d3b3d, T-fff4ef4a |
| B-INFO-038 | Pressing Calculate starts a calculation for exactly that folder, not forced (a size the main process already knows is returned at once). | App.tsx:2651-2653, 2554-2559 | T-77dc3eda, T-71aaa15e |
| B-INFO-039 | While calculating, nothing is drawn for the first 300 ms (a small folder never flashes a spinner); after 300 ms a spinner and a stop button appear (tooltip "Stop Calculating", label "Cancel folder size calculation"). The spinner goes away at once when calculation ends. | GetInfoPanel.tsx:740, 753, 782-796; InfoRow.tsx:164, 177, 206-218 | T-17491c5e, T-74492d44 |
| B-INFO-040 | The stop button cancels the calculation (the folder returns to unknown, with the sizes of folders inside already measured kept). | GetInfoPanel.tsx:789-793; App.tsx:2657-2658 | T-ae767f86 |
| B-INFO-041 | Ready, in the Info panel: first line "<size>", plus " (<disk> on disk)" only when the on-disk string differs from the size string; second line what it holds at any depth: "N files, M folders", singular "1 file"/"1 folder", numbers with thousands separators, parts with zero omitted, "Empty" when both are zero. | GetInfoPanel.tsx:754-769; formatting.ts:231-255 | T-513524fc |
| B-INFO-042 | Ready, in the Info Row: one line "<size> (<disk> on disk) · <files, folders>" and the whole line is also the fact's tooltip. | InfoRow.tsx:107-110, 154-158, 185-189 | T-1161c790 |
| B-INFO-043 | A refresh button next to a ready size (tooltip "Calculate Size Again", label "Recalculate folder size") forces a fresh calculation. | GetInfoPanel.tsx:770-778; App.tsx:2654-2656 | T-513524fc, T-1161c790 |
| B-INFO-044 | A failed calculation (error status) is shown like unknown: the Calculate button again (muted in the panel); the error message is not displayed. | GetInfoPanel.tsx:372, 797-801 | - |
| B-INFO-045 | A folder or package whose handlers are not provided (no folder-size wiring) shows "--" muted in the panel and no size in the Info Row. | GetInfoPanel.tsx:373-375; InfoRow.tsx:91 | - |
| B-INFO-046 | The size shown for a folder is the one in the shared cache for that exact path; the same size appears in the list's Size column, the status text and size bars without a second walk. | App.tsx:2648-2650; useFolderSizeCache.ts:540-555 | - |

## 6. Volume roots, selections and quick actions in the Info panel

| ID | Behavior | Evidence | Test ids |
|---|---|---|---|
| B-INFO-047 | When the item is a volume root ("/" or a disk at /Volumes/<name>) the Size row is replaced by Capacity, Available and Used rows; any other folder (even /Volumes/<name>/Photos) keeps its Size row. | GetInfoPanel.tsx:386, 393-407; volumes.ts:5-13 | T-b9e1ffc4 |
| B-INFO-048 | Until the volume numbers arrive each of the three rows shows "—" muted. Used is total minus available, never below 0. | GetInfoPanel.tsx:387-407 | T-b9e1ffc4 |
| B-INFO-049 | The volume's total and free bytes are requested when the panel is open and the target is a volume root, asked again each time the panel comes to it; the answer is used only if it is for the item shown; a failed request leaves the placeholders. | App.tsx:1785-1811, 2583-2585 | T-b9e1ffc4 |
| B-INFO-050 | With two or more items selected the panel shows a summary instead of the lead item: no Open button, no quick actions. One item selected shows that item as usual. | GetInfoPanel.tsx:160-168; App.tsx:672-675 | T-0033a16b |
| B-INFO-051 | The summary's name is "<count> items" (with thousands separators) and its subtitle "<n folders> and <m files>" with each part left out when zero ("1 folder and 2 files", "4 files"); when the total size is known the subtitle ends " · <size>" ("2 files · 4.0 KB"). | GetInfoPanel.tsx:209-251 | T-0033a16b |
| B-INFO-052 | In the summary only real folders ("directory") count as folders; packages and links count as files. Counting uses the entries shown (a narrowed list counts only visible matches). | App.tsx:679-689 | - |
| B-INFO-053 | The summary's icon is a stack icon for folders only, files only or mixed. | GetInfoPanel.tsx:236-244 | T-0033a16b |
| B-INFO-054 | The summary has a Size row (the folder-size cell with Calculate / spinner / totals when folders are among the items, else the total or "--") and a Where row: the one folder they are all in as a button, or "Several folders" muted when they are in different folders. | GetInfoPanel.tsx:253-290; App.tsx:690-695 | T-0033a16b |
| B-INFO-055 | Quick action buttons are icon-only with tooltips "<label> (<shortcut>)". Quick Look, Edit, Copy Name, Add/Remove Favorites and Use as Tree Root appear only when their handler is given; Copy Path, Open in Terminal and Show in Finder always appear. | GetInfoPanel.tsx:602-669, 681-708 | T-0287f845 |
| B-INFO-056 | Edit shows only for files and links to files, labelled "Edit in <text editor name>". Favorites shows only for folders (and links to folders) other than the Trash, labelled "Add to Favorites" or "Remove from Favorites". Use as Tree Root shows for folders and links to folders. | App.tsx:2235-2244; GetInfoPanel.tsx:612-668 | T-0287f845, T-8a7d2ddb |
| B-INFO-057 | Copy Path copies the path quoted for a shell when it contains spaces; Copy Name copies the name. The pressed button reads "Copied" with a check for 1.5 s; the other copy button is unchanged. On failure the label is unchanged and a notice "Couldn’t Copy the Path" / "Couldn’t Copy the Name" appears. | useExplorerActions.ts:2630-2656; GetInfoPanel.tsx:121-139 | T-ef662069, T-bbf9d4a3, T-0287f845 |
| B-INFO-058 | Quick Look, Open in Terminal, Show in Finder and Open act on the shown item's path (not on the selection). | App.tsx:2589-2614 | T-209d6f52 |

## 7. Open, Open With and "Opens with" in the Info panel

| ID | Behavior | Evidence | Test ids |
|---|---|---|---|
| B-INFO-059 | The primary button says "Open in <app>" with the app's icon for a file or link to a file whose default app is known; for folders, packages and unknown apps it says "Open". | GetInfoPanel.tsx:357-358, 548-558 | T-68714b91 |
| B-INFO-060 | When Open With items exist and a handler is given, a chevron button "Open With" is joined to Open as a split button; its menu lists the same apps as the right-click menu. | GetInfoPanel.tsx:550, 559-582 | T-68714b91 |
| B-INFO-061 | While Option is held with the menu open, the menu swaps to the "Always Open With" list under that heading; choosing sends the action with always set. | GetInfoPanel.tsx:563-565; PullDownMenu.tsx:48-50, 153-155 | T-8727f2e5 |
| B-INFO-062 | The Open With menu is worked by keyboard: ↓ from nothing active goes to the first item, ↑ to the last, both wrap; Home and End; a letter goes to the next item starting with it, wrapping; Return or Space chooses the active item (nothing when none is active); Option+Return or Option+Space also chooses; Escape closes. Keys with Command or Control are ignored. | PullDownMenu.tsx:90-137 | T-c7172562 |
| B-INFO-063 | The menu closes on a press outside, when the window loses focus, when anything other than the menu scrolls, on Escape, and after choosing. The item under the pointer is highlighted, and leaving the menu clears the highlight. | PullDownMenu.tsx:59-80, 150 | T-1a141f6f, T-22636c8b, T-bb498532 |
| B-INFO-064 | Files get an "Opens with" row showing the default app's icon and name (or "None") with a chevron; its label reads "Opens with <app>: change the app for every <kind>". Choosing an app changes the default for every file of that kind (always set); choosing the app it already opens in does nothing; "Other…" is passed as kind other. | GetInfoPanel.tsx:417-457 | T-43f23ca5 |
| B-INFO-065 | Until macOS answers, the Opens with row exists with "—" muted and no button, so the rows below do not move. The lookup starts 80 ms after the item changes and is treated as ready after 250 ms more even without an answer. The row is absent for kinds that cannot change app, and for folders. | GetInfoPanel.tsx:417-418; App.tsx:2202-2206, 2234; useOpenWithLookup.ts:83, 111-115 | T-3ae2ee91, T-55a72312, T-68714b91 |

## 8. Info Row (one line under the list)

| ID | Behavior | Evidence | Test ids |
|---|---|---|---|
| B-INFO-066 | The Info Row is always in the tree; closed it has max-height 0 and opacity 0 and opens to 30 px with a transition. It sits under the list and above the path bar. The preference defaults to closed; the Info panel also defaults to closed. | styles.css:3269-3281; ContentPane.tsx:675-677; appPreferences.ts:414-415 | T-419c42ea, T-f1212345 |
| B-INFO-067 | The toolbar buttons "Info Panel" and "Info Row" are toggle buttons (pressed state mirrors the preference); View menu items of the same names are checked when on. | ExplorerWorkspace.tsx:1448-1475, 1028-1043 | T-419c42ea, T-f1212345 |
| B-INFO-068 | It describes the selected item, or the folder on screen when nothing is selected. With no folder open and nothing selected it is an empty element. | InfoRow.tsx:47-51; App.tsx:2259-2260 | - |
| B-INFO-069 | One item: an icon, the name (ellipsis, full name as tooltip), then facts separated by a centred dot with no labels: kind, size, "Modified <relative date>". Permissions are never shown. | InfoRow.tsx:112-125 | T-3b2397f6, T-0773b3fe |
| B-INFO-070 | Facts come from list metadata for the selected path first, so the bar updates in the same frame as the selection; else from fetched properties only if their path matches; never from the previous item's properties. | InfoRow.tsx:86-88 | T-4e4c9d29 |
| B-INFO-071 | Unknown facts are left out, not drawn as dashes: no size fact until a file's size status is "ready"; no Modified fact until the date is known. | InfoRow.tsx:94-105, 132-138 | T-908f1796, T-3b2397f6 |
| B-INFO-072 | The kind fact uses the metadata or properties kind label, else the fallback label; its tooltip is the same text. | InfoRow.tsx:90, 122 | T-4e4c9d29 |
| B-INFO-073 | For a folder or package the size fact is the folder-size control (Calculate size, spinner, ready line with refresh); a ready size's tooltip is "<size> (<disk> on disk) · <items>". | InfoRow.tsx:91-110, 154-158 | T-467d3b3d, T-1161c790, T-a9d4fb5b |
| B-INFO-074 | The "Modified" fact reads like a list date ("Modified Today, 9:12 AM", "Modified 24 min ago") with the full date to the second as tooltip; see 9 for the date wording. | InfoRow.tsx:132-138 | T-4e4c9d29 |
| B-INFO-075 | With two or more items selected the row reads "<count> items" with no kind and no date; the single fact is the folder-size control when the selection holds folders, else the summed size when known, else nothing. | InfoRow.tsx:53-79 | T-9fa8ca8a, T-49205480 |
| B-INFO-076 | For a selection with folders, the row offers Calculate size (all selected folders, skipping ones already known or being calculated), the spinner and stop (stops the whole run), and when every size is known the totals "5.0 MB · 12 files, 2 folders" with refresh (recalculates all). | InfoRow.tsx:55-71; App.tsx:2248-2258 | T-49205480 |
| B-INFO-077 | In a narrow pane the facts shrink and are cut with an ellipsis well before the name is. | styles.css:3309-3324 | - |
| B-INFO-078 | In search mode the row describes the selected search result; the metadata for it comes only from the folder listing's metadata map, so a result outside the folder falls back to fetched properties. | App.tsx:2543, 2546 | - |

## 9. Dates in the Info Row and lists

| ID | Behavior | Evidence | Test ids |
|---|---|---|---|
| B-INFO-079 | A date under one minute old reads "Just now"; under one hour "<n> min ago" (whole minutes, floored). | formatting.ts:48-54 | - |
| B-INFO-080 | Older than an hour but today: "Today, <time>"; yesterday: "Yesterday, <time>"; within the six days before today: "<Weekday>, <time>"; earlier this year: "<Mon D>, <time>"; earlier years: "<Mon D, YYYY>" without time. Days are calendar days, not 24-hour steps. | formatting.ts:55-73 | - |
| B-INFO-081 | A date more than one minute in the future is shown in full (medium date, short time) rather than "Just now"; up to one minute ahead still reads as now. | formatting.ts:20, 45-47 | - |
| B-INFO-082 | The tooltip is the full date with seconds (full date style, medium time). A date that cannot be parsed or is missing produces no Modified fact. | formatting.ts:31, 77-79; useRelativeDate.ts:19-27 | - |
| B-INFO-083 | Relative dates are measured from the current minute; a once-a-minute timer runs only while a date under an hour old is on screen and the window is visible, plus a timer at midnight for the rest ("Today" becomes "Yesterday"). Returning to the window (focus or visibility change) re-reads every date. | relativeClock.ts:1-91 | - |

## 10. Summing a selection (shared by Info Row, Info panel and status text)

| ID | Behavior | Evidence | Test ids |
|---|---|---|---|
| B-INFO-084 | The total of several selected items is known only when the size of every one is: files from the list's metadata (size status "ready"), folders and packages from the folder-size cache (status "ready"). Until then the total is null. | selectionSize.ts:21-69; App.tsx:619-640 | T-91b90458, T-90b9b5d3 |
| B-INFO-085 | The sizes of selected files must be known before a total is shown even if all selected folders are known; a folder total is not shown on its own. | selectionSize.ts:69 | T-90b9b5d3 |
| B-INFO-086 | For a selection with folders the summed control is: "calculating" while any selected folder is calculating; otherwise unknown (Calculate offered) while any folder is not ready; otherwise ready with the total, once every file size is known. | selectionSize.ts:70-86 | T-36d01adb, T-b1bc11e9, T-2bd1264c |
| B-INFO-087 | The ready totals count what Finder counts for a selection: files = selected files plus all files inside the folders; folders = selected folders plus all folders inside. Size on disk is shown only when the selection is folders alone (files have no size on disk in the list). | selectionSize.ts:47-48, 76-84 | T-2bd1264c |
| B-INFO-088 | A selection of files only has no folder-size control; its total is the plain sum. Links to folders count as the link itself, not the folder they point to. | selectionSize.ts:32-43 | T-91b90458, T-beb94f48 |
| B-INFO-089 | For selections of two or more, the metadata of the selected files is requested in any view (not in search mode), prioritised ahead of visible rows, so the total can be summed even in views that show no sizes. Folders are not asked. | useExplorerNavigationController.ts:2175-2191 | T-22541b51 |
| B-INFO-090 | A selection of one item is never summed; the single-item path is used. | App.tsx:620-622, 673-675 | - |
| B-INFO-091 | The Info Row and Info panel sum the entries shown (a narrowed list counts only visible matches); the status text sums the full list's selected entries. | App.tsx:623-625, 652-653 | - |

## 11. Path bar status text (right side of the path bar)

| ID | Behavior | Evidence | Test ids |
|---|---|---|---|
| B-INFO-092 | The path bar's right side shows a one-line summary, replacing Finder's separate status bar; it is hidden while the path editor is open and when the summary is empty. It is announced politely to screen readers. | ContentPane.tsx:850-854 | T-fb71ed4a |
| B-INFO-093 | Nothing selected: "<n> item(s)" ("1 item", "0 items"). With a typed list filter narrowing the list: "<shown> of <total> items". | statusSummary.ts:36-58; listFilter.ts:52-55 | T-4ef3ba98, T-381332af |
| B-INFO-094 | Something selected: "<k> of <n> selected" where n is the folder's full item count (not narrowed by typing). | statusSummary.ts:49-51 | T-87bcada4 |
| B-INFO-095 | A size part is appended after " · " when known: with nothing selected, the folder on screen's size; with a selection, its total. Free space is not in this text (it is in the Info panel for a volume root). | statusSummary.ts:52-57 | T-e0ca8e31, T-87bcada4 |
| B-INFO-096 | While a size is being calculated the part reads "Calculating…" (with the ellipsis character); the part is omitted when the size is neither known nor being calculated. | statusSummary.ts:26-31 | T-2757fa9d |
| B-INFO-097 | The selection's status size is its total once every size is known; "calculating" while any selected folder is; otherwise no size. | statusSummary.ts:12-17 | T-053962d8, T-21d8abac, T-ce0169b8 |
| B-INFO-098 | The folder on screen's status size: its size when ready, "calculating" while it is, nothing when idle or failed. | statusSummary.ts:19-24 | T-e563b4a1 |
| B-INFO-099 | With nothing selected in search mode, or no folder open, there is no status size. | App.tsx:646-650 | - |
| B-INFO-100 | In search mode the text is "<n> result(s)" ("1 result"), "<shown> of <total> results" when narrowed by the filter, prefixed "Searching… " while the search runs; with a selection it adds " · <k> selected" and, if known, " · <size>". With nothing selected there is no size part. | searchResults.ts:72-97; App.tsx:2471-2478 | T-88a11cc8, T-56a22bbc |
| B-INFO-101 | The status size is recomputed whenever any cached folder size changes; so Calculate Size from a menu, the shortcut or the Info panel shows its progress here as it comes in. | App.tsx:644-670 | T-f9b3fe24, T-e3c9959a |

## 12. Path bar segments, collapsing and editing

| ID | Behavior | Evidence | Test ids |
|---|---|---|---|
| B-INFO-102 | The path bar lists a segment per folder from the top of the disk: "Macintosh HD" for "/"; a folder on another disk (/Volumes/<name>/...) starts at that disk's name, not at Macintosh HD › Volumes. The last segment is the active one. | ContentPane.tsx:869-894 | T-e082ec7b |
| B-INFO-103 | With no folder open the bar shows one disabled segment "No folder selected"; clicking it does nothing, double-clicking it opens the path editor. | ContentPane.tsx:870-872, 803-807 | T-9616b132, T-af56cfdc |
| B-INFO-104 | In search mode the bar shows the single selected result's path; with zero or several selected it shows the search root. | App.tsx:2511-2514 | - |
| B-INFO-105 | Four or fewer segments are always shown in full. With more, if the row is too narrow (width minus an 8 px margin, each segment measured with real styles plus 20 px per separator), middle segments collapse into a "…" button, keeping the first segment and as many tail segments as fit; if none fits with the first segment, the first is dropped and as many tail segments as fit are kept; at least the last segment is always shown. | ContentPane.tsx:937-981, 108-110 | T-18fe33a6 |
| B-INFO-106 | The "…" button is labelled and titled "Show <n> More Folder(s)" ("Show 1 More Folder"). Clicking it expands the whole path and scrolls the bar to its end. | ContentPane.tsx:838-844, 2418-2420, 445-465 | T-18fe33a6, T-a38008df |
| B-INFO-107 | The expanded path folds back when the pointer moves anywhere outside the path bar (a mouse move, not only a click), when a press lands outside, when a segment is chosen, or when the folder changes. Moving within the bar, or into a separator's folder menu, keeps it open. | ContentPane.tsx:403-443, 380 | T-a38008df |
| B-INFO-108 | A long folder name is cut at the standard width so it cannot crowd the rest; room still left in the row is handed back to those names from the current folder backwards, so a name is cut only when there is no space beside it. | ContentPane.tsx:905-935 | - |
| B-INFO-109 | A single click on a segment navigates to that folder after 320 ms (so a double-click can be told apart); the click folds an expanded bar. Command-click opens that folder in a new tab immediately, with no delay. | ContentPane.tsx:804-820, 112 | T-f657b6b8 |
| B-INFO-110 | A double-click on a segment or on the bar's empty space cancels the pending navigation, folds the bar and opens the path editor; a double-click on a separator button does not. | ContentPane.tsx:769-772, 821-830 | T-73dec6db, T-45026165, T-9616b132 |
| B-INFO-111 | A segment's tooltip is its full path. Clicking anywhere in the path bar gives the keyboard focus to the content pane. | ContentPane.tsx:831, 483-486 | T-01ad97ab |
| B-INFO-112 | The path editor opens with the current path, the caret at its end, and focus in the field. Opening it does not change the folder. | ContentPane.tsx:383-392 | T-73dec6db |
| B-INFO-113 | In the editor Return goes to the highlighted suggestion if one is highlighted, otherwise to the trimmed text; an empty text does nothing; after submitting the editor closes and suggestions clear. | ContentPane.tsx:682-697 | T-c3292381, T-5f7427b6 |
| B-INFO-114 | Escape in the editor first clears suggestions or a preview, and only if there are none restores the current path and closes the editor. Leaving the field by blur also restores the current path and closes it, except when focus moves into the suggestion list. | ContentPane.tsx:706-717, 720-729 | T-73dec6db |
| B-INFO-115 | In the editor ↓ and ↑ preview the next or previous suggestion (wrapping; ↓ from none starts at the first, ↑ at the last), showing it in the field with a trailing "/" and the part beyond the typed text selected; Tab moves focus to the first suggestion (Shift+Tab the last). | ContentPane.tsx:730-749; usePathSuggestions.ts:93-109, 135-145 | T-6d2af5d3, T-f80edb39 |
| B-INFO-116 | Suggestions are requested 350 ms after typing stops, are replaced only by the answer to the latest text, and clear the highlight when a refreshed list arrives. Choosing a suggestion fills it with a trailing "/" and asks for the suggestions inside it. | usePathSuggestions.ts:9, 43-76, 147-157 | T-2459714a, T-76b1e8da |
| B-INFO-117 | In the suggestion list ↓/↑ move focus with wrap, Escape clears them and returns to the field, Tab returns to the field; hovering previews. | PathSuggestionDropdown.tsx:36-66 | T-f80edb39 |
| B-INFO-118 | The editor is also closed, with the draft reset, whenever the folder on screen changes. While the field is being typed in, the content pane gives up the keyboard and takes it back afterward. | ContentPane.tsx:370-381 | T-9497e5dc |
| B-INFO-119 | The bar's row is drawn in the focused style when the content pane has focus, and in the normal style when the window or pane is inactive. | ContentPane.tsx:679 | - |

## 13. Path bar folder menus (separator buttons)

| ID | Behavior | Evidence | Test ids |
|---|---|---|---|
| B-INFO-120 | Each separator before a segment is a button "Folders in <parent name>" (tooltip the same). A path of three levels below the top has one per level ("Folders in Macintosh HD", "Folders in Users", "Folders in demo"). A folder on another disk has none for the disk itself. Without a loader the separators are plain "›". | ContentPane.tsx:781-797, 861-867; PathbarFolderMenu.tsx:210-223 | T-b514ec81, T-e082ec7b |
| B-INFO-121 | Pressing the separator asks for the subfolders of the folder to its left (hidden folders follow the Hidden Files setting) and opens a menu above it (the bar is at the window's foot): left edge 6 px left of the button, bottom 6 px above it. Pressing again closes. | PathbarFolderMenu.tsx:61-86; App.tsx:2429-2430 | T-3c985219, T-b514ec81 |
| B-INFO-122 | The menu opens already filled when the folders arrive at once; when they are slow, a "Loading…" line appears only after 300 ms. A request that was closed or superseded is discarded. | PathbarFolderMenu.tsx:18, 49-54, 72-85 | - |
| B-INFO-123 | The folder the path goes through is ticked (radio item with a check) and is the active row to begin with, scrolled to the middle of the menu; if it is not in the list, the first row is active. | PathbarFolderMenu.tsx:108-119, 253-273 | T-3c985219 |
| B-INFO-124 | Choosing a folder navigates to it and closes the menu and folds an expanded bar; choosing the ticked one only closes the menu and navigates nowhere. | PathbarFolderMenu.tsx:100-106; ContentPane.tsx:789-792 | T-487ad066 |
| B-INFO-125 | While the menu is open the keyboard belongs to it and the keys are taken before the file list sees them: ↓/↑ move one row (stopping at the ends, no wrap), Home/End jump to the ends, Return or Space chooses the active row, a letter jumps to the next folder starting with it after the active row and wraps to the first, Escape or Tab closes. Keyboard focus never leaves the file list. | PathbarFolderMenu.tsx:148-195 | T-d2b67f2e |
| B-INFO-126 | Any key with Command, Control or Option held closes the menu and is not taken. The pointer highlights the row under it (mouse move), and a click on a row chooses it without moving focus. | PathbarFolderMenu.tsx:151-154, 265-268 | - |
| B-INFO-127 | The menu closes on a press outside it and its button, on window resize, on window blur, and when the path or the active segment changes. | PathbarFolderMenu.tsx:88-93, 134-206 | T-c7c36ac9 |
| B-INFO-128 | An empty folder shows "No Folders"; a folder that cannot be read shows "Can’t Read This Folder" (typographic apostrophe). | PathbarFolderMenu.tsx:242-245 | T-2fb99a85 |
| B-INFO-129 | More than 300 subfolders: only 300 rows are shown, centred on the ticked folder (clamped to the list ends), with notes "<n> more folders above" and "<m> more folders below" (singular "1 more folder"). | PathbarFolderMenu.tsx:14, 290-314, 248-252, 275-279 | T-ca1e9d7a |
| B-INFO-130 | The menu is kept inside the viewport. Row tooltips are the folder's full path. | PathbarFolderMenu.tsx:54, 264 | - |

## 14. Folder size cache (renderer)

| ID | Behavior | Evidence | Test ids |
|---|---|---|---|
| B-INFO-131 | Reading the size of a path not in the cache returns "idle" and queues a question to the main process; all folders a render asks about go out in one request (sent after the render), in batches of at most 5,000. | useFolderSizeCache.ts:540-555, 195-209, 31, 139-148 | T-000906ee, T-8e6d096f |
| B-INFO-132 | A folder the main process did not know is not asked about again for 5 s (cooldown); re-renders inside it send nothing; after 5 s a render asks again. | useFolderSizeCache.ts:26, 546-551 | T-aa614e35 |
| B-INFO-133 | Answers store sizes without disturbing a folder that is being calculated, and only repaint when a size actually changed. A failed question changes nothing. | useFolderSizeCache.ts:139-193 | T-fea150dc |
| B-INFO-134 | Calculate: the entry becomes "calculating" at once; a size the main process already holds goes straight to ready without polling; otherwise the folder is polled every 200 ms until ready, error or cancelled. | useFolderSizeCache.ts:22, 314-374, 250-310 | T-4c6145e3, T-222fa570 |
| B-INFO-135 | An automatic calculation is sent flagged automatic so the main process runs it at lower priority. | useFolderSizeCache.ts:322-326 | T-f0c677aa |
| B-INFO-136 | Recalculate is the same call with recalculate set, which makes the main process forget the folder's size first. | useFolderSizeCache.ts:376-379 | T-804d4f23 |
| B-INFO-137 | Stop: polling stops, the main process is told to cancel the job, the entry returns to "idle" and the sizes of folders inside that were already measured stay shown. If Stop comes before the start answered, the calculation is cancelled as soon as its job id arrives and never shows as calculating again. | useFolderSizeCache.ts:409-432, 333-341 | T-6b8ebfe3, T-4b779145, T-f2aa08d1 |
| B-INFO-138 | Errors: a failed start shows error "Failed to start folder size calculation"; a failed poll shows "Failed to poll folder size status"; a job error shows its message or "Unknown error"; polling stops in each case. | useFolderSizeCache.ts:281, 296, 366-369 | T-38597fb0, T-bd964763 |
| B-INFO-139 | A second calculation of the same folder replaces the first (the first's late answers are ignored); a calculation started meanwhile is not touched by an earlier answer arriving. | useFolderSizeCache.ts:318-330, 265-267 | T-34d48522, T-5dc1f552 |
| B-INFO-140 | While a walk runs, folders inside it get their sizes as the main process measures them: each poll that reports more measured folders asks again about folders inside the walked one that had no size; the finished parent asks again about all folders inside it, known or not; a stopped or failed walk asks about those without a size. | useFolderSizeCache.ts:213-235, 276-290 | T-514fe05b, T-019b4291, T-aed4e67f |
| B-INFO-141 | The window repaints for size changes at most once per 100 ms; changes inside the interval are merged into one repaint at its end; the first change repaints at once. A listing of 1,000 folders being measured asks and repaints only as sizes come in, not per poll. | useFolderSizeCache.ts:34, 51-66 | T-dd1cef4e, T-26babe7d, T-237da02a |
| B-INFO-142 | The cache keeps at most 5,000 entries; over it the oldest tenth (down to 4,500) go at once, never a calculation under way; evicted paths are asked about again if shown. The list of folders the main process did not know is capped the same way. | useFolderSizeCache.ts:29, 588-608 | T-9dae3f9b, T-1131eecd, T-f2f23029 |
| B-INFO-143 | The cache is per window: other windows' walks do not repaint this one. One measurement is under way per app at a time (see 16); `isCalculating` is true while any entry in this window is calculating. | useFolderSizeCache.ts:559-566 | T-61d57efd, T-237da02a |
| B-INFO-144 | Unmounting stops all polling timers and the pending repaint. | useFolderSizeCache.ts:92-104 | T-6bdc9fd8 |
| B-INFO-145 | A measurement that ended before the window began waiting for it (the app's "settled" message came first) is looked at as soon as the wait begins, remembering the last 64 such ids; a message for a job being waited for makes the window look at once instead of at the next 200 ms poll. | useFolderSizeCache.ts:73-75, 305-307, 498-516 | T-4789e94f, T-4340cba9 |
| B-INFO-146 | A known size the main process has not finished reporting is polled instead of trusted. | useFolderSizeCache.ts:342-356 | T-344ce934 |

## 15. Folder sizes and writes

| ID | Behavior | Evidence | Test ids |
|---|---|---|---|
| B-INFO-147 | When a file operation ends (a terminal status with a result), the sizes of folders it may have changed are handled: folders holding a changed item are asked about again and kept shown meanwhile; what changed and what is inside it is forgotten without asking. Folders being calculated are untouched. | useFolderSizeCache.ts:450-494 | T-6dae4083, T-e72bbb5f |
| B-INFO-148 | Folders the main process no longer knows after such a question are forgotten; folders it answers are updated only if different. | useFolderSizeCache.ts:167-189 | T-92b27980, T-fea150dc |
| B-INFO-149 | A move to the Trash, Undo and Redo also ask again about the home folder's ".Trash" and the folders holding it; other operations (such as Replace) do not treat the Trash as changed on their own. The home Trash path is the home path without trailing slashes plus "/.Trash". | useFolderSizeCache.ts:489-491, 584-586 | T-78dcb4c4, T-5c5478a3 |
| B-INFO-150 | An item dragged out to another app or the Dock's Trash from another window makes this window forget the sizes of what held it (and the Trash's, if it went to the Trash). | useFolderSizeCache.ts:519-525 | T-52a59b70 |
| B-INFO-151 | When the Trash is emptied, from this window or another, the Trash's size and what holds it are asked again and what was in it is forgotten. | useFolderSizeCache.ts:529-536 | T-0124f0b4 |
| B-INFO-152 | The main process takes removed items off its stored sizes where it can and forgets the rest; a measurement running when a write touches what it walks is stopped and run again under the same job, and a size stored during the write for a folder holding a removed item is forgotten. | main/responseCache.ts:241-269, 315-326, 407-450 | - |
| B-INFO-153 | Calculate Size and Show Info stay available while a file operation runs (they are not in the write-locked list). | useExplorerActions.ts:147-156; rendererCommandAvailability.ts:21-31 | - |

## 16. Several folders and the main process

| ID | Behavior | Evidence | Test ids |
|---|---|---|---|
| B-INFO-154 | Calculating several folders measures them one after another, in the order given, skipping folders already ready or calculating (unless recalculating). The next starts as soon as the previous ends, not at the next poll. | useFolderSizeCache.ts:385-407 | T-ecfd5430, T-4789e94f |
| B-INFO-155 | A folder stopped part way (Stop, or another calculation started meanwhile) ends the run; Stop on the selection cancels the run and the folder being measured. | useFolderSizeCache.ts:401-403, 435-445 | T-18ca7451 |
| B-INFO-156 | The main process measures one folder at a time. A window's new request stops that window's own running one (and replaces its queued one) and runs first; another window's running measurement is not stopped, the new one waits in the queue. | main/responseCache.ts:554-583 | - |
| B-INFO-157 | A known size is answered at once from the main process's store without a walk; probing never starts a job. All sizes measured by a walk (every folder inside) are stored, with no time limit, until a write or Recalculate forgets them. | main/responseCache.ts:514-530, 589-606; main/folderSizeCache.ts:1-8 | T-c59e8970 |
| B-INFO-158 | When a window closes or reloads, its running and queued measurements stop; on quit nothing more is measured. | main/responseCache.ts:637-668 | - |
| B-INFO-159 | Finished jobs are pruned beyond 256. | main/responseCache.ts:18, 182-198 | - |

## 17. Calculating from commands and menus

| ID | Behavior | Evidence | Test ids |
|---|---|---|---|
| B-INFO-160 | The Calculate Size command (shortcut, menu bar, toolbar) acts on: the focused tree item when the tree has focus; else the selected folders and packages in view order (files ignored); else, with nothing selected, the folder on screen; in search mode with nothing selected and with no folder open there is nothing to calculate and the command is unavailable. | rendererCommandAvailability.ts:118-128, 235-236 | T-650e6f58 |
| B-INFO-161 | With exactly one target the command forces a fresh calculation (recalculate) of it; with several it runs them one after another, skipping ones already known. | useExplorerShortcuts.ts:1356-1363; App.tsx:1018-1019 | T-650e6f58, T-df07c21f |
| B-INFO-162 | The context menu shows "Calculate Size" only if at least one target is a folder or package; hidden for files alone. With several targets, only the folder-like ones are measured. | useExplorerActions.ts:631-636, 2910-2919 | T-c2c3e724, T-df07c21f |
| B-INFO-163 | Calculate Size from the background menu measures the folder on screen. | useExplorerActions.ts:2851-2853 | T-e3c9959a |
| B-INFO-164 | Calculate Size on a sidebar folder or favorite also opens the Info panel for it, but only if the size would otherwise show nowhere: not when it is the folder on screen (the status text shows it) and not when it is a row in the Details view with a Size column. | useExplorerActions.ts:2925-2938 | T-9cb4c249, T-147baa0e, T-fc474670 |
| B-INFO-165 | For a folder in the list, the size appears in the status text even in views without a Size column (the status text's size part follows the selection). | App.tsx:644-670 | T-f9b3fe24 |
| B-INFO-166 | The Info panel/Info Row Calculate button runs a non-forced calculation for one folder; the refresh icon is forced; for a multi-selection both run over the selected folders. | App.tsx:2248-2258, 2554-2574 | T-49205480 |

## 18. Automatic folder sizes

| ID | Behavior | Evidence | Test ids |
|---|---|---|---|
| B-INFO-167 | Automatic measuring applies only when all hold: the setting "Calculate folder sizes automatically" is on (default on), the Info panel is open, the main view is the explorer, no Show Info override is active, exactly one item is selected, that item is a folder or package (not a link) inside the home folder (path starts with "<home>/"). | useAutoFolderSize.ts:14-29; App.tsx:717-729 | T-df387abe, T-b8e9d9c4 |
| B-INFO-168 | Not measured automatically: the home folder itself, anything outside home (/Applications, /Volumes/...), a path that merely shares the home prefix ("/Users/demonstration/x"), nothing selected, several selected, files, links to folders, or an unknown home path. The folder on screen is not measured automatically either. | useAutoFolderSize.ts:21-28 | T-b8e9d9c4 |
| B-INFO-169 | The folder must stay the same selection for 500 ms (AUTO_FOLDER_SIZE_DELAY_MS) before it is measured; folders passed in less time are never measured. | useAutoFolderSize.ts:9, 62-78 | T-351a9dd4, T-0d2d52b8 |
| B-INFO-170 | Skipped when the size is already known, the last attempt failed, the folder is being measured, or any other folder is being measured (a new calculation would stop it). | useAutoFolderSize.ts:63-66 | T-71d4c4fb |
| B-INFO-171 | The calculation is requested automatic (low priority, not forced). When the selected folder changes or goes (another selection, Info panel closed, setting turned off), a calculation this hook started and that is still running is stopped; one started by Calculate Size on the same folder is left running; sizes measured inside are kept. | useAutoFolderSize.ts:67-85 | T-0d2d52b8, T-e316ae44, T-71d4c4fb |
| B-INFO-172 | If the selection changed before the start answered, the calculation is stopped as soon as its job id is known. | useAutoFolderSize.ts:67-76 | - |
| B-INFO-173 | The Settings switch "Calculate folder sizes automatically" (description "In the Info panel, when you select a folder in your home folder.") turns this off with one toggle; it takes effect in open windows. | SettingsView.tsx:1506-1513; App.tsx:1876 | T-9b1e3197 |
| B-INFO-174 | The folder that auto-measures shows the same spinner (after 300 ms), then the ready line, as a manual Calculate. | useAutoFolderSize.ts:67; GetInfoPanel.tsx:753 | - |

## 19. Size bars and the Size column

| ID | Behavior | Evidence | Test ids |
|---|---|---|---|
| B-INFO-175 | Bars appear behind sizes only while the list is sorted by size, only in the Details view's Size column, and never in search results. | App.tsx:513-516, 2485; ContentPane.tsx:1924-1926, 1966 | T-87c303a0 |
| B-INFO-176 | A bar's width is the item's size as a share of the largest size among the folder's entries (all entries, not only visible ones), clamped to 0..100 %. | App.tsx:524-528; ContentPane.tsx:2135-2144 | T-87c303a0 |
| B-INFO-177 | Sizes for bars: a file uses the listing's size; a folder or package uses its calculated size once ready; unknown sizes (uncalculated folders, files with no size) have no bar. | App.tsx:517-523 | T-87c303a0 |
| B-INFO-178 | Zero bytes draws no bar; a tiny size draws a sliver (width a share like 0.1 % with a 2 px minimum); the bar is anchored right and capped at the cell width plus 4 px; if every size is 0 or unknown there are no bars. | ContentPane.tsx:2193-2199; styles.css:2917-2926; App.tsx:528 | T-87c303a0 |
| B-INFO-179 | Bars are decoration only: they ignore the pointer, are hidden from assistive tech, and turn lighter-on-accent for the selected focused row. | ContentPane.tsx:2196-2198; styles.css:2917-2948 | - |
| B-INFO-180 | The Size column shows "--" (secondary colour) for a folder or package until its size is calculated; then the folder's size ("Calculating…" while calculating); files show their size, blank while their metadata loads. | ContentPane.tsx:2287-2302, 2202-2209; App.tsx:2530-2536 | T-c6d101c9 |
| B-INFO-181 | While sorted by size the list is re-sorted as folder sizes arrive: folders and packages sort by calculated size like files, items without a known size stay at the end in both directions, ties break by name (numeric, case-insensitive); with Folders First on, folders and links to folders come first. | explorerAppUtils.ts:593-636; App.tsx:495-507 | T-bb1a779b |
| B-INFO-182 | Calculating a folder's size (for example by selecting the folder one level up with the Info panel open) sizes every folder inside it, so the bars and sort order fill in without further action. | App.tsx:508-511; useFolderSizeCache.ts:213-235 | T-514fe05b, T-019b4291 |

## 20. Panel layout (Info panel slide and widths)

| ID | Behavior | Evidence | Test ids |
|---|---|---|---|
| B-INFO-183 | Opening the Info panel adds a column (8 px resizer plus the panel width) at the right of the workspace; the content pane's width changes in one step and the panel slides in over 220 ms while icon view moves items to their new places. | ExplorerWorkspace.tsx:340-362, 1795-1799; paneLayoutChange.ts:5 | T-5c92ae3b, T-b690c3e9 |
| B-INFO-184 | Closing keeps the panel on screen, out of reach (inert), laid over the content's right edge for 220 ms while it slides out, with the content already at full width; then it is removed. The resizer is gone at once. | ExplorerWorkspace.tsx:1866-1875 | T-6932d3fd |
| B-INFO-185 | A panel that is open when the window is restored does not slide; the workspace shows a blank loading body until preferences are ready and the saved pane widths are applied. | ExplorerWorkspace.tsx:330-352 | T-5d509651 |
| B-INFO-186 | Items in icon view move only for the panel opening or closing, not for any other width change. | - | T-e76bca54 |
| B-INFO-187 | The Info panel's width is dragged from its resizer: dragging left widens it; the width is limited to 260 to 480 px and to the room left after reserving 420 px for the content and 8 px per resizer. During a drag text selection is disabled and a resize cursor shows. | useExplorerPaneLayout.ts:12-121, 221-232; layoutTokens.ts:3-9 | T-21dbb5e8 |
| B-INFO-188 | When the window narrows, the side panes shrink to keep 420 px for the content (the panel to at least 260 px, the tree to at least 220 px) and come back to the width chosen when the window is widened again; the saved width is the chosen one, not the squeezed one. | useExplorerPaneLayout.ts:124-174 | T-44cf0a5a, T-3d2da726, T-f539501b |
| B-INFO-189 | The resizer separators are keyboard-focusable: Left and Right arrows nudge the width by 12 px, Shift by 24 px (the tree grows with Right, the Info panel with Left); within limits; the nudged width is kept as the chosen one. | useExplorerNavigationController.ts:2072-2086; useExplorerPaneLayout.ts:186-207; ExplorerWorkspace.tsx:1816-1821, 1849-1854 | T-ee035de5 |
| B-INFO-190 | With the Info panel closed the panel width is not applied to the layout, and a hidden tree keeps its grid column at width 0. | useExplorerPaneLayout.ts:163-165; ExplorerWorkspace.tsx:1795 | T-880733c9 |

## 21. Bottom stack (cards and notifications above the bars)

| ID | Behavior | Evidence | Test ids |
|---|---|---|---|
| B-INFO-191 | A running operation's progress card rests 10 px above the top of the visible path bar row or Info Row (whichever is higher), measured when it appears and on window resize; with neither it rests 12 px from the bottom. | bottomStack.ts:6-28; CopyPasteProgressCard.tsx:26 | - |
| B-INFO-192 | Notifications rest above the bars and above the progress card when it is shown (card height plus 8 px); measured when a new notification arrives, when the card appears or goes, and on resize. With a 28 px path bar and a 30 px Info Row the bottom offset is 68 px. | bottomStack.ts:31-35; ToastViewport.tsx:40-43 | T-2709df93, T-a1bd6809 |
| B-INFO-193 | Only an Info Row that is open (`.info-row.open`) counts, and only bars with a visible box. | bottomStack.ts:11-22 | - |

## 22. Cross-cutting edge cases

| ID | Behavior | Evidence | Test ids |
|---|---|---|---|
| B-INFO-194 | Empty folder: nothing selected; status text "0 items"; the Info views describe the folder on screen; its size appears in the status text only after it is calculated; the Info panel's Size cell offers Calculate. | statusSummary.ts:36-58; infoPreview.ts:19-23 | T-4ef3ba98 |
| B-INFO-195 | Folder deleted or unreadable while shown: the Info views still resolve the folder on screen from its path (preview), properties fail quietly and the preview stays; the path bar still shows the path; the separator menu shows "Can’t Read This Folder" for an unreadable parent. | infoPreview.ts:23; useExplorerNavigationController.ts:2330-2337; PathbarFolderMenu.tsx:80-83 | T-2fb99a85 |
| B-INFO-196 | Permission error: the Permissions row shows the code when known, "Unavailable" when not (or "—" while pending); a folder size that errors shows Calculate again. | GetInfoPanel.tsx:471-484, 372 | T-85c8fc6c |
| B-INFO-197 | Window inactive: Info and path bar content does not change; the path bar row loses the focused style; open pull-down and separator menus close on window blur; the minute timer for relative dates pauses while the window is hidden and dates are re-read on return. | ContentPane.tsx:679; PullDownMenu.tsx:73; PathbarFolderMenu.tsx:199; relativeClock.ts:59-76 | - |
| B-INFO-198 | Several windows: each window has its own cache, panel state and automatic measuring; the main process queues measurements across windows (a window never stops another's). Folder-size knowledge from other windows arrives through probes and writes events. | useFolderSizeCache.ts:41-46; main/responseCache.ts:554-583 | T-237da02a |
| B-INFO-199 | Tabs: the folder-size cache is shared across tabs of the window; each tab switch resets the Show Info override and the shown properties and the Info views re-resolve for the tab's folder. | useExplorerTabs.ts:350-352 | - |
| B-INFO-200 | The Info Row and Info panel preferences and the panel width persist with the window preferences (the width saved is the chosen one). | App.tsx:1706-1723, 1879-1880 | - |
| B-INFO-201 | A typed list filter narrows the list and the status text ("<shown> of <total> items") but the selection count still counts against the full list, and the Info panel summary counts only visible selected entries. | App.tsx:561-567, 2480-2483, 679 | T-381332af |

## Open questions

1. Spinner after a failed properties fetch: when the fetch fails but a list preview exists, `pending` stays true and `loading` clears, so GetInfoPanel's `showSpinner = pending || (loading && !item)` keeps the header spinner showing after 300 ms indefinitely. It is unclear whether this is intended; the port should copy it (Same behavior first) unless the orchestrator decides otherwise.
2. Info panel summary counts only `kind === "directory"` as folders (packages and links count as files) while the Finder-style totals in `summarizeSelectionSize` count all folder-size-eligible kinds as folders. Likely an inconsistency, kept as is.
3. The Info Row and Info panel sum the filtered list, while the status text sums the unfiltered list (App.tsx:623-625 vs 652-653). With a typed filter active and hidden selected items the two totals can differ.
4. The InfoRow's `metadata` prop reads the folder listing's `metadataByPath` even in search mode, where search results have their own metadata map (`searchMetadataByPath`, used only for selection sums). A search result in the folder on screen may show listing metadata; others wait for fetched properties. Confirm whether the Swift port should copy this.
5. The Calculate Size shortcut/menu with one target forces a recalculation (`recalculateFolderSize`) while the Info panel Calculate button does not. Confirm the port keeps both.
6. Size bars use the largest size among all entries, including files whose size is "deferred" (no size in the listing): they count as 0 and draw no bar. Not tested.
7. `copyPathDisabled` is never set by the app, so Copy Path/Copy Name are never disabled in the Info panel.
8. Dialog or rename field open: the info code has no special handling (no rule found); the Info views simply keep following selection and cache changes.
9. Dates use the system locale via Intl; exact wording of the medium date in Created/Modified depends on locale (not fixed in code).
