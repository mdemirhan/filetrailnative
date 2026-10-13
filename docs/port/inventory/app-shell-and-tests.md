# File Trail (Electron/TS): app shell, state, menus, IPC and tests for the Swift/AppKit port

**Repo root:** `/Users/tcmudemirhan/src/tsproj/filetrail`. Citations below are `file:line` relative to that root. Main files read:
- `/Users/tcmudemirhan/src/tsproj/filetrail/apps/desktop/src/main/{main,bootstrap,appMenu,applicationMenuSync,appStateStore,explorerWindows,explorerWindowController,windowIpcHandlers,pageWindows,quitWhileBusy,settingsWindowTab,aboutInfo,appLog,logRotation,launchContext,ipc,diskImages,rendererProtocol,fdBinary}.ts`
- `/Users/tcmudemirhan/src/tsproj/filetrail/apps/desktop/src/shared/{appPreferences,applicationMenuState,rendererCommands,shortcuts,toolbarItems,visitedFolders,diskImages,aboutInfo}.ts`
- `/Users/tcmudemirhan/src/tsproj/filetrail/packages/contracts/src/ipc.ts`
- `/Users/tcmudemirhan/src/tsproj/filetrail/apps/desktop/src/preload/index.ts`
- `/Users/tcmudemirhan/src/tsproj/filetrail/apps/desktop/scripts/{build.ts,make-macos-app.sh,entitlements.mac.plist,release.ts,thirdPartyLicenses.ts,build-app-icon.sh,start.sh,runVitest.ts,lib/version.ts}`
- `/Users/tcmudemirhan/src/tsproj/filetrail/.github/workflows/ci.yml`
- Also useful: `/Users/tcmudemirhan/src/tsproj/filetrail/docs/{MULTI_WINDOW_PLAN,UNDO_PLAN,FILE_OPERATION_RISKS,ARCHITECTURE_LOG,ENGINEERING_RULES}.md`

**Findings that matter for the port**
- **One table drives every shortcut.** `shared/shortcuts.ts` feeds the menu keys, the window key handler, tooltips, Help and Settings. Users can rebind keys, and only overrides are saved.
- **Two kinds of state.**
  - App-wide preferences, persisted.
  - Per-window "session" keys: 22 keys, each window keeping its own. Every change in a window also becomes the app-wide latest value.
- **Persistence:** one JSON file plus a sibling visits file. Writes are atomic (`.tmp` then rename). Deliberate changes save after 150 ms; navigation-type changes wait up to 5 min or until quit.
- **Window model:** Finder-like.
  - Closing the last window leaves the app running.
  - Clicking the Dock icon with no windows reopens one where the last window closed.
  - The Dock menu has one item, New Window.
  - Merge All Windows, Move Tab to New Window, and a "stop the operation?" question before quitting or closing the last window while a write runs.
- **IPC surface:** 80 request/response channels plus 14 push events from main to the windows. This becomes the Swift service API.
- **Bundle id** `com.filetrail.desktop`, arm64 only. The only document type is Disk Image (`com.apple.disk-image`, role Viewer, rank Alternate). Version comes from git tags.
- **Tests:** about 3,366 Vitest cases in 249 files, plus 31 Playwright e2e cases in 8 specs.
- **Gaps an exact port would copy** (worth deciding on):
  - `open-file` ignores everything except disk images, so a folder dropped on the Dock icon or opened with `open -a "File Trail" /path` while the app runs does nothing.
  - `second-instance` ignores its arguments and only brings a window forward.
  - The launch folder is read from argv only (`--folder` or the first positional argument).

---

## 1. Application menu tree

Built by `createApplicationMenuTemplate` (`apps/desktop/src/main/appMenu.ts:97-391`).
- The menu is rebuilt whenever Undo/Redo labels change, shortcuts change, or the text editor changes (`main.ts:247-253`, `applicationMenuSync.ts:127-136`).
- Enabled, checked and visible states are patched in place by `resolveApplicationMenuItemStates` / `applyApplicationMenuItemStates` (`appMenu.ts:417-538`).
- Each command item's `id` is the renderer command type; clicking sends `filetrail:command {type}` to the target explorer window (`appMenu.ts:156`).
- Keys:
  - "(rebindable)": comes from `DEFAULT_SHORTCUT_BINDINGS` (`shortcuts.ts:41-534`).
  - "fixed": never rebindable (`shortcuts.ts:503-533`).
  - The menu shows only a command's first key that includes ⌘ or ⌃ (`shortcuts.ts:1091-1093`, `appMenu.ts:160-166`). Keys like Space, F2 and ? belong to the window's key handler.

### File Trail (`appMenu.ts:193-217`)
| Item | Key | Notes |
|---|---|---|
| About File Trail | — | Opens the custom About window (`main.ts:579-594`). Falls back to `role: about`. |
| Settings… | ⌘, (fixed) | Opens the Settings window (`main.ts:477-519`). |
| Empty Trash… | ⇧⌘⌫ | Command `emptyTrash`. |
| Services | — | role |
| Hide File Trail | ⌘H (fixed) | role |
| Hide Others | ⌥⌘H (fixed) | role |
| Show All | — | `role: unhide` |
| Quit File Trail | ⌘Q (fixed) | Goes through `before-quit`, then the controller's `quit()`. |

### File (`appMenu.ts:218-256`)
| Item | Key |
|---|---|
| New Window | ⌘N |
| New Tab | ⌘T |
| New Folder | ⇧⌘N |
| Open | ⌘O (alternate ⌘↓ via `openSelectedItem`, window only) |
| Open in New Tab | — |
| Open in New Window | — |
| Edit in `<TextEditorName>` (default "TextEdit") | ⇧⌘E |
| Quick Look | Space (window only, not in the menu) |
| Reveal in Folder | — (search results only) |
| Calculate Size | — |
| Rename | F2 (window only; Return also renames per `returnKeyAction`) |
| Duplicate | ⌘D |
| Move to… | ⇧⌘M |
| Add to Favorites / Remove from Favorites | — (two items `toggleFavorite:add` / `:remove`, one visible at a time) |
| Open in Terminal | ⌥⌘T |
| Show in Finder | — |
| Move to Trash | ⌘⌫ |
| Eject | ⌘E |
| Reopen Closed Tab | ⇧⌘T |
| Close Tab | ⌘W (closes the window when it has one tab) |
| Close Window | ⇧⌘W (fixed, `role: close`) |

### Edit (`appMenu.ts:257-297`)
- **Undo / Redo:** ⌘Z / ⇧⌘Z (fixed).
  - Four items: the files' Undo/Redo, labelled "Undo Move of "a.txt"" or "Can't Undo", plus hidden plain text-field Undo/Redo (`undo:text`, `redo:text`).
  - `acceleratorWorksWhenHidden: false`.
  - Labels come from `undoMenuLabels` (`appMenu.ts:403-414`).
- **Cut / Copy / Paste:** ⌘X / ⌘C / ⌘V (fixed).
- **Copy Path:** ⌥⌘C.
- **Select All:** ⌘A (fixed).
- **Show Clipboard / Clear Clipboard:** no key.
- **Find Files…:** ⌘F.
- **Show Last Search Results:** ⇧⌘F.

### View (`appMenu.ts:298-343`)
- **as Icons / as List / as Compact List:** radio, ⌘1 / ⌘2 / ⌘3. Ids: `viewAsIcons`, `viewAsDetails`, `viewAsList`. "details" is the table.
- **Sort By ▸ Name / Kind / Date Modified / Size:** radio, no keys.
- **Folders First:** checkbox.
- **Hidden Files:** checkbox, ⇧⌘.
- **Refresh:** ⌘R.
- **Hide Folder Tree / Show Folder Tree:** ⌃⌘S, one visible at a time.
- **Info Panel:** checkbox, ⌘I.
- **Info Row:** checkbox, ⇧⌘I.
- **Customize Toolbar…**
- **Zoom In / Zoom Out / Actual Size:** ⌘+ / ⌘- / ⌘0. Zoom range is 75–150% (`appPreferences.ts:133-134`).
- **Full screen:** hidden `role: togglefullscreen` item keeping ⌃⌘F. macOS adds its own Enter Full Screen.
- **Toggle Developer Tools:** development builds or `FILETRAIL_OPEN_DEVTOOLS=1` only (`main.ts:674`).

### Go (`appMenu.ts:344-365`)
- Back ⌘[ (alt ⌘←); Forward ⌘] (alt ⌘→); Enclosing Folder ⌘↑.
- Documents, Desktop, Downloads: no keys.
- Home ⇧⌘H.
- Library, Macintosh HD, Applications, Trash: no keys.
- Go to Folder… ⌘K (alt ⇧⌘G).
- Use as Tree Root ⇧⌘R.

### Window (`role: windowMenu`, `appMenu.ts:366-381`)
- Minimize ⌘M (fixed) and Zoom.
- Show Previous Tab: ⌃⇧Tab, alt ⇧⌘[ (the menu shows ⇧⌘[ because ⌃⇧Tab… actually both qualify; the first is shown).
- Show Next Tab: ⌃Tab, alt ⇧⌘].
- Move Tab to New Window; Merge All Windows.
- Bring All to Front (`role: front`). macOS appends the window list.

### Help (`role: help`, `appMenu.ts:382-389`)
- **File Trail Help:** "?" (window only; not representable as a menu accelerator, `shortcuts.ts:1100`).
- **Keyboard Shortcuts:** opens the Help window on the `shortcuts` topic.

### Window-only shortcut commands (not in the menu)
`focusTreePane`, `focusContentPane` (no defaults), `pageUp`/`pageDown` (PageUp/PageDown), `halfPageUp`/`halfPageDown` (⌃U/⌃D), `openSelectedItem` (⌘↓) (`shortcuts.ts:142-153, 235`). There are 72 renderer command types in total (`rendererCommands.ts:1-76`).

### Shortcut rules (`shortcuts.ts`)
- **Format:** "Ctrl+Cmd+Option+Shift+Key" (`:5-7`). At most 2 keys per command (`:552`).
- **Saved form:** only overrides, in `shortcutOverrides` (`:541-543`, `:979-993`).
- **Resolution order** (`:925-974`): fixed commands claim their keys first, then customized commands, then the remaining defaults. A key claimed twice goes to the command it was explicitly given to.
- **Refusals** (`:866-898`):
  - Typing keys without ⌘ or ⌃.
  - Motion keys without a modifier.
  - Keys of fixed commands.
  - ⌘. (cancels dialogs).
  - Reserved macOS keys (`:814-836`).
  - Keys macOS uses by default unless switched off: ⌃arrows, F11 (`:839-841`).
- **Text fields:** shortcuts that would edit text are left to a focused field (`:846-860`).

### Enable/disable rules
Main process (`appMenu.ts:417-512`):
- **No explorer window focused:**
  - With zero explorer windows, or no window focused at all, only `COMMANDS_WITHOUT_EXPLORER_WINDOW` stay enabled: newWindow, the Go places, Go to Folder (`appMenu.ts:45-56`). Choosing one makes the host open a window (`main.ts:681-685`).
  - With another window focused (e.g. Settings), only `COMMANDS_FOR_ANY_WINDOW` stay enabled: undo, redo, cut, copy, paste, selectAll, closeTab, newWindow (`appMenu.ts:32-41`).
  - In that case edit commands act natively on the focused window's text field, ⌘W closes that window, and New Window opens beside the front explorer (`appMenu.ts:142-155`).
- **Explorer focused:**
  - Disabled if listed in the window's reported `disabledCommands`.
  - `mergeAllWindows` needs more than one explorer window.
  - The files' Undo/Redo are enabled only when history has an entry.
  - Text Undo/Redo are visible while `textEditing` is true or the explorer is not focused.
- **Checkmarks** (`appMenu.ts:457-469`): viewMode, sortBy, foldersFirst, hiddenFilesShown, infoPanelOpen, infoRowOpen. Radio items are only ever switched on (`:529-536`).
- **Default menu state before a window reports:** `INITIAL_APPLICATION_MENU_STATE` (`applicationMenuState.ts:22-33`).

Which window the menu acts on (`applicationMenuSync.ts:109-181`):
- The focused explorer window.
- Otherwise the front explorer while another app window has focus.
- With no window focused, the front explorer only while it is visible and not minimized.

Window-side rules (`apps/desktop/src/renderer/lib/rendererCommandAvailability.ts:20-266`):
- **While a write is running:** undo, redo, paste, move, rename, duplicate, newFolder, trash and emptyTrash are blocked (`:20-31`).
- **open / edit:** limited to `openItemLimit` items (default 5). Edit requires every item to be an editable file.
- **trash / duplicate:** not for items already in the Trash. Duplicate in search mode requires a single parent folder.
- **emptyTrash:** unless the Trash is known to be empty.
- **eject:** needs an eject target.
- **paste:** needs clipboard items and a destination.
- **showClipboard / clearClipboard:** need clipboard items.
- **revealInFolder:** search mode with a selection only.
- **toggleFavorite:** needs a target folder that isn't the Trash.
- **sort\* / toggleFoldersFirst:** disabled in search mode.
- **goBack / goForward:** follow the history.
- **goEnclosingFolder:** needs a parent folder.
- **selectNextTab / selectPreviousTab / moveTabToNewWindow:** need more than one tab.

The window reports its state with `app:setMenuState`; `bootstrap.ts:359-365` feeds `ApplicationMenuSync.setWindowState`. Undo-history changes refresh the menu once per tick via `setImmediate` (`applicationMenuSync.ts:79-89`). Focus and blur of any window trigger a refresh (`main.ts:93-99`).

### Dock menu
A single item, "New Window", which calls `explorerWindows.openNewWindowFromFront()` (`main.ts:259-263`).

---

## 2. App state persistence

### Files (all under Electron `userData`)
No `setName` or `setPath` call exists, so this is `~/Library/Application Support/@filetrail/desktop/` (per the comment at `appMenu.ts:25-26`; tests and e2e pass `--user-data-dir`).

| File | Purpose | Source |
|---|---|---|
| `app-state.json` | Preferences, windows, last closed window. Pretty JSON (2-space) plus newline. | `appStateStore.ts:456-458`, `:417` |
| `visited-folders.json` | Go To ranking: `{"folders":[` one JSON object per line `]}`, each visit stored as `[epochMs, kind]` | `appStateStore.ts:461-463`, `visitedFolders.ts:103-111` |
| `replace-journal.json` | Write journal for crash recovery of Replace operations | `bootstrap.ts:227-232` |
| `logs/app.log` (+ `app.1.log` … `app.9.log`) | Log | `appLog.ts:25-27` |

`app-state.json` shape (`appStateStore.ts:65-72`):
- `{ preferences?, windows?: StoredExplorerWindow[] (front to back), lastClosedWindow? }`
- `StoredExplorerWindow = { id, bounds: {x?, y?, width, height, maximized}, session: WindowSession }` (`:45-60`).

### Writing
- **Atomic:** write `path.tmp`, then rename (`appStateStore.ts:532-546`). Read errors fall back to defaults and never block startup (`:470-510`).
- **Two debounce tiers** (`appStateStore.ts:117-139`, `:192-217`, `:425-446`):
  - **Prompt (150 ms, restarted on each change):** any change to a key outside `NAVIGATION_PREFERENCE_KEYS`, and `forgetVisitedFolder`.
  - **Deferred (5 min, not pushed back by later changes):** these navigation keys: lastVisitedPath, lastVisitedFavoritePath, treeRootPath, openTabs, activeTabIndex, viewMode, searchViewMode, sortBy, sortDirection, searchResultsSortBy, searchResultsSortDirection. Also folder visits, window add/remove/order/bounds, and `lastClosedWindow`.
  - A prompt save also writes any pending deferred data.
- **Dirty tracking:** only files with changes are rewritten (`unsavedFiles`, `:396-423`).
- **On quit:** `flush()` runs before and after `shutDown` (`explorerWindowController.ts:525-529`).
- **Window bounds:** debounced 160 ms on move/resize/maximize/unmaximize/leave-full-screen, and recorded on close (`explorerWindowController.ts:134, 626-699`). Normal (non-zoomed) bounds are stored; `maximized = isMaximized && !isFullScreen`.
- **Window side:** the window debounces preference writes by 300 ms (`renderer/hooks/usePreferencesSync.ts:10`).

### Preference keys and defaults
Defaults are in `appPreferences.ts:390-448`; types in `:281-350`; sanitizing in `appStateStore.ts:617-844`. The IPC schema (`contracts/ipc.ts:724-788`) also bounds them.
- **Theme and look:** `theme:"auto"` (auto/light/dark); `accent:"#007aff"` (6-digit hex, 9 presets `:120-130`); `zoomPercent:100` (75–150).
- **View:** `viewMode:"icons"`; `searchViewMode:"details"`; `sortBy:"name"`; `sortDirection:"asc"`; `foldersFirst:true`.
- **Compact views (all false):** `compactListView`, `compactDetailsView`, `compactIconView`, `compactTreeView`; also `singleClickExpandTreeItems:false`.
- **Columns:**
  - `detailColumns` {modified, size, kind: true; created, permissions: false}.
  - `detailColumnOrder` [modified, size, kind, created, permissions] (Name is always first).
  - `detailColumnWidths` {name 320, modified 152, size 108, kind 148, created 152, permissions 108}, clamped per column (`:186-193`).
  - `searchColumns` {folder, modified, size: true; kind, created, permissions: false}.
  - `searchColumnOrder` [folder, modified, size, kind, created, permissions].
  - `searchColumnWidths` {name 300, folder 240, others as the detail widths}; folder clamp 80–720 (`:214-235`).
  - Saved orders are normalized: unknown or duplicate keys are dropped and new columns appended (`:471-487`).
- **Behaviour switches:** `notificationsEnabled:true`; `markClipboardItems:true`; `autoCalculateFolderSizes:true`.
- **Panels:** `folderTreeOpen:true`; `propertiesOpen:false` (Info panel); `detailRowOpen:false` (Info row).
- **Toolbar:** `topToolbarItems` = [folderTree, topSeparator, back, forward, title, clipboard, view, sort, search, viewOptions, infoPanel] (`toolbarItems.ts:408-420`).
  - Sanitizing drops unknown or duplicate items (only `topSeparator` may repeat).
  - It appends any missing required item: title, clipboard, viewOptions, search (`:439-473`).
  - 37 item ids exist (`:55-92`); palette order is at `:478-512`.
- **Apps:** `terminalApp:null` (Terminal.app is used when null); `defaultTextEditor` {/System/Applications/TextEdit.app, "TextEdit"}; `openWithApplications:[]` (pinned apps, `{id, appPath, appName}`).
- **Actions:** `fileActivationAction:"open"` (open|edit); `diskImageOpensIn:"window"` (window|tab); `returnKeyAction:"rename"` (rename|open).
- **Shortcuts:** `shortcutOverrides:{}`.
- **Open limit:** `openItemLimit:5` (1–50).
- **Search:** `includeHidden:false`; `searchPatternMode:"text"` (text/glob/regex); `searchMatchScope:"name"`; `searchRecursive:true`; `searchSkipGitFolders:true`; `searchSkipGitIgnored:false`; `searchResultsSortBy:"path"` (name/path/kind); `searchResultsSortDirection:"asc"`.
- **Pane widths:** `treeWidth:280` (220–520); `inspectorWidth:320` (260–480).
- **Session:** `restoreSessionOnStartup:true`.
  - `openTabs:[]`, max 100 (`OPEN_TABS_LIMIT`). Each tab is {path, treeRootPath, favoritePath, viewMode, searchViewMode, sortBy, sortDirection, includeHidden, foldersFirst, favoritesExpanded, locationsExpanded} (`appPreferences.ts:80-97`).
  - `activeTabIndex:0`; `treeRootPath:null`; `lastVisitedPath:null`; `lastVisitedFavoritePath:null`.
- **Favorites:** `favorites:[]` as {path, icon}, 23 icon ids (`:49-72`, `:243-267`), de-duplicated by path (`appStateStore.ts:846-884`).
  - `favoritesPlacement:"integrated"` (or separate); `favoritesExpanded:true`; `locationsExpanded:true`; `favoritesInitialized:false`.
  - On first run the window seeds /Applications, ~/Desktop, ~/Documents, ~/Downloads and sets `favoritesInitialized` (`renderer/lib/favorites.ts:119-129`, `renderer/App.tsx:1906`).
- **Batch rename:** `batchRenameSettings` = `DEFAULT_BATCH_RENAME_SETTINGS` (`shared/batchRename.ts:92-115`).
  - `batchRenamePresets:[]` as {name ≤80 chars, case-insensitively unique, settings}, max 50 (`batchRename.ts:117`, `:205-211`). Presets live inside `preferences`.

### Window session keys vs app-wide keys
- **The 22 session keys** (`appPreferences.ts:357-380`): openTabs, activeTabIndex, treeRootPath, lastVisitedPath, lastVisitedFavoritePath, viewMode, searchViewMode, sortBy, sortDirection, searchResultsSortBy, searchResultsSortDirection, includeHidden, foldersFirst, favoritesExpanded, locationsExpanded, folderTreeOpen, propertiesOpen, detailRowOpen, treeWidth, inspectorWidth, detailColumnWidths, searchColumnWidths.
- **`updateWindowPreferences`** (`appStateStore.ts:261-285`) writes every key app-wide and the session keys into the window record. A new window starts from the app's latest values (`createWindowSession`, `:288-292`).
- **Reads:** explorer windows read app preferences merged with their session (`getWindowPreferences`, `:252-255`). Non-explorer windows such as Settings get app-wide preferences only (`windowIpcHandlers.ts:134-139`).
- **Broadcast:** only non-session keys are broadcast to other windows as `filetrail:preferencesChanged` (`windowIpcHandlers.ts:153-156`, `main.ts:225-243`).
- **Side effects of a change:** a zoom change sets every window's zoom factor and resizes About; a theme change sets `nativeTheme.themeSource`; a shortcut or editor change rebuilds the menu.
- **Window ids** are `window-<uuid>` (`main.ts:363`).
- **`lastClosedWindow`** is the window closed last, keeping only its front tab (`appStateStore.ts:318-334`). It is not recorded for merged windows or while quitting (`explorerWindowController.ts:681-686`).

### Migration and damaged-file handling (`appStateStore.ts:470-510, 1021-1098`)
- **Legacy single-window file** (no `windows` array): becomes one window `id:"window-1"`, bounds from top-level `window`, session from the preferences.
- **`lastClosedWindow` present but `windows` missing:** windows = [] and one window opens as the last closed one did.
- **Damaged windows:** entries with a duplicate or empty id are dropped; at most 50 windows are read (`STORED_EXPLORER_WINDOWS_LIMIT`, `:63`). `activeTabIndex` is clamped to the last tab (`:1075-1077`).
- **Old tabs** without `favoritesExpanded`/`locationsExpanded`, or without per-tab `includeHidden`/`foldersFirst`, inherit the window's value (`:556-614`).
- **Bounds:** width and height must be 320–6000, else the default 1200×760; x and y are optional (`:1079-1098`).
- **Other values:** every key falls back to its default when invalid. Shortcut overrides, toolbar items, rename settings and presets each go through their own sanitizers.

### Visited folders (`shared/visitedFolders.ts`)
- **Visit kinds:** `goTo` (weight 3), `stay` (weight 1), `passThrough` (makes the folder known, adds no visit).
- **Limits:** at most 500 folders and 10 visits per folder.
- **Recency weights:** 1 / 0.7 / 0.5 / 0.3 / 0.1 at ≤4 days, ≤14 days, ≤31 days, ≤90 days, older (`:37-58`). Over the folder limit, the lowest-scoring folders are evicted.
- **Lenient reading:** paths must be absolute (`:114-158`).
- **When recorded:** a stay counts after 5 s (`renderer/lib/folderVisitTracker.ts:5`).

---

## 3. Window lifecycle

### Launch (`main.ts:68-288`)
1. `requestSingleInstanceLock()`; quit if not obtained (`:68, :83-85`).
2. Register the `filetrail://app` scheme as standard, secure, with code cache (`rendererProtocol.ts`).
3. Clear Electron's default menu (`:90`).
4. `whenReady`:
   - Create the logger and install the uncaughtException/unhandledRejection handlers.
   - Resolve the startup folder from argv (`launchContext.ts`).
   - Create the state store and the controller.
   - Apply the native appearance.
   - Run `bootstrapMainProcess`: worker, volume watcher, disk-image opener, folder watches, write-journal recovery, undo history, write coordinator, all IPC handlers.
   - Build the menu and set the Dock menu.
   - `openStartupWindows(startupFolderPath)`, then open any queued `open-file` disk images and show crash-recovery notices after load (`:739-760`).

**Startup folder** (`launchContext.ts:13-97`): `--folder <p>` / `--folder=<p>`, else the first positional argument that isn't the app path. `~` is expanded and the path must be a directory.

### Restoring windows (`explorerWindowController.ts:213-263`)
- With `restoreSessionOnStartup`, all stored windows are restored; otherwise only the first. Dropped records are removed from the store.
- With none stored, one window opens from `lastClosedWindow`.
- Windows are created hidden. The launch folder goes to the front window.
- Windows are shown back to front once all are `ready-to-show`, or after 5 s. Maximized windows are re-maximized. The front window uses `show()`, the others `showInactive()`.
- **Explorer window options** (`main.ts:401-447`):
  - Size and minimum: min 760×480, `title:"File Trail"`.
  - Appearance: `vibrancy:"sidebar"`, `visualEffectState:"followWindow"`, transparent background.
  - Title bar: `titleBarStyle:"hiddenInset"`, traffic lights at (14,16).
  - Web preferences: sandbox, contextIsolation, no Node integration.

### New window variants
- **`openDefaultWindow(initialCommand?)`** (`:268-281`): with no window open (Dock click, Go menu with no window). Uses the last closed window's bounds and front tab, then runs the initial command (e.g. a Go place) once loaded via `app:getLaunchContext`.
- **`openNewWindowFromFront()`** (`:286-300`): Dock menu, or ⌘N while Settings is focused. Opens on the front window's active tab.
- **`openWindowFrom(senderId, tabs, activeIndex)`** (`:305-331`): New Window, Open in New Window and Move Tab to New Window, all via `app:openWindow`.
  - Copies the source window's session and its normal bounds.
  - Placed by `placeNewWindow`: +22 px down and right, wrapping to the work area's top-left (`explorerWindows.ts:76-91`).
- **Window order:** front to back, kept in `ExplorerWindowList`; focus moves a window to the front and persists the order (`explorerWindowController.ts:665-669`).

### Closing
- **Last explorer window closed:** the app stays open (`main.ts:306`).
  - The closed window is remembered as `lastClosedWindow` and removed from `windows` (`explorerWindowController.ts:671-688`).
  - ⌘W on a window's last tab goes through `app:closeWindow`, which closes the window like its close button (`:464-471`).
- **Dock click** (`app.on("activate")`, `main.ts:275-282`; `explorerWindowController.ts:489-502`): with 0 explorer windows and not quitting, open the default window. If no window is visible, restore and focus the front one.
- **Second instance** (`main.ts:325-330`): `bringToFront()`, which restores and focuses the front window or opens a default one. Argv is ignored.

### Quitting, and closing while busy (`quitWhileBusy.ts`, `explorerWindowController.ts:507-531, 712-808`)
- `before-quit` is always prevented and routed to `controller.quit()`. A second ⌘Q while the question is open brings the question forward.
- If a window is open and a write runs, a warning dialog asks with "Keep Working" (default and cancel) and "Stop and Quit". For `empty_trash` the button reads "Quit".
- Per-kind messages (`quitWhileBusy.ts:35-89`):
  - copy, move, trash, delete, undo, batch_rename: each has its own message and detail.
  - empty_trash: asks on quit only.
  - rename and new_folder: never asked; they are short and just awaited.
- **After agreeing:**
  1. Set `shuttingDown`.
  2. Record all bounds and flush the store.
  3. `shutdownMainProcess()`: stop watchers, wait for the write coordinator, close the worker.
  4. Flush the logger.
  5. Record bounds and flush again.
  6. `app.exit(0)`.
- **Closing the last window during a write:** close is held and the same question appears with "Stop and Close" (`holdClose`, `:715-742`). After Stop, the operation is not handed to another window (`stoppedOnClose`).
- **Closing a window that has other windows open:** the operation is handed to a successor window, preferring one whose page has loaded (`successorOf`, `:452-460`). The successor receives `filetrail:writeOperationAdopted`.

### Merge All Windows (`explorerWindowController.ts:340-376`, `windowIpcHandlers.ts:58-101`)
1. The asking window calls `app:mergeAllWindows {tabCount}`.
2. Main sends `filetrail:mergeRequest {requestId}` to each other window. Each answers `app:answerMergeRequest {tabs, busy}`, with a 2 s timeout.
3. Windows that don't answer, are busy (sheet, dialog, inline edit), or whose tabs don't fit within 100 tabs stay open.
4. The others are closed without asking and are not remembered as last closed.
5. One merge runs at a time, and none while quitting.

### Move tab to new window
The window calls `app:openWindow` with the one tab and removes it locally; `moveTabToNewWindow` is enabled only with more than one tab.

### Opening files from Finder or `open -a`
- **`app.on("open-file")`** (`main.ts:312-323`) handles disk images only (`isDiskImagePath`: dmg, udif, img, toast, dvdr, cdr, dmgpart, iso, sparseimage, asif, sparsebundle, backupbundle; `shared/diskImages.ts:4-23`). Paths are queued until the startup windows exist.
- **`openDiskImageFromOtherApp`** (`main.ts:336-354`):
  - With a front window: it queues the path, sends `filetrail:openRequestsWaiting`, and the window pulls the path via `app:takeOpenRequests` (`explorerWindowController.ts:399-446`).
  - With no window: the image is mounted in main and `openWindowOnFolder(volumePath)` runs. Failures show a standalone warning built by `describeDiskImageFailure`.
- **Mounting** (`main/diskImages.ts`): `hdiutil isencrypted`, then `imageinfo`. Encrypted images or ones with a licence are handed to DiskImageMounter.app. Otherwise `hdiutil attach -plist -noautoopen`. Repeat opens are de-duplicated. Statuses: opened, handedOff, busy, failed.
- **Folders** passed with `open -a` or dropped on the Dock are not handled (see the gaps above).

### Page crashes (`explorerWindowController.ts:592-623`)
- On `render-process-gone` (other than a clean exit) the page reloads. A second crash within 30 s leaves the window as it is.
- Until the reload finishes, the window doesn't count as open.
- After a reload the window opens its own tabs, not the launch folder or command (`:585-591`).

### Other windows (`main.ts:460-627`)
All other windows are pages of the same renderer, chosen by URL hash: `#settings[/tab]`, `#help[/topic]`, `#about`, `#acknowledgements`.
- **Settings:** 720×540, min 680×420, not full-screenable. Remembers the last tab for the session only (`settingsWindowTab.ts`). Tabs: general, browsing, search, files, shortcuts.
- **Help:** 900×680, min 560×420. Topics: navigation, files, search, views, shortcuts.
- **About:** 460×356 scaled by zoom, not resizable, not minimizable.
- **Acknowledgements:** 620×640, min 460×360.
- **Shared behaviour:**
  - Background is #161618 in dark and #f4f5f8 in light.
  - Navigation away from the page is blocked; https and mailto links open externally (`pageWindows.ts`).
  - Zoom is re-applied after each load.

### Startup notices
- Recovery notices from the write journal are shown as a warning after the window loads (`main.ts:739-760`).
- Later recovery retries show an info dialog (`main.ts:188-201`).

---

## 4. IPC surface (`packages/contracts/src/ipc.ts:800-1678`): 80 channels

**Transport** (`main/ipc.ts`):
- Every channel is validated by its schema on the way in and on the way out (`:41-90`). Exception: `directory:getSnapshot.entries` and `tree:getChildren.children` aren't validated item by item (`:36-39`).
- Responses are wrapped as `{ok:true,payload} | {ok:false,error}`.
- Errors on `copyPaste:*`, `writeOperation:*` and `undo:*` channels are turned into plain sentences (`describeCopyPasteError`, `:107-113`).
- EACCES/EPERM/ENOENT/ENOTDIR errors are logged only with `FILETRAIL_DEBUG=1`.
- **Limits:** `MAX_PATHS_PER_REQUEST = 100000`; `MAX_FILE_DRAG_IMAGES = 200` (`contracts/src/limits.ts`).

### App and windows (17)
| Channel | Request → Response | Purpose |
|---|---|---|
| app:getHomeDirectory | {} → {path} | Home folder path |
| app:openSettingsWindow | {tab?} → {ok} | Open or focus Settings, optionally on a tab |
| app:openHelpWindow | {topic?} → {ok} | Open or focus Help |
| app:getAboutInfo | {} → {version, commit\|null, macosVersion, architecture "Apple silicon"\|"Intel", electronVersion, fdVersion} | About window data |
| app:openAcknowledgementsWindow | {} → {ok} | Open the licenses window |
| app:getAcknowledgements | {} → {components:[{id,name,version\|null,license,url,text\|null}]} | Bundled OSS list |
| app:openAcknowledgementNotices | {id} → {ok} | Open Chromium's separate notices (Brotli-decompressed to tmp) |
| app:setMenuState | {state:{disabledCommands[≤200], viewMode, sortBy, foldersFirst, hiddenFilesShown, folderTreeOpen, infoPanelOpen, infoRowOpen, favoriteIsSet, textEditing}} → {ok} | Window reports menu state |
| app:getPreferences | {} → {preferences} | Preferences as this window sees them (with its session) |
| app:updatePreferences | {preferences: Partial} → {preferences} | Patch preferences; non-session keys are broadcast |
| app:getLaunchContext | {} → {startupFolderPath\|null, restoreTabs?, initialCommand?} | What a new window opens with |
| app:takeOpenRequests | {} → {paths[]} | Disk images queued for this window (each handed out once) |
| app:openWindow | {tabs[1..100], activeTabIndex} → {ok} | New window with these tabs |
| app:closeWindow | {} → {ok} | Close the asking window as its close button does |
| app:getExplorerWindowCount | {} → {count} | Number of explorer windows |
| app:mergeAllWindows | {tabCount≤100} → {tabs[]} | Merge All Windows |
| app:answerMergeRequest | {requestId, tabs[≤100], busy} → {ok} | Reply to `filetrail:mergeRequest` |

### App clipboard, caches, logs (5)
| Channel | Shape | Purpose |
|---|---|---|
| app:getClipboard | {} → {clipboard: {type:"empty"} \| {type:"ready", mode copy\|cut, sourcePaths[], sourceEntries{path:{kind,isSymlink,isExecutable?}}, capturedAt}} | Clipboard shared by all windows |
| app:setClipboard | {clipboard, follows?} → {ok} | Set it. With `follows`, only applies if `capturedAt` still matches. Other windows get `filetrail:clipboardChanged`. |
| app:clearCaches | {} → {ok:true} | Clear the folder-listing and metadata caches |
| app:writeLog | {level, namespace, message, error\|null, context{}} → {ok:true} | Window log entry into app.log |
| folder:watch | {path\|null} → {ok:true} | Watch the folder on screen; changes arrive as `filetrail:folderChanged` |

### Places / Go To (3)
| Channel | Shape | Purpose |
|---|---|---|
| places:list | {} → {folders:[{path, visits:[{at,kind}]}]} | Visited folders |
| places:recordVisit | {path, kind: goTo\|stay\|passThrough} → {ok:true} | Record a visit |
| places:forget | {path} → {folders} | Remove one from Go To |

### Browsing and reading (6)
| Channel | Shape | Purpose |
|---|---|---|
| tree:getChildren | {path, includeHidden} → {path, children: treeChild[]} | Child folders for the tree (cached, timed) |
| directory:getSnapshot | {path, includeHidden, sortBy, sortDirection, foldersFirst} → {path, parentPath, entries[]} | Folder listing, sorted in the worker (cached, timed) |
| directory:getMetadataBatch | {directoryPath, paths[≤500]} → {directoryPath, items: metadata[]} | Lazy metadata for visible rows (cached) |
| item:getProperties | {path} → {item: itemProperties} | Info panel data |
| path:getSuggestions | {inputPath, includeHidden, limit≤50 (default 12)} → {inputPath, basePath, suggestions[]} | Go to Folder autocomplete |
| path:resolve | {path} → resolvedPath | Resolve a typed path |

### Search, via bundled `fd` (3)
| Channel | Shape | Purpose |
|---|---|---|
| search:start | {rootPath, query, patternMode, matchScope, recursive, includeHidden, skipGitFolders, skipGitIgnored} → {jobId, status} | Start a search job |
| search:getUpdate | {jobId, cursor} → {jobId, status, items[], nextCursor, done, truncated, error} | Poll results |
| search:cancel | {jobId} → {ok} | Cancel |

### Copy, paste and write operations (13 + 1 batch-rename inspect)
| Channel | Shape | Purpose |
|---|---|---|
| copyPaste:analyzeStart | {mode copy\|cut, sourcePaths[], destinationDirectoryPath, action paste\|copy_to\|move_to\|duplicate} → {analysisId, status} | Start conflict analysis |
| copyPaste:analyzeGetUpdate | {analysisId} → {analysisId, status, done, report\|null, error} | Poll the analysis report (conflict tree, summary, issues, warnings) |
| copyPaste:analyzeCancel | {analysisId} → {ok} | Cancel analysis |
| copyPaste:start | {analysisId, action, policy{file,directory,mismatch}, overrides?[{nodeId,action}], clearsCutClipboard?} → {operationId, status:"queued"} | Execute the paste |
| copyPaste:cancel | {operationId} → {ok} | Cancel |
| copyPaste:resolveConflict | {operationId, conflictId, resolution, applyToRemaining?} → {ok} | Answer a conflict found while copying |
| writeOperation:rename | {sourcePath, destinationName} → {operationId, queued} | Rename one item |
| batchRename:inspect | {paths[], includeDateTaken} → {items[{path, createdAt, modifiedAt, takenAt, cannotRename}], folders[{path, names[], caseSensitive}]} | Data for the Rename sheet |
| writeOperation:batchRename | {items[{sourcePath, destinationName, isFolder}], onConflict number\|skip\|block, numberSeparator} → {operationId, queued} | Rename several |
| writeOperation:createFolder | {parentDirectoryPath, folderName, nextFreeName?} → {operationId, queued} | New Folder |
| writeOperation:trash | {paths[]} → {operationId, queued} | Move to Trash |
| writeOperation:deleteImmediately | {paths[]} → {operationId, queued} | Delete permanently |
| writeOperation:getAdopted | {} → {adoption\|null} | Operation handed to this window when its owner closed |
| writeOperation:getActive | {} → {operationId\|null} | Running operation, in any window |
| writeOperation:cancel | {operationId} → {ok} | Cancel |

Progress for all of these arrives as `filetrail:writeOperationProgress` events. Handlers live in `bootstrap/writeOperations.ts:1912-2260`.

### Undo (2)
| Channel | Shape | Purpose |
|---|---|---|
| undo:prepare | {direction undo\|redo} → {ticket\|null, refusal busy\|nothing\|cant_undo\|null, label, action, nameTaken[], changed[{name,putBack,replaced}]} | Dry run: what to ask first |
| undo:start | {ticket} → {operationId, queued} | Run the prepared undo |

### Folder sizes (4)
| Channel | Shape | Purpose |
|---|---|---|
| folderSize:start | {path, recalculate?, automatic?} → {jobId, status} | Measure a folder (automatic = lower priority) |
| folderSize:getStatus | {jobId} → {status, sizeBytes, diskBytes, fileCount, folderCount, measuredFolderCount, error} | Poll |
| folderSize:cancel | {jobId} → {ok} | Cancel |
| folderSize:probeMany | {paths[]} → {sizes[{path,sizeBytes,diskBytes,fileCount,folderCount}]} | Sizes already known, without measuring |

### System, macOS integration (25)
| Channel | Shape | Purpose |
|---|---|---|
| system:openPath | {path} → {ok, error} | Open with the default app |
| system:openDiskImage | {path} → {status opened\|handedOff\|busy\|failed, volumePath, reason} | Mount an image with hdiutil |
| system:getVolumeInfo | {path} → {availableBytes, totalBytes} | Volume capacity |
| system:getDiskIds | {paths[]} → {ids[] (st_dev\|null)} | Same-disk check (drag moves vs copies) |
| system:startFileDrag | {paths[], directories[], images[{path,rect,dataUrl…}]} → {started, operation copy\|move\|link\|delete\|none, endedOver this_window\|another_window\|elsewhere} | Native file drag out of the app |
| system:findDraggedAway | {paths[], intoTrash?} → {gone[]} | Which dragged-out items left; other windows get `filetrail:draggedAway` |
| system:readDraggedIn | {} → {changeCount, items[{path,kind}]} | Read the drag pasteboard for a drag coming in |
| system:readDragChangeCount | {} → {changeCount} | Drag pasteboard change count |
| system:bringWindowToFront | {} → {focused} | Activate the app (or bounce the Dock icon) |
| system:quickLook | {path} → {ok} | Quick Look |
| system:pickApplication | {} → {canceled, appPath, appName} | Choose an .app (Open With Other…, settings) |
| system:getOpenWithApplications | {paths[≤500], pinnedAppPaths[≤200]} → {defaultApp, apps[], kinds[{contentType,name,isFolder}], pinnedApps[]} | Open With menu data |
| system:setDefaultApplication | {applicationPath, contentType} → {ok, error} | LaunchServices default handler |
| system:pickDirectory | {defaultPath?} → {canceled, path} | Folder picker |
| system:openPathsWithApplication | {applicationPath, paths[1..500]} → {ok, error} | Open with a specific app |
| system:openInTerminal | {path} → {ok, error} | Open in Terminal (`terminalApp` preference) |
| system:copyText | {text} → {ok} | Put text on the pasteboard |
| system:performEditAction | {action undo\|redo\|cut\|copy\|paste\|selectAll} → {ok} | Native edit on the sender's web contents |
| system:emptyTrash | {} → {ok, error} | Empty Trash through Finder (osascript) |
| system:listVolumes | {} → {volumes[]} | Mounted volumes other than the startup disk |
| system:ejectVolume | {path, wholeDisk, force} → {status ejected\|busy\|failed, failedPath, code, reason} | Eject via Disk Arbitration |
| system:getTrashState | {} → {empty\|null} | Whether the Trash is empty (null without Full Disk Access) |
| system:openFullDiskAccessSettings | {} → {ok} | Open Privacy & Security at Full Disk Access |
| system:getFileIcon | {path, size 16–512, generic? folder\|file\|executable} → {pngBase64\|null} | NSWorkspace icon |
| system:getFileThumbnail | {path, size 16–1024, knownVersion?} → {version, unchanged, dataUrl} | Quick Look thumbnail |

### Push events, main → windows (preload `index.ts:32-51`)
`filetrail:command` {type} · `preferencesChanged` (patch) · `showSettingsTab` · `showHelpTopic` · `volumesChanged` (Volume[]) · `folderChanged` (FolderChange) · `clipboardChanged` · `writeOperationProgress` (also exposed as `onCopyPasteProgress`) · `writeOperationAdopted` · `draggedAway` {gone, intoTrash} · `trashEmptied` · `openRequestsWaiting` · `folderSizeSettled` (jobId) · `mergeRequest` {requestId}.

**Preload bridge:** `window.filetrail` exposes `invoke`, `log`, one `on*` per event, and `getPathForFile` (`webUtils`).

### Other main-process triggers
On every window focus, main:
- refreshes the volume list,
- forgets the Open With cache,
- checks the folder watch for changes it missed (`bootstrap.ts:172-208`).

---

## 5. Logging
- **Location:** `<userData>/logs/app.log` (`appLog.ts:25-27`).
- **Format:** `<ISO-8601 time> <LEVEL> <args…>`, one line per entry (`appLog.ts:49`).
  - Strings are written raw; Errors as their stack.
  - Objects use `util.inspect` with depth 8, single line, sorted keys (`:131-148`).
  - Every line is also echoed to the console.
  - Writes are serialized through a promise queue; `flush()` waits for it (`:46-68, :107-109`).
- **Rotation:** before an append that would exceed 5 MB, rotate. Keeps 10 files: `app.log`, `app.1.log` … `app.9.log` (`appLog.ts:22-23, :53-55`; `logRotation.ts:13-33`).
- **Levels:** debug, info, warn, error. Debug lines are dropped unless debug is enabled (`:59-61`).
- **Flags:**
  - `FILETRAIL_DEBUG=1`: enables debug lines and expected IPC failures (`appLog.ts:29-31`, `ipc.ts:30`). Set in CI for the smoke tests.
  - `FILETRAIL_DEBUG_TIMINGS=1`: enables debug lines and logs every IPC timing (`responseCache.ts:47`).
  - `FILETRAIL_OPEN_DEVTOOLS=1`: detached DevTools and the menu item.
  - `FILETRAIL_RENDERER_URL`: overrides the page URL.
  - `start.sh --verbose`: build verbosity only.
- **Timing logs:** `withTiming(label, path)` emits `[filetrail] <label> <path> <ms>ms` at debug level when ≥120 ms, or always with the timings flag (`responseCache.ts:742-756`).
  - It wraps tree:getChildren, directory:getSnapshot, directory:getMetadataBatch, item:getProperties, path:getSuggestions, path:resolve and search:start (`bootstrap.ts:390-448`).
  - Because it uses debug level, slow-call lines only reach the file when a debug flag is set.
- **Structured lines:**
  - `[filetrail] app start` with appVersion, electron/chrome/node versions, platform, arch, pid, userDataPath, appLogPath, startupFolderPath, debugEnabled, fdBinaryPath/fdBinaryError (`main.ts:127-141`).
  - Also: app activate, open file, second instance activation, app stop (phase, windowCount, worker and coordinator status), renderer process gone or unresponsive, uncaught exception, unhandled rejection, failed reading/persisting app state, shutdown failures.
- **Window-side logging:** `createRendererLogger(namespace)` sends `app:writeLog`, written as `[namespace] message [error] [context]` (`renderer/lib/logging.ts`, `appLog.ts:116-129`).

---

## 6. Build and release

**Build** (`scripts/build.ts`): Bun bundles into `apps/desktop/dist/`.
- `main/main.js`, plus the core `explorerWorker.js`: ESM, names kept, linked source maps.
- `preload/index.cjs` (CJS).
- `renderer/main.js`: fully minified; `NODE_ENV=production` unless `--development`.
- Copies `index.html`, `assets/` and the SVG icon.
- Writes `dist/assets/licenses/` and `dist/build-info.json` `{version, commit}`; commit is `git rev-parse --short HEAD` (`:139-153`).

**Version scheme** (`scripts/lib/version.ts`):
- A release is a commit tagged `vX.Y.Z`. Any other build is `<last release>+dev.<commits since>`, or `0.0.0+dev.N` with no release (`:75-86`, `:111-124`).
- package.json versions are placeholders (`0.0.0`).
- `CFBundleShortVersionString` and `CFBundleVersion` are the numeric part only (`make-macos-app.sh:161, :184-185`).
- The packaged `Resources/app/package.json` gets the real version so `app.getVersion()` works (`:257-262`).

**Packaging and signing** (`scripts/make-macos-app.sh`, modes: default Developer ID, `--notarize`, `--adhoc`):
- Builds on and for **arm64 only** (`:61-68`). Steps: icon, native-fs addon (node-gyp), then `bun run build`.
- Copies `Electron.app` to `out/FileTrail-darwin-arm64/File Trail.app`.
- **Info.plist** edits (`:178-210`):
  - `CFBundleName` and `CFBundleDisplayName` = "File Trail".
  - **`CFBundleIdentifier` = `com.filetrail.desktop`**.
  - `CFBundleExecutable` = "File Trail" (renamed from Electron so `isPackaged` is true).
  - `CFBundleIconFile` = `FileTrail.icns`.
  - `NSAppleEventsUsageDescription` = "File Trail asks Finder to empty the Trash."
  - **`CFBundleDocumentTypes`:** one entry, Name "Disk Image", Role Viewer, `LSHandlerRank` Alternate, `LSItemContentTypes` [`com.apple.disk-image`].
  - No URL schemes and no folder document type.
- **Slimming:** non-English `.lproj`, SwiftShader and `default_app.asar` are removed. Chromium notices are added as `Resources/LICENSES.chromium.html.br` (Brotli). Source maps are deleted. The native-fs addon and node-gyp-build are copied in.
- **Entitlements** (`scripts/entitlements.mac.plist`): `com.apple.security.cs.allow-jit` (V8) and `com.apple.security.automation.apple-events` (osascript to Finder). No sandbox.
- **Signing** (`:302-343`):
  - Identity: the SHA-1 of the Developer ID .cer (`MACOS_SIGN_CERT`, default `~/Documents/Apple Developer Certificates/developerID_application.cer`), or `MACOS_SIGN_IDENTITY`.
  - Hardened runtime and secure timestamp, signed inside-out: `.node` and `fd` binaries, then dylibs, crashpad and ShipIt, then frameworks, then Helper apps with entitlements, then the app with entitlements. Finally `codesign --verify --deep --strict`.
  - Ad hoc mode uses `codesign --deep -s -`.
- **Notarization** (`:345-391`):
  - `xcrun notarytool submit --keychain-profile ${MACOS_NOTARY_PROFILE:-filetrail} --wait`, on a zip of the app, then `stapler staple` and `spctl --assess`.
  - Then `FileTrail-arm64.zip` and a UDZO `FileTrail-arm64.dmg`; the DMG is signed, notarized and stapled.
- **App icon** (`scripts/build-app-icon.sh`): `assets/icons/filetrail.svg`, rendered by `rsvg-convert` to `assets/icons/build/filetrail-1024.png`, then `png2icons` to `filetrail.icns`. Development runs set the Dock icon from the PNG (`main.ts:151-160`).
- **Acknowledgements** (`scripts/thirdPartyLicenses.ts`):
  - Components: fd (MIT or Apache 2.0, version from `assets/vendor/fd/manifest.json`), Electron (MIT), Chromium (separate notices, version reported at runtime), React (MIT), Zod (MIT), node-gyp-build (MIT).
  - Output: `dist/assets/licenses/<id>.txt` and `index.json`. A missing license fails the build.
  - Read at runtime by `main/aboutInfo.ts:69-118`.
- **Bundled `fd`:** `assets/vendor/fd/` (manifest has the arm64 binary path and sha256), resolved by `main/fdBinary.ts`.
- **Release** (`scripts/release.ts`): `bun run release <major|minor|patch|X.Y.Z> [--yes] [--dry-run]`.
  1. Requires clean `main`, equal to `origin/main`, and no unfinished release: no local-only tag, latest not a draft or missing (`lib/releaseState.ts`).
  2. Builds native, runs `bun run ci`, builds the desktop app, runs the smoke tests.
  3. Checks HEAD is unchanged, creates annotated tag `vX.Y.Z`, then `desktop:make:mac:notarized`.
  4. Verifies the bundle and recorded versions match, pushes the tag, and runs `gh release create --draft` with the DMG and ZIP, using notes drafted from commit subjects (`lib/releaseNotes.ts`).
  5. If anything fails before the push, the tag is deleted.
- **CI** (`.github/workflows/ci.yml`):
  - Runs on `macos-14`, 30 min timeout, with `FILETRAIL_LARGE_FILE_TESTS=1`.
  - Steps: bun install (frozen), build native-fs, `bun run ci` (Biome lint, `tsc --noEmit`, Vitest with coverage), `desktop:build`, then `test:smoke` (Playwright) with `FILETRAIL_DEBUG=1`.
  - Vitest runs on Electron-as-node (`ELECTRON_RUN_AS_NODE=1`) using a background (`LSUIElement`) re-signed copy of Electron (`scripts/runVitest.ts`).

---

## 7. Test suite inventory

**Totals:** 3,366 Vitest cases in 249 files (count of lines starting `it(`/`test(` or `it.x(`/`test.x(`). Around 51 `it.each`/`test.each` tables are counted once each, so runtime cases are somewhat higher. Plus **31 Playwright e2e** cases in 8 specs.

| Area | Files | Cases |
|---|---|---|
| apps/desktop/src/main (top level) | 19 | 249 |
| apps/desktop/src/main/bootstrap | 29 | 551 |
| apps/desktop/src/preload | 1 | 8 |
| apps/desktop/src/shared | 7 | 119 |
| apps/desktop/src/renderer | 144 | 1,746 (App.* 567, components 468, hooks 98, lib 576, other 37) |
| apps/desktop/scripts/lib | 3 | 13 |
| packages/contracts | 7 | 57 |
| packages/core | 38 | 547 |
| packages/native-fs | 1 | 76 |

**Class key:** **L** = pure logic, ports to XCTest unit tests. **FS** = real filesystem or OS (temp dirs, hdiutil, native addon). **UI** = UI or behaviour (jsdom/React or controller with stand-in windows). **E** = specific to Electron or Zod; replace rather than port.

### Shell, state, menus (main top level)
| File | Cases | Class | Covers |
|---|---|---|---|
| main/appMenu.test.ts | 36 | L | Menu layout, ids, keys, routing to focused vs other windows, no-window behaviour, enable/check/visible rules, Undo labels |
| main/applicationMenuSync.test.ts | 13 | L | Which window the menu targets; state caching; rebuild only when labels change |
| main/appStateStore.test.ts | 26 | FS (injectable fs) | Atomic writes, prompt vs deferred saves, sanitizing, migration, per-window sessions, last closed window, rename presets |
| main/explorerWindowController.test.ts | 48 | UI/L (stand-in windows) | Startup restore, opening windows, open-from-other-app, order and bounds, closing with the busy question, quitting, Merge All, page crashes |
| main/explorerWindows.test.ts | 5 | L | Window list ordering; `placeNewWindow` cascade |
| main/windowIpcHandlers.test.ts | 8 | L | Session-aware preferences, broadcast filter, shared clipboard `follows`, merge requests and timeout |
| main/quitWhileBusy.test.ts | 8 | L | Activate rule; quit/close messages per operation kind |
| main/launchContext.test.ts | 10 | L (stubbed stat) | `--folder` and positional parsing, ~ expansion, app path skipped |
| main/settingsWindowTab.test.ts | 2 | L | Parse `#settings/<tab>` |
| main/pageWindows.test.ts | 3 | E/L | External URL allow-list, navigation guard, zoom |
| main/rendererProtocol.test.ts | 4 | E | `filetrail://` file resolution and traversal guard |
| main/ipc.test.ts | 10 | E | Envelope, validation both ways, unchecked lists, error humanizing |
| main/bootstrap.test.ts | 30 | L | `toPreferencePatch` mapping; terminal app name; app bundle path validation |
| main/appLog.test.ts | 4 | FS | Line format, rotation, debug gating, structured entries |
| main/aboutInfo.test.ts | 10 | FS | build-info, licenses index, Chromium notices decompression, macOS version format |
| main/fdBinary.test.ts | 2 | FS | Bundled fd path resolution |
| main/diskImages.test.ts | 10 | L (mocked hdiutil) | Mount, hand-off to DiskImageMounter, plist parsing, busy |
| main/volumes.test.ts | 8 | L | Volume watcher and eject results |
| main/folderWatch.test.ts | 12 | L | Per-window watch, missed-change check, cache invalidation |
| preload/index.test.ts | 8 | E | Bridge invoke/unwrap and listeners |

### Shared logic
| File | Cases | Class | Covers |
|---|---|---|---|
| shared/shortcuts.test.ts | 32 | L | Parse/normalize, key events to shortcut, resolution and conflicts, refusals, assign/remove/reset, accelerators |
| shared/toolbarItems.test.ts | 10 | L | Sanitize, required items, palette, insert/move/remove |
| shared/visitedFolders.test.ts | 8 | L | Scoring, eviction, serialize and sanitize |
| shared/appPreferences.test.ts | 6 | L | Clamps, column order, theme, accent |
| shared/batchRename.test.ts | 58 | L | Rename modes (replace, regex, add, format, date, case), splitting, preset sanitizing |
| shared/diskImages.test.ts | 3 | L | Extension detection; failure text |
| shared/aboutInfo.test.ts | 2 | L | Version string; Copy Details text |

### Main bootstrap (file operations, undo, caches)
| File | Cases | Class | Covers |
|---|---|---|---|
| writeOperations.test.ts | 81 | FS+L | Write coordinator: queueing, progress, cancel, several windows, rename on a real disk |
| writeOperations.windows.test.ts | 26 | FS+L | Progress to other windows; hand-over to a successor window on close |
| writeOperations.undoLog.test.ts | 25 | FS | What each operation records for Undo |
| writeOperations.batchRename.test.ts | 17 | FS | Batch rename on a real disk and its pre-checks |
| batchRenameExecution.test.ts | 43 | L (memory disk) | Batch rename engine: swaps, chains, conflicts |
| batchRenameExecution.fuzz.test.ts | 3 | L | Randomized batch rename |
| batchRenamePlanAndRun.test.ts | 9 | L | Plan shown matches the rename done |
| batchRenameInspect.test.ts | 7 | FS | `batchRename:inspect` |
| undoPlan.test.ts | 32 | L | Reverse steps and move/trash checks |
| undoHistory.test.ts | 20 | L | History stack, two-try undo, size cap, menu labels |
| undoExecution.test.ts | 37 | FS | Undo round trips, outside changes |
| undoExecution.failures.test.ts | 29 | FS | Failure handling |
| undoExecution.locked.test.ts | 9 | FS | Locked items |
| undoExecution.names.test.ts | 8 | FS | Case-only renames and names taken |
| undoExecution.start.test.ts | 7 | FS | Ticket and start flow |
| undoExecution.links.test.ts | 3 | FS | Folders opened through symlinks |
| undo.realfs.test.ts | 3 | FS | Undo across disks (disk images) |
| undo.fuzz.test.ts | 5 | FS | Fuzzed undo on a real disk |
| writeJournal.test.ts | 24 | FS | Replace journal open and recovery |
| responseCache.test.ts | 53 | L | TTL caches, folder-size handlers, owner cleanup, quitting |
| folderSizeAdjust.test.ts | 21 | L | Size adjustments after trash or delete |
| folderSizeCache.test.ts | 6 | L | Folder size cache during writes |
| preferencesPatch.test.ts | 14 | L | Preference patch mapping |
| systemHandlers.test.ts | 10 | L (mocked) | emptyTrash, getTrashState, Open With |
| systemHandlers.apps.test.ts | 24 | FS | openPath, Full Disk Access, volume info, app pickers |
| fileDrag.test.ts | 13 | L (mocked native) | Drag out, image decode, dragged-away detection |
| diskHasTrash.test.ts | 11 | FS | Mount-table parsing; which disks have a Trash |
| diskIds.test.ts | 2 | FS | st_dev per path |
| trashItem.test.ts | 9 | L | Trash wrapper rules |

### Contracts and scripts
| File | Cases | Class | Covers |
|---|---|---|---|
| contracts ipc.test.ts | 24 | E/L | Schema acceptance and rejection (becomes Codable tests) |
| contracts writeEffects.test.ts | 13 | L | Which paths a write changes; change matcher |
| contracts trash.test.ts | 6 | L | isInsideTrash, isTrashFolder |
| contracts itemName.test.ts | 5 | L | Name validation; package detection |
| contracts copyPasteChoices.test.ts | 5 | L | Conflict choice tables |
| contracts paths.test.ts | 2 | L | `withoutNestedPaths` |
| contracts schemaFreeImports.test.ts | 2 | E | Bundle hygiene |
| scripts version.test.ts | 8 | L (+git) | Release tag parsing, next version, build version |
| scripts releaseState.test.ts | 3 | L | Unfinished-release detection |
| scripts releaseNotes.test.ts | 2 | L | Draft release notes |

### packages/core (copy engine, explorer service, search, worker)
**Pure logic, 23 files:**
- copyPasteExecution 99, copyPasteAnalysis 35, copyPasteEdgeCases 18, copyPasteFingerprint 15, copyPasteNames 13, copyPasteMoveCleanup 10, copyPasteRecovery 10, copyPastePartialFile 8, copyPasteReviewEdges 8, copyPastePolicy 7, copyPasteScenarioMatrix 7, copyPasteBlockedReplace 3, copyPasteErrors 3, copyPasteStagedDiscard 3, copyPasteLargeTree 1.
- writeService.analysis 12, writeService.runtime 11.
- explorerService.fixtures 4 (fixtures on disk), stoppableCopy 5, fdSearch 16 (spawns fd), explorerWorker 5, explorerWorkerClient 6, createExplorerFixture 1.

**Real filesystem, 15 files:**
- copyPasteRuntimeSafety.realfs 62, copyPasteConflictSafety.realfs 28, copyPasteUndoLog.realfs 27, copyPasteFolderSafety.realfs 17, copyPasteLocked.realfs 13, copyPasteVolumes.realfs 12 (FAT32 image), copyPastePackages.realfs 11, copyPasteExecution.realfs 10, copyPasteReviewData.realfs 6, copyPasteNative.realfs 3, copyPasteAnalysis.realfs 1, copyPasteSymlinkMetadata.realfs 1.
- explorerService 30, writeService 17, undoLog 9.
- Large-file tests are gated by `FILETRAIL_LARGE_FILE_TESTS`; disk images come from `core/src/fs/testDiskImage.ts`.

**native-fs:** native-fs.test.ts, 76 cases, **FS**. Covers the C/ObjC addon: folder size, copyfile, ACLs, flags, rename, trash, volumes, icons, thumbnails, open-with, eject. This is the behavioural spec for the native Swift replacements.

### Window side (React; all **UI** unless marked) — `apps/desktop/src/renderer`
- **App integration (567):**
  - App.fileOperations 111, App.menusAndTree 78, App.commands 62, App.windows 39, App.pasteFlow 38, App.tabs 36, App.openItems 30, App.dragIn 28, App.dragOut 22.
  - App.undo 16, App.search 14, App.treeKeys 14, App.folderWatch 13, App.listPaging 12, App.menuCommands 11, App.writeRefusals 11, App.folderOrder 10, App.history 8, App.selection 6, App.notifications 5, App.scrollRestore 2, App.tabOrder 1.
- **Components (468):**
  - SettingsView 39, ContentPane 39, TreePane 37, ExplorerWorkspace 35, BatchRenameSheet 27, CopyPasteReviewDialog 24, GetInfoPanel 24, ItemContextMenu 21, CopyPasteResultDialog 17, TabStrip 17, InfoRow 13, IconGridView 12.
  - ClipboardButton 11, InlineRenameField 11, GoToFolderDialog 10, ShortcutSettings 10, HelpView 9, ContentPane.items 9, TreePane.rows 9, CopyPasteRuntimeConflictDialog 8, ToastViewport 7, ContentPane.reveal 7.
  - AppDialogs 6, ContentPane.dragSelection 6, HistoryButton 6, PathbarFolderMenu 6, SearchBar 6, SearchOptionsMenu 6, ToolbarIcon 6, ClipboardMarks 5, CopyPasteDialog 4, TextPromptDialog 4, UndoQuestionAlert 4.
  - ContentPane.rename 3, ContentPane.rowRenders 3, ActionNoticeDialog 2, CopyPasteProgressCard 2, TreePane.rowRenders 2, WindowDragRelease 1.
- **Hooks (98):** useFolderSizeCache 38, useBatchRename 13, useFolderWatch 10, useAutoFolderSize 6, useExplorerPaneLayout 5, useEjectVolume 4, useKeepInViewport 4, usePreferencesSync 4, useAppPreferences 3, useHiddenItemCount 3, useRelativeDate 3, useWriteOperations 3, useDelayedFlag 1, useElementSize 1.
- **lib (576, mostly L, porting candidates for view models):**
  - formatting 44, explorerAppUtils 42, rendererCommandAvailability 27 (the menu enable rules), shortcutPolicy 24, copyPasteReview 21, explorerNavigation 21, internalDragAndDrop 21, copyPasteClipboard 20, shortcutTargets 18, explorerTabs 17, virtualization 16, openWith 15.
  - startupNavigation 14, focusedEditTarget 13, titleTooltips 12, topToolbarLayout 12, detailsLayout 11, iconGridLayout 11, eject 9, iconLabel 9, statusSummary 9, fileIcons 9, contentSelection 8, favorites 8, searchResults 8.
  - dragSelection 7, flowListLayout 7, helpContent 7, menuPlacement 7, places 7, tooltips 7, fileThumbnails 7, selectionSize 6.
  - earlyWriteOperationEvents 5, explorerPaneFocus 5, folderVisitTracker 5, infoPreview 5, listFilter 5, logging 5, otherWindowsWriteResult 5, relativeClock 5, scrollbarVisibility 5, theme 5.
  - accent 4, fileDragImages 4, pagedScroll 4, searchRefinement 4, treeView 4.
  - entriesAtPaths 3, filetrailClient 3, goMenuPlaces 3, historyMenu 3, nameHighlight 3, responsiveLayout 3, volumes 3.
  - layoutTokens 2, toasts 2, typeahead 2, undoQuestion 2, windowActivity 2, folderViewMemory 1.
- **Other (37):** styles.theme 13 (CSS), SettingsWindowApp 5, AboutWindowApp 4, main 4 (hash routing), state/explorerStores 4, AcknowledgementsWindowApp 3, test/mockFiletrailClient 3, styles.responsive 1.

### E2E (Playwright driving the built Electron app, `apps/desktop/e2e`)
Each run uses its own `--user-data-dir`. `quitApp.ts` waits for no active operation, then fails with the tail of app.log if quit takes more than 15 s.

| Spec | Cases | Flows |
|---|---|---|
| smoke.spec.ts | 1 | App launches; `main.app-shell` visible; window title is the home folder name |
| windows.spec.ts | 5 | New windows on the current folder; windows restored after relaunch; each window's place and front order restored; move a tab out and Merge All back; paste in one window what was copied in another; app stays open with no window and reopens where the last one closed (via `app.emit("activate")`) |
| fileOperations.spec.ts | 8 | Copy/paste in the same folder (makes a copy); ⌘D duplicate; F2 rename in the list; new folder named in its row; ⌘⌫ trash; cut/paste moves; name-taken dialog "keep both"; a taken name keeps the field open |
| undo.spec.ts | 3 | Undo/redo a rename from the Edit menu (label names it); put back from the Trash; ⌘Z inside the rename field undoes typing, not files |
| batchRename.spec.ts | 7 | Add text; numbering a taken name; chained names; date-created naming with repeats numbered; swap two names; case-only change on a case-insensitive disk; settings and presets persist across a quit |
| dragIn.spec.ts | 3 | Drag-in from another app moves (Undo restores); copy-only source copies into a list folder; refused on the path bar and for items already in the folder |
| folderWatch.spec.ts | 2 | Outside create/rename/delete shown with the selection kept; file size growth shown |
| quit.spec.ts | 2 | Quit while measuring a folder ends the process at once; quit during a search leaves no `fd` process |

### Porting summary
- **Directly portable to XCTest unit tests (L):** about 1,150 cases outside the window code. These are shared/*, menu, sync, windows, launch, quit, store logic, contracts, batch-rename and undo planning, caches, core copy logic, scripts. Window-side `lib/*` adds about 550 more for view-model logic.
- **Real filesystem or OS integration (FS):** about 700 cases. These are core *.realfs, bootstrap undo/writeJournal/writeOperations, native-fs 76, appStateStore, appLog, aboutInfo, systemHandlers.apps. They port to XCTest with temp dirs and hdiutil images.
- **UI behaviour (UI):** about 1,100 React/jsdom cases (App.*, components, hooks) plus the 48 window-controller cases plus 31 e2e. Re-target these to XCUITest or AppKit controller tests. The e2e flows are the minimum acceptance set.
- **Electron or Zod transport (E):** about 50 cases (ipc, preload, rendererProtocol, pageWindows, schemaFreeImports, parts of the contracts ipc tests). These become Codable and service-boundary tests.
