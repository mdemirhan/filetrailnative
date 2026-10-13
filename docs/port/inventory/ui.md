# File Trail (Electron/React) UI inventory, for a native Swift/AppKit port

I read the whole renderer and its shared modules and changed nothing. Citations use `file:line`.

**Path prefixes:**
- **R/** = `/Users/tcmudemirhan/src/tsproj/filetrail/apps/desktop/src/renderer/`
- **S/** = `/Users/tcmudemirhan/src/tsproj/filetrail/apps/desktop/src/shared/`
- **M/** = `/Users/tcmudemirhan/src/tsproj/filetrail/apps/desktop/src/main/` (only used for window sizes and the menu bar)

---

## 0. Architecture facts that drive the port

- **One bundle, several windows.** `R/main.tsx:27-38` picks the page from the URL hash:
  - no hash: explorer window (gets class `vibrant-window`)
  - `#settings[/tab]`: Settings
  - `#about`: About
  - `#acknowledgements`: Acknowledgements
  - `#help[/topic]`: Help
- **Startup installs** (`R/main.tsx:17-19`):
  - app-drawn tooltips
  - overlay scrollbars that show only while scrolling
  - window-activity tracking: `body.window-inactive` turns every selection gray while the window is in the background (`R/lib/windowActivity.ts`)
- **Explorer window chrome** (`M/main.ts:400-426`):
  - `titleBarStyle: hiddenInset`, traffic lights at (14, 16)
  - `vibrancy: "sidebar"`, `visualEffectState: followWindow`, transparent background
  - min 760×480; default 1200×760 (`M/appStateStore.ts:99-100`)
- **Zoom** scales the whole page (web zoom), 75–150% (`S/appPreferences.ts:133-134`):
  - ⌘+ / ⌘− step by 10 (`R/hooks/useExplorerShortcuts.ts:1230-1240`); ⌘0 resets to 100
  - Settings offers 75, 80, 90 … 150 (`R/components/SettingsView.tsx:1062-1068`)
  - **Native port:** needs one global scale factor applied to every font and metric. Fonts are never resized separately: "Text is scaled with the zoom level" (`R/styles.css:86-88`).
- **Menu bar** lives in `M/appMenu.ts:190-390`:
  - **File Trail:** About, Settings…, Empty Trash…, Services, Hide, Hide Others, Show All, Quit
  - **File:** New Window/Tab/Folder; Open; Open in New Tab/Window; Edit in <Editor>; Quick Look; Reveal in Folder; Calculate Size; Rename; Duplicate; Move to…; Add/Remove Favorites; Open in Terminal; Show in Finder; Move to Trash; Eject; Reopen Closed Tab; Close Tab; Close Window
  - **Edit:** Undo/Redo (dynamic labels); Cut/Copy/Paste; Copy Path; Select All; Show Clipboard; Clear Clipboard; Find Files…; Show Last Search Results
  - **View:**
    - as Icons / as List / as Compact List (radio)
    - Sort By ▸ Name, Kind, Date Modified, Size (radio)
    - Folders First; Hidden Files; Refresh
    - Hide/Show Folder Tree; Info Panel; Info Row
    - Customize Toolbar…
    - Zoom In / Zoom Out / Actual Size
    - full screen
  - **Go:** Back, Forward, Enclosing Folder; Documents, Desktop, Downloads, Home, Library, Macintosh HD, Applications, Trash; Go to Folder…; Use as Tree Root
  - **Window:** Minimize, Zoom, Show Previous/Next Tab, Move Tab to New Window, Merge All Windows, Bring All to Front
  - **Help:** File Trail Help, Keyboard Shortcuts
- **Menu state** from the renderer (`S/applicationMenuState.ts:6-19`): disabled commands, view mode, sortBy, foldersFirst, hiddenFilesShown, folderTreeOpen, infoPanelOpen, infoRowOpen, favoriteIsSet, textEditing.
- **Window title** is the front tab's label, or "File Trail" (`R/App.tsx:1149-1154`).

---

## 1. Window layout

### 1.1 Grid (`R/components/ExplorerWorkspace.tsx:1787-1879`)
- **Columns:** `[tree W][8px resizer][content 1fr]` plus, when the Info panel is open, `[8px resizer][inspector W]`.
- **Hidden tree:** columns go to 0 px rather than being removed.
- **Rows:** toolbar (auto), tab strip (auto, zero height with one tab), panes (1fr).
- **Sidebar spans all rows** (Finder-style full-height sidebar under the traffic lights).
  - Toolbar sits at `gridColumn 3 / -1` (`:1662`): over the content and inspector only.
  - With the tree hidden, the toolbar gets `padding-left: 76px` to clear the traffic lights (`R/styles.css:353-355`).
- **Layout constants** (`R/lib/layoutTokens.ts:3-19`):

| Constant | Value |
|---|---|
| treeMin / treeMax | 220 / 520 |
| inspectorMin / inspectorMax | 260 / 480 |
| resizerWidth | 8 |
| keyboard step / with ⇧ | 12 / 24 |
| minContentWidth | 420 |
| tree row height | 26 (compact 21) |

- **Default widths:** tree 280, inspector 320 (`S/appPreferences.ts:433-434`).
- **Resizer behaviour** (`R/hooks/useExplorerPaneLayout.ts`):
  - Drag with a global pointer and the `col-resize` cursor.
  - Both side panes share `viewport − 420 − resizers` (`:211-221`).
  - The saved width is the one the user chose; a narrow window shows the pane squeezed and restores it when the window widens.
  - Keyboard: ←/→ on a focused resizer; the tree grows to the right, the inspector to the left (`R/hooks/useExplorerNavigationController.ts:2072-2086`).
  - Visual: 1 px hairline centred in the 8 px gutter (`R/styles.css:4548-4553`); hover colour `--ft-accent-border`.
- **Info panel animation:** slides in/out over 220 ms with `cubic-bezier(.2,0,0,1)`. Icon-view items animate to their new places over the same time (FLIP) (`R/components/ExplorerWorkspace.tsx:336-362`; `R/components/IconGridView.tsx:236-272`; `R/styles.css:3850-3884`).
- **Readiness:** the workspace is blank until preferences and pane widths are restored (`:329-334`).
- **Translucent sidebar:**
  - Sidebar and tab strip are `color-mix(sidebar-bg 62%, transparent)` over the vibrancy (`R/styles.css:8118-8186`).
  - Everything else is opaque `--bg-base`.
  - The toolbar's bottom line and the path-bar line extend into the half of the divider past the hairline.

### 1.2 Toolbar
**Items** (`S/toolbarItems.ts:109-394`):
- **Navigation:** back, forward, up ("Enclosing Folder"), refresh, `topSeparator` ("Space", may repeat)
- **Composites:** view (3-segment), sort (menu), title (required), clipboard (required), viewOptions (required), search (required)
- **Navigation/view buttons:** goToFolder, foldersFirst, hidden, folderTree, infoPanel, infoRow, newTab
- **Selection actions:** openSelection, quickLook, editSelection ("Edit in Text Editor"), moveSelection, renameSelection, duplicateSelection, newFolder, trashSelection, copySelection, cutSelection, pasteSelection
- **Other:** openInTerminal, showInFinder, revealInFolder, calculateSize, copyPath, theme (menu), settings, help ("File Trail Help")

**Default order** (`:408-420`): folderTree, Space, back, forward, title, clipboard, view, sort, search, viewOptions, infoPanel.

**Required items** (`:466-473`): title, clipboard, search, viewOptions. They are appended if missing.

**Customize palette order** (`:478-512`), the rest of the add/insert/move/remove helpers are at `:516-567`.

**Layout constants** (`R/lib/topToolbarLayout.ts:12-23`; CSS `R/styles.css:358-376`):

| Constant | Value |
|---|---|
| itemGap | 2 |
| edgedItemInset | 5 |
| capsulePadding | 3 |
| titleMinWidth | 96 |
| overflow button | 32 |
| search width / min | 200 / 110 |
| control height | 32 |
| button width | 32 |

- Toolbar min-height 52, padding `0 12 0 8`, background `--bg-base`, bottom border `--border` (`R/styles.css:3937-3944`).

**Capsules** (macOS 26 look; `R/lib/topToolbarLayout.ts:33-66`; `R/styles.css:393-449`):
- Adjacent buttons share a round capsule filled with `--toolbar-toggle-bg`.
- title, search, view and Space are not on capsules; a Space ends one capsule and starts the next.
- Hover fill `--bg-hover`; "on" fill is `text-primary` at 16% (hover 21%) (`R/styles.css:6340-6360`).
- Icons 17 px, stroke 1.7.

**Title block** (`R/styles.css:3949-3975`):
- Flexes to take the free room, min 96, padding `0 4 0 8`.
- 15 px semibold, ellipsis; tooltip is the full path.
- Text: "Searching “X”" in search mode (`R/App.tsx:2777-2781`).
- It is a window-drag region.

**View switch:** segmented control, 4 px track, 32×24 segments, the selected one raised (`R/styles.css:6361-6395`). Tooltips "View as Icons/List/Compact List (⌘1/2/3)". Disabled in search mode (`ExplorerWorkspace.tsx:1193-1234`).

**Sort button:** sort icon opens a 200 px-wide menu (`ExplorerWorkspace.tsx:1235-1318`):
- Name / Kind / Date Modified / Size (radio)
- separator
- Ascending / Descending (radio)
- Tooltip "Sort By: Name, Ascending".

**Search field** (`ExplorerWorkspace.tsx:1319-1400`; `R/styles.css:903-972`, 6396-6413):
- Round capsule (`--search-surface`); 1 px accent border plus focus ring while active.
- Magnifier with a small chevron is the Search Options menu button.
- Placeholder "Search"; clear (×) button once text is typed.
- **Return:** runs the search.
- **↓:** moves into the results.
- **Esc:** ends search mode, or drops a draft if nothing was searched.
- The field keeps the same width focused or not (`R/styles.css:964-972`).

**View Options (⋯) menu** (`ExplorerWorkspace.tsx:1008-1052`), each item with its current shortcut:
- Folders First, Hidden Files
- separator
- Info Panel, Info Row
- separator
- Customize Toolbar…

**Overflow »:**
- Width calculation is in `topToolbarLayout.ts:131-176`. Removable items drop from the right; title and search shrink first.
- » menu groups (`ExplorerWorkspace.tsx:1509-1580`, `R/components/ToolbarOverflowButton.tsx`):
  - toggles as checkable items
  - view as "as Icons…" etc.
  - sort as "Sort by …"
  - theme options
  - others by their menu label

**Toolbar right-click** (empty area or title): one-item menu "Customize Toolbar…" (`ExplorerWorkspace.tsx:950-1006`).

**Customize Toolbar** is an in-place, Finder-like editor (`ExplorerWorkspace.tsx:521-950`, `R/components/ToolbarCustomizePanel.tsx`, `R/styles.css:456-780`):
- **Window state:** the rest of the window is inert under a scrim (`--scrim` at 35%).
- **Handles:** one over each item.
  - Drag threshold 4 px; an item dropped more than 28 px below the toolbar is still "over" it.
  - Reorder slide 180 ms; flash of an added item 900 ms.
  - Spaces show as 10×22 dashed slots.
  - Items without room are drawn faint.
- **Panel:**
  - Width `min(760, 100%−32)`, hangs 8 px below the toolbar, radius 14.
  - Title "Drag items into the toolbar".
  - Note: "Drag an item out of the toolbar to remove it. Click an item to add it at the far right."
  - Grid of 32 px chips with labels.
  - A red dashed overlay shows while a drop would remove an item.
  - Footer: "Restore Defaults" and "Done" (default button).
- **Keys:** ←/→ move between handles, ⌥←/⌥→ move the item, Delete/⌫ removes it (`:909-948`), Esc/Done finishes.
- **Native port:** `NSToolbar`'s own customization sheet looks different; matching this needs a custom editor.

### 1.3 Tab strip (custom; not native window tabs)
`R/components/TabStrip.tsx`, `R/styles.css:3987-4124`
- Shown only with 2 or more tabs (`R/App.tsx:2757`).
- **Band:** height 29, `--sidebar-bg` (translucent), inset bottom line, `margin-left: −4` so it starts at the tree hairline.
- **Tab:** width 180 (min 96), padding `0 28 0 12`, 1 px right divider, 13 px secondary text.
  - Active tab: `--bg-base` with a **2 px accent line on top** and primary text.
  - Hover: `--bg-hover`.
- **Close button:** 16×16 at right 7, visible on hover or on the active tab; tooltip "Close Tab (⌘W)".
- **Search tab:** a 12 px magnifier before the label, accent-coloured while searching.
- **"+" button:** 34 px wide; tooltip "New Tab (⌘T)".
- **Interaction:**
  - Middle-click closes a tab.
  - Dragging reorders (6 px threshold).
  - The active tab is scrolled into view.
  - A file drag hovering a tab for 700 ms switches to it; the drop-target style is accent soft background plus a 1.5 px inset ring.
- **Context menu:** Close Tab, Close Other Tabs, Duplicate Tab, separator, Move Tab to New Window, Merge All Windows (disabled unless more than one window) (`TabStrip.tsx:271-296`).
- **Labels** (`R/lib/explorerTabs.ts:140-172, 360-379`):
  - Folder name; `/` shows as "Macintosh HD".
  - Search tab: `“query” in Folder`.
  - Duplicate names get a suffix: `Name — Parent`.
  - "Favorites" when no folder is shown.
  - Tooltip is the path, or "Searching <path>".

### 1.4 Sidebar (`R/components/TreePane.tsx`, `R/lib/favorites.ts`)
- **Top:** 52 px drag strip (`.sidebar-titlebar`) for the traffic lights (`R/styles.css:3893-3896`).
- **Layout A, "separate"** (`TreePane.tsx:608-726`):
  - Scrollable sections area (max 60% height) holding **Favorites** and **Locations** headers with flat rows.
  - Below it a "Folders" label (`.sidebar-header`, 11 px semibold secondary, padding `14 12 4 20`).
  - Then the folder tree, with a 6 px top fade mask (`R/styles.css:6580-6593`).
- **Layout B, "integrated" (default):** a single tree with collapsible root rows:
  - Favorites root: star icon, label 11 px semibold secondary.
  - Locations root.
  - Then the filesystem root (`R/lib/favorites.ts:300-425`).
- **Section header** (`R/styles.css:6631-6676`):
  - Height 24, margin `8 10 0`, radius 6.
  - Chevron (12 px) appears on hover; rotated 90° when open.
  - Tooltip "Hide/Show Favorites".
- **Locations** (`R/lib/favorites.ts:23-54`): Home (account name, home icon), Macintosh HD (drive), Trash, then mounted volumes (drive, or server for network). Ejectable volumes have an eject button 20×20 (icon 14) at the row end (`TreePane.tsx:1262-1282`).
- **Default favorites:** /Applications, ~/Desktop, ~/Documents, ~/Downloads (`favorites.ts:109-120`).
- **Favorite icons:** 23 ids listed in `S/appPreferences.ts:243-267`.
  - Icon is inferred from the folder name (`favorites.ts:122-163`).
  - Favorite icons are drawn in the **accent colour** (`R/styles.css:3103-3108`).
- **Tree rows** (native layer, `R/styles.css:6464-6530`):

| Property | Regular | Compact |
|---|---|---|
| height | 26 | 21 |
| label | 14 px regular | 12 px |
| icon | 16 | 14 |
| chevron | 14 | 12 |
| indent per level | 14 | 11 |

  - Row margin `0 10`, radius 6.
  - Left padding `8 + depth × indent` (`TreePane.tsx:1159`).
  - Active row label semibold.
  - Selection colours:
    - focused: `--ft-accent-selection-bg` with white text
    - unfocused pane: `--bg-active-inactive`
  - While a context menu is open for a row: 2 px accent inset ring (`R/styles.css:2448-2450`).
  - Symlink badge "Alias".
  - Loading line "Loading folder…" after 400 ms; error line in danger colour.
- **Disclosure:** chevron button rotated 90° when expanded (120 ms transition); hidden (opacity 0) when there are no children.
  - Tooltips: "Expand Folder" / "Collapse Folder" / "No subfolders".
- **Click** (`TreePane.tsx:973-1060`):
  - Single click navigates after a 180 ms delay (expands too if "single-click expand" is on).
  - Double-click expands and navigates.
  - ⌘-click on a non-current folder opens a new tab; ⌘-click on the current row clears the selection.
  - Ctrl-click opens the context menu.
  - Clicking a root header toggles it.
- **Favorite reorder:** drag a row; the top half drops before, the bottom half after; a 2 px accent line marks the spot; the dragged row dims to 0.45 (`TreePane.tsx:1104-1150`; `R/styles.css:6426-6448`).
- **Drop target:**
  - valid: accent soft fill, ring, label bold, and a pill "Drop here"
  - invalid: red tint (`R/styles.css:2453-2467, 2797-2812`)
- **Keyboard** (`R/lib/treeView.ts:46-126`): ↑↓ move, Home/End, → load/expand/first child, ← collapse/parent.
- **Typeahead:** "Jump to" pill centred in the pane, resets after 1000 ms (`R/hooks/useExplorerNavigationController.ts:2414, 698-735`; `TreePane.tsx:699-704`).

### 1.5 Content pane (`R/components/ContentPane.tsx`)
- **Rows:** optional search header, list, Info Row, path bar (`R/styles.css:4377-4385`).
- **Path bar row** (`R/styles.css:4387-4422`, `ContentPane.tsx:712-857`):
  - Height 28, padding `0 10`, top border, 11 px text.
  - Segments: 20 px tall, padding `0 6`, max width 220 (current folder 320).
  - Separator `›` is a 16 px button that opens a **folder menu**.
  - `/` shows as "Macintosh HD"; a path on another volume starts at that volume.
  - **Collapse rules** (`ContentPane.tsx:937-1080`): with more than 4 segments, middle folders collapse into a "…" button. Its tooltip is "Show N More Folders"; clicking expands the bar into a horizontal scroll.
  - **Clicks:**
    - single click navigates after 320 ms
    - ⌘-click opens a new tab
    - double-click opens the inline path editor
  - **Path editor:** input field with a suggestions dropdown that opens **upward**. Esc clears suggestions, then closes; ↑↓ move; Tab focuses suggestions.
  - **Status text** sits at the right of the same row (`R/styles.css:6233-6247`) and shrinks with ellipsis; the path keeps at least 45%.
- **Info Row** (`R/components/InfoRow.tsx`, `R/styles.css:3269-3330`):
  - Height 30, top border; slides via max-height/opacity (220/180 ms).
  - Shows a 16 px icon, the name (500 weight), then facts in 12 px secondary separated by " · ": kind, size, "Modified <relative>".
  - Several items: "N items" plus the summed size.
  - Folders get "Calculate" / spinner / refresh.
  - Nothing selected: describes the current folder (`R/App.tsx:2192`).
- **Search bar** (search mode only; `R/components/SearchBar.tsx`, `R/styles.css:4505-4527, 6534-6556`):
  - "Search:" label, then a segmented scope control: “Current”, Home, the volume, Macintosh HD (`R/App.tsx:2928-2950`).
  - Filter field "Filter by name or folder"; Esc clears it, then returns focus to the results.
  - "Stop" button with spinner, appearing after 400 ms.
  - "Done" button.
  - Banner when truncated: "Showing the first 20,000 matches."
- **Empty and error states** (`ContentPane.tsx:2355-2466`):
  - "Loading…" card after 400 ms.
  - "Couldn’t open this folder" plus the message.
  - Trash Full Disk Access card with an "Open Privacy Settings" default button.
  - "Empty folder" or "Empty folder · N hidden items"; "Select a folder to see what’s in it."
  - Filter with no match: "No items match “q”" / "Nothing in this folder has that in its name." plus a "Search Subfolders" button.
  - Search states (`SearchBar.tsx:SearchResultsState`): "Searching…", "No matches" / "Try other text, or another location above.", "Incomplete pattern", "Search failed".
- **Drop onto background:** 2 px accent inset ring (`R/styles.css:1842-1852`).

### 1.6 Info panel (GetInfoPanel) — see §3.20.

---

## 2. Views

**View modes** (`S/appPreferences.ts:16-23`): `icons` = "Icons", `details` = "List", `list` = "Compact List".
- Menu order: Icons, List, Compact List.
- Folder view default: icons. Search results default: details (`:394-395`).
- Each tab has its own folder view mode and search view mode.

### 2.1 Icon view (`R/components/IconGridView.tsx`, `R/lib/iconGridLayout.ts`, `R/styles.css:7899-8110`)

| Metric | Regular | Compact |
|---|---|---|
| icon | 64 | 48 |
| icon box (tile) | 72 | 56 |
| cell min width | 104 | 88 |
| row pitch | 116 | 94 |
| item top padding | 5 | 3 |
| icon→label gap | 4 | 3 |
| label width | 102 | 86 |
| pane padding top/bottom | 10 | 8 |
| pane padding inline | 16 | 16 |

- **Columns:** `max(1, floor((width − 32) / cellMin))`; columns stretch to share the width; each item stays centred, so the gaps are empty space (`iconGridLayout.ts:61-64`).
- **Label:** 13 px / line-height 16 (compact 12/15); padding `1 4` (compact `1 2`); radius 4; at most 2 lines.
- **Middle truncation** (`R/lib/iconLabel.ts`): the first line wraps naturally; the rest becomes `head…tail.ext`, keeping up to 5 trailing stem characters plus the extension. Results are cached up to 4000 entries.
- **Hit testing:** only the icon tile and the label take clicks (`R/styles.css:2675-2688`).
- **Selection** (`R/styles.css:8041-8053`):
  - tile background is text colour at 10%
  - focused pane: label pill `--ft-accent-selection-bg` with white text
  - unfocused: `--bg-active-inactive`
- **Thumbnails:** Quick Look previews (photos framed with a hairline and shadow, radius 2), loaded a few at a time (`R/lib/fileThumbnails.tsx`).
- **Clipboard badge:** 18 px circle at the icon's corner (−4, −4); 1 px accent border; copy or scissors glyph (`R/styles.css:7767-7782`).

### 2.2 List view, i.e. `details` (`ContentPane.tsx:1450-2280`, `R/lib/detailsLayout.ts`)
- **Rows:** 28 (compact 24); column gap 12; row padding `0 12`; rows inset 10 px from the pane edges, so stripes and selection are rounded bars with radius 6 (`R/styles.css:4441-4469`).
- **Stripes:** odd rows get ink at 3.5%.
- **Text:** name 14 px primary; other cells 14 px secondary (tabular numbers); compact 13 px.
- **Header:** 28 tall, 11 px secondary; the active sort column is semibold. Sort chevron 9×6 at the right edge.
- **Header separators:** 1×14 px lines that are also the resize handles (12 px hit area); darker on hover (`R/styles.css:2846-2872`).
- **Columns** (`S/appPreferences.ts:136-193`):

| Column | Default width | Min | Max | Shown by default |
|---|---|---|---|---|
| Name (always first) | 320 | 140 | 720 | always |
| Date Modified | 152 | 80 | 280 | yes |
| Size | 108 | 60 | 240 | yes |
| Kind | 148 | 60 | 320 | yes |
| Date Created | 152 | 80 | 280 | no |
| Permissions | 108 | 36 | 260 | no |

  - **Order:** chosen in Settings.
  - **Search results add "Folder"** (default 240, range 80–720). Search defaults: Folder, Modified, Size shown; Name width 300 (`:201-235`).
- **Sorting:**
  - Header click: the same column toggles direction. A new column starts **descending for Modified/Size**, ascending otherwise (`R/hooks/useExplorerNavigationController.ts:2002-2025`).
  - Not sortable: Created, Permissions, Folder (in folder view) (`ContentPane.tsx:350-356`).
  - Search results sort by name, path (Folder column), or kind (`R/App.tsx:584-588`; `R/lib/searchResults.ts`).
- **Resizing:**
  - Drag uses a global pointer; ←/→ on a focused separator steps ±12.
  - **Double-click** fits the column to its title and widest value, plus 2 px slack; Permissions ignores its title (`detailsLayout.ts:91-119`; `ContentPane.tsx:1665-1780`).
- **Narrow pane** (`detailsLayout.ts:62-87`): Name shrinks to a floor of 160 (absolute min 96), then columns drop from the right. Saved widths are unchanged.
- **Size column:**
  - Right-aligned; folders show "--" (secondary) until calculated, or "Calculating…".
  - **Size bars** appear only while sorted by size (folder view, not search):
    - bar width = item bytes ÷ the largest in the folder
    - bar is accent at 20%, inset top/bottom 3, extends 4 px past the right edge, radius 4, min 2 px
    - on a selected row, the white selection-text colour at 28%
    - (`R/App.tsx:508-528`; `ContentPane.tsx:2133-2216`; `R/styles.css:2894-2935`)
- **Dates:** relative text with the exact date as tooltip (§6).
- **Permissions:** octal in a monospace font; tooltip `rwxr-xr-x`.
- **Folder column:** right-to-left ellipsis, "src › renderer" (`R/lib/searchResults.ts:117-128`).

### 2.3 Compact List, i.e. `list` (`ContentPane.tsx:1082-1448`, `R/lib/flowListLayout.ts`)
- Column-major: fills top to bottom, then the next column; scrolls **horizontally**, and the vertical wheel scrolls sideways (`ContentPane.tsx:1306-1318`).
- Item width 292 (compact 252); column gap 18; row height 28/24; padding `8 10 4`.
- Items are as wide as icon plus name (max the column width); highlight hugs the content.
- Font 14 (compact 13); 18 px icons; gap 8.
- ←/→ move by a column, ↑/↓ by an item.

### 2.4 Density
- One "Density" setting (Comfortable/Compact) sets 4 flags: list, details, icon, tree. Mixed flags show as a disabled "Custom" option (`R/components/SettingsView.tsx:1366-1404`).

### 2.5 Virtualization
- Fixed row heights read from layout tokens, not measured from the page (`R/lib/virtualization.ts`).
- Overscan: details 10, flow 6, icons 3 (`ContentPane.tsx:1201, 1572`; `IconGridView.tsx:190`).
- Scroll position is coalesced with requestAnimationFrame; stripe parity comes from the absolute row index.
- **Native:** `NSTableView` / `NSCollectionView` virtualize on their own; keep the same fixed metrics.

### 2.6 Selection model (`R/lib/contentSelection.ts`, `R/components/entryItemEvents.ts`)
- **State:** paths, anchor, lead, and an optional `gapIndex` (where removed items stood).
- **Pointer down** on an item:
  - selects it if it is not selected, or if ⌘/⇧ is held
  - ⌘ toggles (`toggleContentSelection`)
  - ⇧ extends a range in visual order
- **Plain click** on one of several selected items narrows to it on click, not on press, so a drag can carry the whole selection (`isSelectionNarrowingClick`).
- **Double-click** activates; ⌘-double-click on a folder opens it in a new tab (`R/App.tsx:2398-2405`).
- **Mouse down on empty space** clears the selection (unless ⌘/⇧) and starts marquee selection (`ContentPane.tsx:1818-1832`).
- **Right-click on empty space** clears the selection and opens the background menu.
- **Marquee** (`R/lib/dragSelection.ts`, `R/hooks/useDragSelection.ts`):
  - threshold 4 px
  - modes: plain replace, ⇧ add, ⌘ toggle
  - auto-scroll step `sign × min(40, 4 + |overshoot|/3)`
  - box: border text colour at 38%, fill at 12% (`R/styles.css:2270-2282`)
  - icon view hit-tests only tile and label
- **Arrow keys** (`R/lib/explorerNavigation.ts:132-212`):
  - details: linear
  - icons: ←/→ ±1, ↑/↓ ±columns; ↓ from the row above a short last row goes to the last item
  - compact list: ↑/↓ ±1, ←/→ ±rows-per-column
  - Home/End; ⇧ extends
- **Paging:** PageUp/PageDown is a full page (visible − 1 lines); ⌃U/⌃D is half (floor(visible / 2)); ⇧ extends (`:214-252`).
- **Typing in the list does not jump to a match.** It types into a **filter**:
  - The list narrows to names containing the text (case-insensitive).
  - The first name starting with the text is selected.
  - A floating **filter pill** at bottom centre shows "Filter <text> n of N" with a clear button.
  - ⌫ removes a character; Esc clears.
  - Space counts as text for 1 s after the last typed character, otherwise it is Quick Look.
  - The filter clears when the folder changes.
  - Sources: `R/lib/listFilter.ts`; `R/hooks/useExplorerNavigationController.ts:579-697`; `R/components/ListFilterPill.tsx`; `R/styles.css:1894-1934`.
- **Tab** switches focus between tree and list (`R/hooks/useExplorerShortcuts.ts:360-394`).
- **Selection colours** depend on focus: focused pane uses the accent; an unfocused pane, or an inactive window, uses gray.
- **Cut/copy marks** (`R/lib/clipboardMarks.tsx`, `R/styles.css:7700-7835`):
  - 12 px copy or scissors glyph after the name, in the accent (white on a selected row)
  - **cut items are dimmed:** label 0.55, icon 0.45
  - a 700 ms accent flash overlay when items are copied or cut
  - toggled by the Settings option "Mark copied and cut items"
- **Name highlight** (search matches, `R/lib/nameHighlight.tsx`, `R/lib/searchResults.ts:94-111`):
  - Yellow `rgba(255,214,10,.45)` mark with radius 4.
  - Underlined instead on a selected row.
  - Smart case; glob and path searches are not highlighted.
  - Maps onto middle-truncated labels; the "…" is marked when the match falls in the hidden part.
- **Inline rename** (`R/components/InlineRenameField.tsx`; `R/styles.css:7846-7896`):
  - Return (default "Return key" setting) or F2 starts it.
  - Field 20 px tall, opaque `--bg-base`, focus ring, radius 4.
  - Selects the stem only for files, the whole name for folders.
  - Return commits; Esc cancels; blur commits.
  - An unchanged or empty name cancels.
  - A refused name keeps the field open, adds a red ring, and shows an error popup under the field (max width 320, danger text).
  - The draft survives scrolling and virtualization.
  - Several selected items open the Batch Rename sheet instead.
  - Tree folders use the TextPromptDialog instead (`R/components/AppDialogs.tsx:246-258`).

---

## 3. Dialogs, sheets, popovers and menus

**Common menu look** (`R/styles.css:973-1205`):
- Min width 220; padding 5; 0.5 px border; radius 10; opaque `--context-menu-bg`; shadow.
- Rows 24 tall, padding `0 10 0 8`; a 16 px check/icon column, so labels start 30 px from the edge.
- Highlight fills with `--ft-accent-solid-button` and `--ft-accent-on-solid` text.
- Shortcut text: 14 px left margin, grey.
- Separator: 1 px, margin `5 10`.
- Section heading: 11 px semibold, left padding 30.
- Disabled items grey and never highlight.
- Menus are kept 8 px inside the window (`R/lib/menuPlacement.ts`).
- Toolbar dropdowns align left or right depending on which half of the window the anchor is in, 6 px below it.
- **Native:** NSMenu will look close. The differences are the opaque background and the accent-coloured highlight with any custom accent, which NSMenu always draws in the system accent.

**Common alert** (`R/components/Alert.tsx`, `R/styles.css:1459-1558`):
- Centred card, width 272, padding `20 16 16`, radius 14, no icon.
- Title 13 px bold; message 11 px secondary.
- Two buttons split the width (height 28); three or more stack.
- **Wide variant:** 520 px, left-aligned, buttons right-aligned.
- Scrim `rgba(0,0,0,.12)` (dark `.32`).
- Return presses the default button; Esc/⌘. cancels; Tab is trapped (`R/components/useDialogFocus.ts`).
- The default button is the **rightmost**.
- **Native:** NSAlert has an icon and a different layout, so a pixel match needs a custom panel or sheet.

**Push button** (`R/styles.css:1245-1307`):
- Height 24, min width 76, padding `0 12`, radius 6, 13 px; bezel = 0.5 px edge plus a faint shadow.
- **Default:** accent fill with white or black text (chosen for contrast).
- **Destructive:** red text, never the default.
- **Small:** height 22, 12 px text.
- Pressed: brightness 0.94 (dark 1.25).

### 3.1 GoToFolderDialog (Go To ⌘K/⇧⌘G, and Move To ⇧⌘M) — `R/components/GoToFolderDialog.tsx`, `R/styles.css:3431-3666`
- **Panel:** 560 px wide, dropped 60 px below the top (sheet-like), radius 14.
- **Title:** shown for "Move To" only.
- **Field:** height 28, magnifier icon, placeholder "Folder name, or a path starting with / or ~", clear button.
- **List label:**
  - "Recent and favorite folders" before anything is typed, or "N matches"
  - right-side hint "⇥ Completes" (path mode) or "⌘⌫ Removes from List"
- **List:** 8 visible rows of 28 px, then scrolls.
- **Rows:**
  - 14 px star (favorite) or folder glyph
  - name (max 55%, matched letters **bold**)
  - location in secondary text, truncated at the **start** (right-to-left trick)
  - selected row filled with the accent
- **Footer:** Choose… (Move To only), spacer, Cancel, Open/Move (default).
- **Name mode:** ranks places (§8.5). In Go To, the top row is preselected so Return opens it; Move To does not preselect.
- **Path mode** (starts with `/` or `~`): completions from disk.
  - ↓ selects a completion.
  - Tab completes and appends `/`.
  - Return on a selected completion puts it in the field first; a second Return opens it.
- **Other keys:** ⌘⌫ forgets a visited folder; Esc or a click on the backdrop closes.
- **Mouse:** a row is selected only after the pointer actually moves.
- **Empty states:**
  - "No folders match this path"
  - "No folder you have opened has that name. Start with / or ~ to type a path."
  - "Folders you open are listed here. Start with / or ~ to type a path."

### 3.2 Copy/paste flow (`R/components/AppDialogs.tsx:286-560`)
- **Analysis:** CopyPasteDialog alert titled "Preparing to Paste…" (or Move/Copy/Duplicate), message "Checking the destination for items with the same names.", Cancel.
- **Single non-folder conflict:** an alert like Finder's (`R/components/CopyPasteReviewDialog.tsx:179-226`):
  - title "“X” already exists in “Dest”", message "Replace moves the item there to the Trash."
  - buttons [Cancel (aside, left)] [Replace (destructive)] [Keep Both (default)]
- **Review sheet** (CopyPasteReviewDialog; `R/styles.css:7174-7420`):
  - Width 680, below the toolbar.
  - Header title, for example "N of M items already exist in “Dest”" or "Copy N items into “Dest”?" (large-operation message).
  - **Bar** "For all conflicts:" with a segmented choice:
    - Skip / [Add Missing] / Keep All / Replace
    - Add Missing appears only when folders conflict and the action is not a move
    - Replace turns red when selected
    - a hint line under it, for example "Existing items stay as they are." (`R/lib/copyPasteReview.ts:100-145`)
  - "Show N new items" link.
  - Rows: 20 px glyph, name, optional rename/path line, detail, and a per-row popup (Keep Both / Replace / Skip / Merge).
  - "Show all N" after a row limit.
  - Footer note, with a warning glyph when replacing ("N existing items will be moved to the Trash", "Merging can’t be undone").
  - Buttons Cancel / primary ("Replace N and Copy" in red when replacing).
  - Return starts the operation unless it replaces something.
- **Runtime conflict** (CopyPasteRuntimeConflictDialog):
  - Wide alert with two fingerprint cards ("In “folder” now" and "Being pasted"), each showing name and "size · date".
  - Checkbox "Do the same for similar changes while pasting".
  - Buttons: [Stop Pasting (aside)] [secondary choices] [default safe choice].
  - Reasons: destination_created / changed / deleted, source_changed / deleted, trash_unavailable ("Delete Permanently") (`:170-210`).
- **Progress card** (CopyPasteProgressCard; `R/styles.css:1631-1726`):
  - Bottom right, width 320, menu surface, radius 10.
  - Shows after 500 ms (`R/lib/progressCardDelay.ts`).
  - Title such as "Moving…", "Copying…", "Moving to Trash…" (`AppDialogs.tsx:625-655`) plus a percent.
  - 4 px accent track.
  - "Current item: name".
  - Meta line "x of N items · 1.2 GB of 3 GB" (or "Preparing…", "Waiting to start", "Waiting for your answer", "Working…").
  - Small "Stop" button.
  - Placed 10 px above the path bar / Info Row (`R/lib/bottomStack.ts`).
- **Result:**
  - Copy-like actions, batch rename, undo and redo use CopyPasteResultDialog, a sheet listing Failed / Stopped part way / Not started / Note / Skipped, with "Retry N Items" or "Try Again…".
  - Other operations use a simple alert: title "Move to Trash" etc.; message "Done." / "Some items couldn’t be changed." / …; up to 3 detail lines.
- **Confirmations** (all CopyPasteDialog):
  - Move to Trash?
  - Delete Immediately: Finder wording; Cancel is the default.
  - Delete on a volume without a Trash.
  - Empty Trash: "Are you sure you want to permanently erase the items in the Trash?"; Cancel default.
  - Dot name: "Use “.”"; Cancel default.
  - Always Open With: "Change All".

### 3.3 BatchRenameSheet (`R/components/BatchRenameSheet.tsx`, `S/batchRename.ts`, `R/styles.css:6696-7170`)
- Width 680, radius 14.
- **Header:**
  - title "Rename N Items"
  - Presets popup: "Presets" or "<name> (Edited)", saved presets, "Save as Preset…", plus update/delete actions
  - saving shows a name field (180 px) with Cancel / Save (or Replace)
- **Mode segmented control:** Replace Text / Add Text / Format / Change Case.
- **Option grid:** label 112 | control | label 132 | control; labels right-aligned.
  - **Replace:** Find (with validation), Replace with, checkboxes Match case and Regular expression.
  - **Add:** Text, before/after.
  - **Format:**
    - Name format: Name and Index / Name and Counter / Name and Date
    - Custom format (default "File")
    - Keep current names
    - Date: Created / Modified / Taken / Today
    - Date format list, or Custom… with token chips (YYYY YY MM DD HH mm ss) and "Text in [brackets] is kept as typed"
    - separators: Space / - / _ / None
    - Start numbers at; Digits (As Many as Needed / 2–5); step
  - **Case:** lowercase / UPPERCASE / Title Case.
  - **Apply to:** Name / Extension / Name and Extension (Format mode: "Names only: extensions are kept").
  - **If a name is taken:** Add a Number / Skip Those Items / Don’t Rename.
  - Warning: "Changing an extension can change the app a file opens in."
- **Preview:** columns `18 | old | 14 arrow | new`, header 22 px, rows 26 px, 8 rows visible; changed parts marked in accent; problems in red; skipped struck through.
- **Footer:**
  - summary, e.g. "N will be renamed · N get a number · …", or "Checking names…", "Nothing to rename yet", "N names to fix before renaming"
  - Cancel, and "Rename N Items" (default)
- **Defaults:** `S/batchRename.ts:92-115`.

### 3.4 TextPromptDialog (`R/components/TextPromptDialog.tsx`)
- Alert with a field: height 24, text selected or caret at the end; error line in danger colour.
- Uses:
  - Rename tree folder: title "Rename “X”", button "Rename".
  - New Folder: title "New Folder", message "In “parent”", button "Create Folder" (`AppDialogs.tsx:246-271`).
- Submit is disabled while the field is empty. Esc closes, but not during IME composition.

### 3.5 Alert family
- ActionNoticeDialog: one OK button.
- **EjectWhichVolumesAlert** (`R/components/EjectVolumeAlert.tsx`):
  - title "Do you want to eject “X” only, or all N volumes on its disk?"
  - buttons stacked: Eject All (default) / Eject / Cancel
  - text in `R/lib/eject.ts:79-90`
- **EjectBusyAlert:** stacked Try Again (default) / Force Eject (destructive) / Cancel; wording "disk" vs "volume".
- **UndoQuestionAlert** (`R/components/UndoQuestionAlert.tsx`, `R/lib/undoQuestion.ts`):
  - "Keep Both" is the default for a name-taken question; "Move to Trash" is not the default for a changed-items question.
  - Lists up to 5 names, then "and N more".

### 3.6 ClipboardButton popover (`R/components/ClipboardButton.tsx`, `R/styles.css:7604-7690`)
- **Button:** shown only while something is on the clipboard. Copy or scissors icon plus a count (11 px semibold accent). Tooltip "name copied" or "N items copied".
- **Menu:** width 260–420.
  - Header "N items copied" with the hint "Paste with ⌘V"; breakdown line "2 folders and 3 files".
  - List grouped under folder headings; the top heading stays pinned while scrolling; 10 visible rows of 24 px, virtualized.
  - Each row: icon, name, a hover × "Remove from Clipboard".
  - Footer "Clear Clipboard".
  - A permanent 10 px scrollbar.
- **Keys:** ↑↓, Home/End, Return reveals the item, ⌫ removes it, Esc/Tab closes. Keyboard focus never moves into the menu.

### 3.7 HistoryButton (`R/components/HistoryButton.tsx`, `R/lib/historyMenu.ts`)
- **Opening:** click steps back/forward; **holding 350 ms**, or right-click, opens a menu.
- **Contents:** up to 12 entries, nearest first, as "Name" plus a detail with the parent path (home shown as ~), 11 px secondary; max width 420.
- **Keys:** ↑↓ wrap, Return/Space choose, Esc/Tab close.
- Choosing an entry jumps within the history without adding to it.

### 3.8 PathbarFolderMenu (`R/components/PathbarFolderMenu.tsx`, `R/styles.css:2085-2125`)
- Opened by clicking a `›` separator; lists the folders inside the folder to its left, with the folder the path goes through ticked.
- Opens upward (the bar is at the bottom); width 200–360, max height 440.
- Loading note "Loading…" after 300 ms; other notes "Can’t Read This Folder", "No Folders".
- At most 300 folders, centred around the ticked one, with a count of the rest.
- Keys: ↑↓, Home/End, letter jump, Return.

### 3.9 ThemeMenuButton (`R/components/ThemeMenuButton.tsx`)
- Toolbar item with tooltip "Theme: Auto"; menu Auto / Light / Dark with a checkmark.

### 3.10 SearchOptionsMenu (`R/components/SearchOptionsMenu.tsx:225-256`)
- Heading **Match**: Name / Full Path (radio).
- Heading **Match As**: Plain Text / Glob / Regex (radio).
- separator
- Search Subfolders (checkbox)
- separator
- Skip .git Folders, Skip Files Ignored by Git (checkboxes)
- Keyboard-opened: focus goes to the first item. Mouse-opened: focus stays in the field.

### 3.11 ItemContextMenu (`R/components/ItemContextMenu.tsx`, `R/lib/contextMenu.ts`)
- **Rendering:** every item has a 14 px line icon; destructive items are red. Submenus open beside the menu (Open With with app icons and a scrolling list; View As; Sort By). Holding **Option** turns Open With into **Always Open With**.
- **Keys:** ↑↓, Home/End, → enters a submenu, ← leaves it, Return/Space choose, a letter jumps, ⌥Return picks the alternate.
- **Shortcuts are shown** only when pressing the key would do the same thing now (`R/lib/shortcutPolicy.ts:343-414`).
- **Surfaces** (`R/lib/contextMenu.ts:179-305`):
  - **content** (file list item):
    1. Open, Open in New Tab, Open in New Window, Open With ▸, Quick Look, Edit in <Editor>, Show Package Contents
    2. Show Info, Calculate Size
    3. Cut, Copy, Paste into Folder, Copy Path
    4. Rename (or "Rename N Items…"), Duplicate, Move to…, New Folder
    5. Add/Remove from Favorites
    6. Open in Terminal, Show in Finder
    7. Move to Trash
  - **search:** "Reveal in Folder", separator, then the content menu.
  - **trash:** the content menu plus "Delete Immediately…".
  - **treeFolder:**
    1. New Folder
    2. Open in New Tab, Open in New Window, Use as Tree Root
    3. Show Info, Calculate Size
    4. Cut, Copy, Paste into Folder, Copy Path
    5. Rename, Duplicate, Move to…
    6. favorite toggle
    7. Open in Terminal, Show in Finder
    8. Move to Trash, Delete Immediately…
  - **favorite / location:**
    1. New Folder
    2. Open in New Tab, Open in New Window, Reveal in Tree, Use as Tree Root
    3. Eject “X”
    4. Show Info, Calculate Size
    5. Paste into Folder, Copy Path
    6. favorite toggle
    7. Open in Terminal, Show in Finder
    8. Empty Trash…
  - **background:**
    1. New Folder
    2. Show Info, Calculate Size
    3. Paste, Copy Path
    4. View As ▸, Sort By ▸
    5. Open in Terminal, Show in Finder
    6. Empty Trash…
- **Visibility rules** (`R/hooks/useExplorerActions.ts:576-700`): items that cannot apply are **hidden, not dimmed**; only Paste may be dimmed.
  - Edit only for text files.
  - Show Package Contents only for bundles.
  - Calculate Size only when folders are involved.
  - Paste/New Folder only for a single folder.
  - Open in New Tab/Window only for a single folder.
  - While a write is running: paste, move, rename, duplicate, new folder, trash, delete and empty trash are hidden.
  - The Trash hides paste, new folder, duplicate and trash.
  - The toggle reads "Add to Favorites" or "Remove from Favorites".
- **Menu-target ring:** the right-clicked tree row gets a 2 px accent ring.

### 3.12 ToastViewport (`R/components/ToastViewport.tsx`, `R/lib/toasts.ts`, `R/styles.css:1560-1630`)
- Cards bottom right (right 12, above the bars and the progress card); each as wide as its text, max 420.
- At most 3 visible; 4 s each.
- Kinds: success (filled check) and info (filled "i").
- One line: title, then grey detail that truncates first.
- Slide-in 180 ms (8 px).
- Only when "Show notifications" is on.
- Example: "A window can have up to 100 tabs" (`R/hooks/useExplorerTabs.ts:397-415`).

### 3.13 PathSuggestionDropdown (`R/components/PathSuggestionDropdown.tsx`, `R/styles.css:2200-2265`)
- Under the path editor; opens upward in the path bar.
- Rows: grid of name (12 px, 500 weight) and full path (monospace 12 px, ellipsis).
- Active row filled with the accent; up to 12 suggestions (`R/App.tsx:2957`).

### 3.14 Other popovers
- **Tab context menu:** §1.3.
- **Toolbar Customize menu:** §1.2.
- **Favorite icon picker** (Settings): 6-column grid of 30 px cells, gap 4, padding 6; the selected cell is accent-filled.
- **ApplicationPopup:** current app with its icon, the default app, separator, "Choose…".
- **Zoom combo box:** text field plus a menu of zoom steps.

### 3.15 Info panel (`R/components/GetInfoPanel.tsx`, `R/styles.css:3127-3270, 4555-4850`)
- **Header:** 32 tall, 12 px semibold secondary "Info"; a spinner after 300 ms when pending; close × (18 px), tooltip "Hide Info Panel (⌘I)". Inset 16.
- **Hero:** icon box 104 (icon 88; native icon 96); name 15 px semibold, 2-line clamp; subtitle "Kind · size" (12 px).
- **Split "Open" button:**
  - full width, accent-filled
  - label "Open in <App>" with the app icon for files, "Open" otherwise
  - 26 px chevron half for Open With; Option shows "Always Open With"
- **Section "Information"** (11 px semibold title):
  - Rows Size, Kind, Opens with (popup button), Created, Modified, Permissions ("Read & Write" plus the octal code), Where (accent link).
  - Volume roots show Capacity / Available / Used.
  - Placeholder "—" while pending.
  - Rows are 8 px padded with hairline separators; labels and values 12 px.
- **Folder size cell:** "Calculate" accent link; after 300 ms a spinner with × "Stop Calculating"; when done "1.2 GB (1.3 GB on disk)" over "48,611 files, 2,765 folders", plus a refresh button.
- **Section "Quick Actions":** row of 32×28 icon buttons with tooltips: Quick Look, Edit in X, Copy Path / Copy Name ("Copied" for 1.5 s), Open in Terminal, Show in Finder, Add/Remove Favorites, Use as Tree Root.
- **Several selected items:** hero with a stacked two-icon glyph, "N items", "3 folders and 2 files · size", rows Size and Where ("Several folders").
- **Empty:** "Select a file or folder to show its info."
- **Auto size:** "Calculate folder sizes automatically" measures a single folder inside home while the panel is open (`R/hooks/useAutoFolderSize.ts`).

---

## 4. Settings window (`R/SettingsWindowApp.tsx`, `R/components/SettingsView.tsx`)

### 4.1 Window
- 720×540, min 680×420, not fullscreenable, traffic lights at (14, 16) (`M/main.ts:488-500`).
- **Layout:** sidebar 196 px plus a pane (`R/styles.css:4884-5050, 5223-5235`).
  - Sidebar padding `52 10 10`; items 30 tall, radius 6, gap 8.
  - Each item has a 20×20 tile with radius 5, a gradient, and a white 13 px glyph.
- **Tabs and tile tones** (`SettingsWindowApp.tsx:18-54`):
  - General: gray `#a3a3a9→#808086`
  - Browsing: blue `#4a9bff→#1f6fe8`
  - Search: indigo `#8f7bf5→#6750de`
  - Files: orange `#ffab45→#f3861b`
  - Shortcuts: slate `#7f8da5→#5d6a82`
- **Pane header:** 52 tall; 15 px semibold title; a hairline appears once the page scrolls; an accessory slot holds the Shortcuts search field (200 px).
- **Page:** max 560 px wide, padding `4 12 20 20`, scrollbar gutter kept.
- **Groups ("cards"):** text ink at 2.8% (dark: white 3.5%), 1 px inner border, radius 10, padding `0 12`.
  - Rows min 40 tall, padding 8, hairline between rows; title 13 px; description 11 px / 14 line-height (`R/styles.css:5341-5400`).
  - Section title 13 px semibold; note 11 px.
- **Behaviour:**
  - Esc closes the window.
  - Every edit saves immediately and syncs to explorer windows.
  - Remembers the last tab (`#settings/<tab>`).
  - Error banner "Couldn’t load the settings." with a Dismiss button.

### 4.2 Every preference
Types, defaults and order are in `S/appPreferences.ts:281-448`.

**General**
- *Appearance* (Restore Defaults button below the group):
  - **Theme** `theme`: auto | light | dark, default `auto`. Picker of 3 thumbnails (56×36, accent ring when selected).
  - **Accent color** `accent`: hex, default `#007aff`. Swatches Blue `#007aff`, Purple `#a550a7`, Pink `#f74f9e`, Red `#e0383e`, Orange `#f7821b`, Yellow `#ffc600`, Green `#62ba46`, Graphite `#8c8c8c`, Copper `#d4845a`, plus a Custom conic swatch that opens a color picker. 15 px circles, gap 7.
  - **Zoom** `zoomPercent`: 75–150, default 100. Combo box; description "⌘+, ⌘−, ⌘0 change it too."
- *Behavior*:
  - **Reopen the last folder and tabs** `restoreSessionOnStartup` = true.
  - **Show notifications** `notificationsEnabled` = true.
  - **Mark copied and cut items** `markClipboardItems` = true.
  - **Calculate folder sizes automatically** `autoCalculateFolderSizes` = true.

**Browsing**
- *Views*:
  - **Density** (Comfortable / Compact / disabled "Custom") maps to `compactListView`, `compactDetailsView`, `compactIconView`, `compactTreeView`, all false.
  - **Expand folders with a single click** `singleClickExpandTreeItems` = false.
- *Columns in List View*: a checkable list.
  - Name row is disabled with the note "Always first".
  - Drag to reorder; Space toggles; ⌘/⌥ + arrows move a row; "Restore Defaults" restores order only.
  - Backed by `detailColumns` and `detailColumnOrder`.
- *Favorites*:
  - **Show favorites** `favoritesPlacement`: integrated ("In the folder tree", default) | separate ("In their own section").
  - **Favorites list** `favorites`: icon picker per row, name and path; + / − / "Change…" / "Restore Defaults"; drag reorder; ⌥/⌘↑↓ move; Return changes; ⌫ removes.

**Search** (defaults only; the toolbar's menu changes them per search)
- **Search in** `searchMatchScope`: Names (`name`, default) | Full Paths.
- **Match as** `searchPatternMode`: Plain Text (default) | Glob | Regex.
- **Search subfolders** `searchRecursive` = true.
- **Skip .git folders** `searchSkipGitFolders` = true.
- **Skip files ignored by Git** `searchSkipGitIgnored` = false.
- *Columns in Search Results*: `searchColumns` and `searchColumnOrder`; defaults Folder, Modified, Size.

**Files**
- **Double-click a file to** `fileActivationAction`: Open (default) | Edit.
- **Return key** `returnKeyAction`: Renames (default) | Opens.
- **Open disk images in** `diskImageOpensIn`: New Window (default) | New Tab.
- **Ask before opening more than** `openItemLimit`: 1–50, default 5; number field "N items".
- **Text editor** `defaultTextEditor`: default TextEdit.
- **Terminal** `terminalApp`: null means Terminal.
- *Always in Open With* `openWithApplications`: list of apps; missing apps show "Not found ·".

**Saved but not shown in Settings** (window/session state):
- `viewMode`, `searchViewMode`, `sortBy` = name, `sortDirection` = asc, `foldersFirst` = true, `includeHidden` = false
- `folderTreeOpen` = true, `propertiesOpen` (Info panel) = false, `detailRowOpen` (Info Row) = false
- `topToolbarItems`
- `treeWidth` 280, `inspectorWidth` 320
- `detailColumnWidths`, `searchColumnWidths`
- `searchResultsSortBy` = path, `searchResultsSortDirection` = asc
- `openTabs` (max 100), `activeTabIndex`, `treeRootPath`, `lastVisitedPath`, `lastVisitedFavoritePath`
- `favoritesExpanded` = true, `locationsExpanded` = true, `favoritesInitialized`
- `batchRenameSettings`, `batchRenamePresets` (max 50)
- `shortcutOverrides`

**Per-window keys:** `WINDOW_SESSION_PREFERENCE_KEYS` (`:357-380`).

### 4.3 Shortcuts tab (`R/components/ShortcutSettings.tsx`)
- **Top:** search field "Search commands or keys" in the header; it matches labels, group names and keys. Intro: "Click a key and press the new one. Esc cancels, and ⌫ removes the key."
- **Groups** (each a card): Navigation, Windows and Tabs, Files, Search, View, "Standard shortcuts". The Standard group note: "The same in every Mac app, or shared with text fields. They can not be changed here."
- **Row:**
  - Label (plus a hint such as "Does what a double-click does.", "Return renames too: Settings → Files.").
  - "Restore Default" small button when customized.
  - **Up to 2 key slots:** 52 px min, 20 tall, radius 5.
    - An empty "+" slot is dashed and shows only on hover.
    - While recording the slot says "Press keys…" with an accent border.
    - A × removes a key; it shows on hover.
- **Recording:** Esc cancels; ⌫ removes; Tab leaves; key repeat is ignored.
- **Messages under a row:**
  - **Refused** (red): needs ⌘ or ⌃ for typing keys; needs ⌘/⌃/⌥ for motion keys; fixed command; ⌘. cancels dialogs; macOS-reserved (`S/shortcuts.ts:866-899`; texts at `ShortcutSettings.tsx:48-62`).
  - **Conflict:** "⌘X is used by <Cmd>." with buttons [Reassign] [Cancel].
  - **Info:** Mission Control keys (⌃arrows, F11); "Taken back from …" after a reset.
- **Footer:** "Restore Defaults" (disabled when nothing is customized).
- **Logic** (`S/shortcuts.ts:925-1090`): resolve, assign, remove, reset, persist overrides only.
- **Display:** glyphs ⌃⌥⇧⌘ in that order plus the key: ← → ↑ ↓ ↩ ⌫ ⌦ ⇥ ↖ ↘ ⇞ ⇟ "Esc" (`R/lib/shortcutLabels.ts`).
- **Return/rename:** when Return renames, "Return" is listed as Rename's first key (`R/lib/shortcutDisplay.ts:31-34`).

### 4.4 All 82 commands and default keys (`S/shortcuts.ts:41-535`)
Keys use the source notation (Cmd = ⌘, Ctrl = ⌃, Option = ⌥). An em dash means no default key.

**Navigation**

| Command | Label | Default keys |
|---|---|---|
| goBack | Back | Cmd+[, Cmd+Left |
| goForward | Forward | Cmd+], Cmd+Right |
| goEnclosingFolder | Enclosing Folder | Cmd+Up |
| goHomeRootTree | Home | Cmd+Shift+H |
| goDocuments, goDesktop, goDownloads, goLibrary, goMacintoshHD, goApplications, goTrash | (place name) | — |
| openLocationSheet | Go to Folder… | Cmd+K, Cmd+Shift+G |
| rootTreeAtSelection | Use as Tree Root | Cmd+Shift+R |
| refreshOrApplySearchSort | Refresh | Cmd+R |
| focusTreePane | Focus Folder Tree | — |
| focusContentPane | Focus File List | — |
| pageUp | Move One Page Up | PageUp |
| pageDown | Move One Page Down | PageDown |
| halfPageUp | Move Half a Page Up | Ctrl+U |
| halfPageDown | Move Half a Page Down | Ctrl+D |

**Windows and Tabs**

| Command | Label | Default keys |
|---|---|---|
| newWindow | New Window | Cmd+N |
| newTab | New Tab | Cmd+T |
| closeTab | Close Tab | Cmd+W |
| reopenClosedTab | Reopen Closed Tab | Cmd+Shift+T |
| selectNextTab | Show Next Tab | Ctrl+Tab, Cmd+Shift+] |
| selectPreviousTab | Show Previous Tab | Ctrl+Shift+Tab, Cmd+Shift+[ |
| openSelectionInNewTab | Open in New Tab | — |
| openSelectionInNewWindow | Open in New Window | — |
| moveTabToNewWindow | Move Tab to New Window | — |
| mergeAllWindows | Merge All Windows | — |

**Files**

| Command | Label | Default keys |
|---|---|---|
| openSelection | Open | Cmd+O |
| openSelectedItem | Open Selected Item | Cmd+Down |
| editSelection | Edit in Text Editor | Cmd+Shift+E |
| quickLookSelection | Quick Look | Space |
| calculateSize | Calculate Size | — |
| renameSelection | Rename | F2 (plus Return when the Return-key setting is Renames) |
| duplicateSelection | Duplicate | Cmd+D |
| moveSelection | Move to… | Cmd+Shift+M |
| newFolder | New Folder | Cmd+Shift+N |
| trashSelection | Move to Trash | Cmd+Backspace |
| ejectVolume | Eject | Cmd+E |
| emptyTrash | Empty Trash… | Cmd+Shift+Backspace |
| copyPath | Copy Path | Cmd+Option+C |
| showClipboard | Show Clipboard | — |
| clearClipboard | Clear Clipboard | — |
| openInTerminal | Open in Terminal | Cmd+Option+T |
| showInFinder | Show in Finder | — |
| toggleFavorite | Add to Favorites | — |

**Search**

| Command | Label | Default keys |
|---|---|---|
| focusFileSearch | Find Files… | Cmd+F |
| showLastSearchResults | Show Last Search Results | Cmd+Shift+F |
| revealInFolder | Reveal in Folder | — |

**View**

| Command | Label | Default keys |
|---|---|---|
| viewAsIcons | View as Icons | Cmd+1 |
| viewAsDetails | View as List | Cmd+2 |
| viewAsList | View as Compact List | Cmd+3 |
| sortByName, sortByKind, sortByModified, sortBySize | Sort by … | — |
| toggleFoldersFirst | Folders First | — |
| toggleHiddenFiles | Hidden Files | Cmd+Shift+. |
| toggleFolderTree | Folder Tree | Ctrl+Cmd+S |
| toggleInfoPanel | Info Panel | Cmd+I |
| toggleInfoRow | Info Row | Cmd+Shift+I |
| customizeToolbar | Customize Toolbar… | — |
| zoomIn | Zoom In | Cmd+Plus |
| zoomOut | Zoom Out | Cmd+- |
| resetZoom | Actual Size | Cmd+0 |
| openHelp | File Trail Help | ? |
| openKeyboardShortcuts | Keyboard Shortcuts | — |

**Standard (fixed, cannot be changed)**

| Command | Default key |
|---|---|
| Undo | Cmd+Z |
| Redo | Cmd+Shift+Z |
| Cut | Cmd+X |
| Copy | Cmd+C |
| Paste | Cmd+V |
| Select All | Cmd+A |
| Settings… | Cmd+, |
| Close Window | Cmd+Shift+W |
| Minimize | Cmd+M |
| Enter Full Screen | Ctrl+Cmd+F |
| Hide File Trail | Cmd+H |
| Hide Others | Cmd+Option+H |
| Quit File Trail | Cmd+Q |

**Keys that are not commands** (`R/hooks/useExplorerShortcuts.ts`, `R/lib/shortcutPolicy.ts:155-203`):
- Tab: switch pane.
- Arrows, Home, End: move.
- Return: rename or open.
- Typing: filter in the list, typeahead in the tree.
- ⌫ / Esc: edit the list filter.
- ⌘. : same as Esc.
- Esc in Help: return.

**Reserved by macOS** (refused): `S/shortcuts.ts:814-837`.

**Context gating:** which commands work with tree focus vs list focus and under modals (`R/lib/shortcutPolicy.ts:76-339`).

---

## 5. Design tokens (`R/styles.css`)

### 5.1 Fonts and type scale (`:79-97`)
- **Sans:** -apple-system / SF Pro Text. **Mono:** SF Mono, used for paths in suggestions, permissions, code.
- Font smoothing is left at the system default.

| Token | Size |
|---|---|
| mini | 10 |
| small | 11 |
| callout | 12 |
| body | 13 |
| name (file names in sidebar and views) | 14 |
| title3 | 15 |
| title2 | 17 |
| title1 | 20 |
| mono | 12 |

### 5.2 Radii, control heights, spacing (`:98-112`)
- **Radii:** xs 4, control 6, menu 10, dialog 14, capsule 999.
- **Control heights:** small 22, regular 24, large 28; toolbar controls 32.
- **Spacing scale:** 2, 4, 6, 8, 10, 12, 14, 16, 20, 24, 28.

### 5.3 Motion (`:113-121`)
- fast 120 ms, base 180, slow 220, flash 700, flash-slow 900, spin 700.
- Easing `cubic-bezier(.2,0,0,1)`.
- **Keyframes:** toast slide-in, info panel slide in/out, spinner, clipboard flash, toolbar item flash, folder "spring" wiggle (±7°, 250 ms).
- Reduced motion sets every duration to 0 (`:8187-8195`).

### 5.4 Other root tokens
- **Focus ring:** 3 px accent at 50% (`:123`).
- **Disabled opacity:** 0.4.
- **Fields:** fill `--bg-input`, 0.5 px inset edge.
- **Z-order layers:** `:139-148`.

### 5.5 Colours

| Token | Light | Dark |
|---|---|---|
| bg-base | #ffffff | #1e1e20 |
| bg-surface | #ececf0 | #29292c |
| bg-elevated | #ffffff | #2a2a2d |
| bg-hover | text-primary 5% | text-primary 5% |
| bg-input | rgba(0,0,0,.04) | rgba(255,255,255,.06) |
| bg-active-inactive (unfocused selection) | #dcdce1 | #3a3a3e |
| border | #dcdce1 | #38383b |
| border-light | rgba(0,0,0,.07) | rgba(255,255,255,.07) |
| border-active | rgba(0,0,0,.12) | rgba(255,255,255,.1) |
| text-primary | #1d1d1f | #f2f2f5 |
| text-secondary | rgba(0,0,0,.5) | rgba(255,255,255,.55) |
| text-tertiary | rgba(0,0,0,.26) | rgba(255,255,255,.25) |
| text-dim | #a1a1a6 | #6e6e73 |
| sidebar-bg | #ececf0 | #29292c |
| toolbar-toggle-bg (capsule / segment track) | #ececf0 | #323235 |
| toolbar-toggle-active-bg (raised segment) | #ffffff | #5a5a5e |
| context-menu-bg | #f6f6f8 | #2c2c30 |
| menu border | rgba(0,0,0,.16) | rgba(255,255,255,.12) |
| menu shadow | `0 8 32 .12, 0 2 8 .06` | `0 8 40 .45, 0 2 8 .25` |
| menu shortcut text | #89898d | #79797e |
| menu disabled text | #a7a7ab | #606062 |
| destructive | #e0383e | #ff453a |
| danger / danger-text | #b42318 | #f08080 |
| search-surface | #ececf0 | #323235 |
| scroll-thumb | rgba(110,110,115,.22) | rgba(161,161,166,.30) |
| scrim | .12 | .32 |

- Scrollbars are 8 px.
- **Settings group colours:** `:5208-5232`.
- **Warning glyph:** yellow #ffcc00 (`:6690-6702`).
- **Hard-coded placeholder icons:** folder blues `#45aae4` / `#67c0ef` / `#80cff7` (`:3078-3087`).

### 5.6 Accent handling (`R/lib/accent.ts`, `R/lib/theme.ts`)
The accent can be **any hex**. Tokens derived from it:
- **solidButton:** the accent darkened in 1% steps (up to 20%) until white text reaches 4.5:1 contrast; otherwise black text on the plain accent (`:157-171`).
- **selectionBg:** the accent darkened by at least 14%, at most 34%, until white reaches 4.5:1; selection text is always white (`:183-195`).
- **softBg:** 8% alpha; **border:** 30%; **ringSoft:** 15%.
- **activeBg:** 8% (light) / 10% (dark).
- **folderTint:** 16% / 14%.
- **solidDark** and **pathCrumbHover:** the accent darkened 18%; used on light themes only.
- Dark theme: batch-rename marks use the accent mixed 65% with white.
- **Native port:** compute these colours yourself. Don't use `NSColor.controlAccentColor` or the standard selection highlight, because the user picks the accent inside the app.

### 5.7 Selection, bars and rings
- Rows and icon labels: focused = `--ft-accent-selection-bg` with white text; unfocused or inactive window = `--bg-active-inactive` (`R/styles.css:4473-4497`).
- Size bars: §2.2.
- Focus rings are hidden on rows and lists; panes show no focus ring.
- Drop-target styles: §1.4.

### 5.8 Controls that need custom drawing to match
1. Toolbar capsules and fills; segmented view switch; capsule search field with options button.
2. Tab strip (flat tabs, accent top line).
3. Bottom path bar with menu separators and status text (NSPathControl looks different).
4. Info Row; Info panel (split Open button, link-style values, icon action row).
5. Alerts (no icon, 272 px, rightmost default) and sheets dropped 60 px from the top.
6. Go To / Move To panel.
7. Toasts; progress card.
8. List filter pill; "Jump to" pill.
9. Accent-derived selection colours; striped, inset, rounded list rows.
10. Size bars; icon-view label pill with middle truncation; clipboard badges, dimming and flash.
11. Settings: switch 28×16 (thumb 14); appearance thumbnails; accent swatches; settings list with +/− bar; icon grid picker; shortcut recorder; custom checkbox (14 px accent).
12. Batch-rename preview; review sheet; conflict cards.
13. App-drawn tooltips (600 ms delay, warm window 400 ms, 11 px) (`R/lib/titleTooltips.ts`) — native `toolTip` would be acceptable.
14. Toolbar customization editor.
15. Icons: all toolbar, menu and Info-panel icons are custom stroke SVGs (`R/components/ToolbarIcon.tsx`, `ItemContextMenu.tsx:380+`, `GetInfoPanel.tsx:821+`). Map them to SF Symbols, or re-draw them.
16. File icons come from macOS (`system:getFileIcon`, cached by kind/extension; `R/lib/fileIcons.tsx`) and map directly to `NSWorkspace.icon(forFile:)`.

---

## 6. Formatting

### 6.1 Relative dates (`R/lib/formatting.ts:33-77`)

| Age | Text |
|---|---|
| future by more than 1 min | full medium date + short time |
| under 1 min | "Just now" |
| under 1 h | "N min ago" |
| today | "Today, 9:12 AM" |
| yesterday | "Yesterday, 6:03 PM" |
| within the 6 calendar days before today | "Mon, 4:05 PM" |
| this year | "Jun 12, 8:30 AM" |
| older | "Mar 3, 2024" |

- Calendar-day logic handles daylight saving changes.
- Tooltip is `dateStyle full, timeStyle medium`.
- **Refresh clock** (`R/lib/relativeClock.ts`): "now" is rounded to the minute. A minute timer runs only while a date under an hour old is on screen and the window is visible, plus a timer at midnight; both are refreshed when the window regains focus or visibility (50 ms slack).

### 6.2 Sizes (`formatting.ts:83-103`)
- Decimal units: 1 KB = 1000 B.
- "N B"; one decimal under 9.95, otherwise whole numbers; units KB, MB, GB, TB, PB.
- Steps up a unit when the rounded value reaches 1000.
- Missing values: "Unavailable" / "Not yet available".
- Folder sizes: "1.2 GB (1.3 GB on disk)" plus "48,611 files, 2,765 folders" or "Empty" (`:221-248`).

### 6.3 Permissions
- Octal code; symbolic form in the tooltip.
- Info panel says "Read & Write", "Read only", "Write only" or "No access" (`GetInfoPanel.tsx:711-725`).

### 6.4 Status text (`R/lib/statusSummary.ts`)
- Folder view:
  - "240 items", or "3 of 240 items" while filtered
  - "2 of 240 selected"
  - then " · size" (selection size or folder size) or " · Calculating…"
- Search: "Searching… 12 results · 2 selected · 1.2 MB" (`R/lib/searchResults.ts:63-90`).

### 6.5 Tooltip wording (`R/lib/tooltips.ts`, `R/lib/titleTooltips.ts`)
- "Label (⌘K)".
- Toggles describe the action: "Show/Hide Hidden Files", "List Folders First" / "Mix Files and Folders", "Show/Hide Folder Tree", "Show/Hide Info Panel", "Show/Hide Info Row".
- Edit is "Edit in <Editor>".

---

## 7. Help, About and Acknowledgements

### 7.1 Help window
- 900×680, min 560×420 (`M/main.ts:534-542`).
- **Layout** (`R/HelpWindowApp.tsx`, `R/components/HelpView.tsx`, `R/styles.css:4142-4375, 4851-4882`):
  - Sidebar 208 px (188 when narrow) with a "Search help" field and topic buttons (28 tall; the current one gets an accent icon and semibold text).
  - Content column max 720, padding `22 28 36`; 52 px top drag strip.
  - Responsive: wide ≥1100, narrow ≥760, otherwise compact with topics wrapping on top (`R/lib/responsiveLayout.ts`).
- **Content** (`R/lib/helpContent.ts`): topics → sections → rows (label or `code`, description), plus an optional note in an accent-soft box.
  - `{commandId}` in text becomes the command's current key, or its menu path.
- **Topics:**
  - **Getting around:** Folders, Tabs, Windows, Path bar, Keyboard.
  - **Working with files:** Opening, Copying and moving, Changing, Undo and Redo, "Undo and Redo: if something has changed since".
  - **Searching:** Plain Text, Glob patterns, Regex patterns, Upper and lower case, Matching the full path, Options, Results.
  - **Views and panels:** The list, Information, Appearance.
  - **Keyboard shortcuts:** every shortcut in two columns, grouped by topic.
    - Keycaps are 21 px tall with min width 22 and radius 6.
    - A second key is described as "(⌘← also works)".
    - "Customize…" opens Settings → Shortcuts.
    - Source: `SHORTCUT_ITEMS`, `:54-214`.
- **Search** over rows and shortcuts; empty result: "Nothing in Help matches. Try a shorter or different word."
- **Navigation:** the window opens on the last or requested topic (`#help/<topic>`).

### 7.2 About window (`R/AboutWindowApp.tsx`; `R/styles.css:5081-5150`)
- Fixed 460×356 scaled by zoom; not resizable (`M/main.ts:567-591`).
- 40 px drag strip.
- Header: 72 px app icon, "File Trail" 20 px semibold, tagline "A file browser that stays out of your way."
- Detail rows (12 px, hairlines): Version "0.1.0 (commit)", macOS "ver, arch", Electron, Search "fd x".
- Buttons: Copy Details ("Copied" for 1.5 s; text from `S/aboutInfo.ts:18-25`), GitHub, Report an Issue (styled as push buttons).
- Footer: "Acknowledgements" link and "© 2026 Mustafa Demirhan".
- Esc closes.

### 7.3 Acknowledgements window (`R/AcknowledgementsWindowApp.tsx`)
- 620×640, min 460×360.
- Centred title bar "Acknowledgements"; intro paragraph.
- Disclosure list: name, version, and license on the right.
- Expanded entry: URL link, then either a monospace license box (max 300 tall) or an "Open License Notices" button.
- Esc closes.
- **Native:** NSOutlineView or disclosure views.

---

## 8. Navigation

### 8.1 History (`R/hooks/useExplorerNavigationController.ts:315-768`)
- Per tab: a list of paths plus an index.
- **push** truncates forward entries and appends; **replace** overwrites the current entry; **skip** is used by Back, Forward and history jumps.
- No explicit history cap.
- Back/Forward/jump restore the folder's **saved view**: selection and scroll position. Memories are kept only for folders still in the history (`R/lib/folderViewMemory.ts`).
- Changing the sort reloads with "replace".
- Hold menus: last 12 entries each way (§3.7).

### 8.2 Tabs (`R/hooks/useExplorerTabs.ts`, `R/lib/explorerTabs.ts`)
- **Per-tab snapshot:**
  - path, history, view mode and search view mode, sort, tree root, selected sidebar item, sidebar subview, focused pane
  - includeHidden, foldersFirst, favorites/locations expanded
  - view state: tree nodes, entries, metadata, selection, list filter, scroll positions, folder memories
  - search session (keeps running in the background, polled)
- **Max 100 tabs** per window; over the limit the toast "A window can have up to 100 tabs" appears (`useExplorerTabs.ts:397-415`; `S/appPreferences.ts:97`).
- **⌘T:** new tab on the current folder, with its own history.
- **Closing:** the tab to the right becomes active, or the left one if it was last; closing the last tab closes the window.
- **Reopen Closed Tab:** the last 10, not saved across launches; reopened tabs keep folder, root and view only (`explorerTabs.ts:236-249`).
- **Duplicate tab** copies folder, tree, history and view; not the search.
- **Move Tab to New Window, Merge All Windows**, ⌃Tab cycling with wraparound.
- **Background tabs:** follow folders renamed or moved; go Home when their disk is unmounted (`explorerTabs.ts:331-396`).

### 8.3 Startup (`R/lib/startupNavigation.ts`)
- A folder the OS launched the app with always wins: it gets its own tab, or an existing tab on that path is activated.
- With "Reopen the last folder and tabs" on: restore `openTabs` and `activeTabIndex`. Each tab's tree root is kept if the folder is inside it, otherwise home (if inside home) or the volume root.
- Otherwise: one tab at home, tree rooted at home.

### 8.4 Favorites and places
- Default favorites: §1.4.
- Reorder by dragging in the sidebar or in the Settings list; icon chosen from 23 options.
- The Trash cannot be added (it is always under Locations); a Trash favorite can only be removed.
- **Go menu places** (`R/lib/goMenuPlaces.ts`):
  - Documents, Desktop, Downloads, Library (in home)
  - Home (also roots the tree)
  - Macintosh HD and Trash (as Locations rows)
  - /Applications

### 8.5 Visited-folder ranking for Go To (`S/visitedFolders.ts`, `R/lib/folderVisitTracker.ts`, `R/lib/places.ts`)
- **Visit kinds:**
  - `goTo` (picked in Go To): weight 3, counts immediately.
  - `stay`: weight 1; counts after **5 s** on screen, or when something is done in the folder.
  - `passThrough` (left sooner): only makes the folder known.
- **Recency weights:** ≤4 days 1.0; ≤14 days 0.7; ≤31 days 0.5; ≤90 days 0.3; older 0.1.
- **Score:** sum of weight × recency over the last 10 visits per folder; up to 500 folders; the lowest scores are evicted.
- **Places list:** visited folders plus favorites, minus the current folder.
- **Matching** (each typed word must match):
  - name prefix (5) > word-start (4) > substring (3) > scattered letters starting at index 0 (2) > path-only (1)
  - sort by match quality, then score, then favorite
  - up to 50 results
- **Display:** paths shown with home as `~`; the row shows the place's parent folder (`describePlaceLocation`).
- **Forget:** ⌘⌫ removes a visited folder; folders that no longer exist are dropped automatically (`R/App.tsx:2166-2180`).

---

## 9. Other timings and constants
- Tree single-click delay 180 ms; path-bar segment click delay 320 ms; tree typeahead reset 1000 ms; list-filter Space window 1000 ms.
- Delays before showing:
  - "Loading…": folder 400 ms, tree 400 ms, path-bar menu 300 ms
  - Info spinner 300 ms; folder-size spinner 300 ms
  - search Stop button 400 ms; progress card 500 ms
- Drag and drop (`R/hooks/useExplorerDragAndDrop.ts:52-62`):
  - spring-load 700 ms, wiggle warning 625 ms, rest tolerance 3 px
  - tab hover switch 700 ms
- Overlay scrollbars linger 1000 ms after scrolling (`R/lib/scrollbarVisibility.ts`).
- Toolbar reorder slide 180 ms, flash 900 ms; clipboard flash 700 ms.

## 10. Notes for the native rewrite
- **Typing filters the list** instead of jumping to a match (unlike Finder), with a floating pill. Keep this.
- **Return renames by default** (setting). ⌘O / ⌘↓ open; Space is Quick Look.
- **Context menus hide items** that don't apply rather than dimming them; only Paste may be dimmed.
- **One write operation at a time across all windows;** while one runs, write commands are locked.
- **Whole-UI zoom** needs a global scale for fonts, metrics and window sizes (the About window size is scaled too).
- **Accent can be any hex,** so system selection and accent drawing can't be used; derive the colours as in §5.6.
- **Window-inactive state** turns every selection gray.
