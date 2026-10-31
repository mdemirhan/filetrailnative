# Known issues

Differences and gaps left when the port from Electron finished. None has been decided on yet. IDs are from the port's records, kept in the private archive. Background work that may affect battery is in [battery.md](battery.md).

## Medium

- **VoiceOver in the folder tree** (`B-TREE-015`): rows don't report selected, expanded or level, and the lists have no names. Only the row label is exposed.

## Files and drags

- **Failed spring-loaded drag** (`T-5de0804d`): when a held folder can't be read, the folder on screen still takes drops. An Option-drop on empty space then duplicates the items there instead of being refused. `TabDragDrop.swift:345`.
- **Busy notice shown twice** (`B-CLIP-072`, `T-65506a7d`): a paste refused at its start shows two stacked alerts. `WindowWriteActions.swift`, `PasteFlow.swift`.
- **Silent menu action while busy** (`B-CLIP-060`, `B-VIEW-215`): a right-click item chosen after an operation began does nothing and says nothing. `ContextMenuCoordinator.swift:168`.
- **Items a write took away stay selected** (`B-NAV-140`, `B-SEL-026`): until the next read. `AfterWrite.pathsLeftByWrite` exists and is tested, but nothing calls it.
- **Drop from another File Trail window** (`T-9c4c006c`): the target window stays behind its dialog. `TabDragDrop.swift:40` checks the app, not the window.
- **Result text after a reviewed drop** (`T-e0ffebfc`): a drop through the review sheet says "Moved to Target" for the folder on screen, where a direct drop is silent.
- **Preparing sheet** (`T-00e53ea3`): Return does nothing; the focused Cancel took it in Electron. `PasteFlow.swift:70`.

## Keyboard and focus

- **Keyboard lost after a dialog** (`B-NAV-223`): closing a dialog opened from a text field leaves no pane with the keyboard until a click.
- **Path bar clicks** (`B-INFO-111`, `B-VIEW-006`, `T-01ad97ab`): a press on a segment or separator doesn't move focus to the list. `PathBarView.swift:93,178`.
- **Search from a filter** (`B-SRCH-052`): the carried text ends selected, so the next key replaces it. `TabSearch.swift:288`.
- **Sidebar header margins** (`B-TREE-028`): a press beside the header's button doesn't clear the selection. `SidebarListView.swift:105`.

## Lists and panels

- **Outside changes during some dialogs** (`B-NAV-136`, `B-VIEW-187`): the list can change under Go To, Customize Toolbar and notices; only copy-paste dialogs, drags, menus, rename and writes hold changes back.
- **Sorted search results** (`B-VIEW-083`): sorting by a header doesn't reveal the lead item, and a quiet re-order doesn't keep it in view.
- **Marquee and the scroll wheel** (`B-VIEW-081`): the wheel does nothing during a marquee.
- **Rename error box** (`B-SEL-134`): stays in place when the window resizes.
- **Removed favorite** (`B-NAV-186`, `B-TREE-050`): a saved tab still opens as that favorite, so no row is selected and the tree doesn't follow.
- **Free space in the Info panel** (`B-INFO-049`): stays as first read for that tab.
- **Info Row buttons** (`B-INFO-166`): with the panel open on another item, Calculate, refresh and Stop act on the panel's item.
- **Folder sizes per tab** (`B-INFO-199`): a calculation in one tab shows no progress in another tab on the same folder.

## Small visual details

- **Dimmed Paste** (`B-VIEW-214`): still shows its shortcut.
- **Always Open With** (`B-VIEW-223`): Option relabels the row before macOS has answered, even for files of different kinds.
- **Selected row behind dialogs** (scenarios 198, 218): gray, where Electron stays blue behind the Undo question and result sheet.

## Tests to watch

These failed only under load and passed alone: `f2RenameLands`, `theToolbarDimsWhileANewFolderIsNamed`, `theAppsCatalogForgetsWhenAWindowComesForward`, `keyStepsCopyInThePickedWindowAndPasteInTheOther`. `FTFileSystemTests` also crashed once in a full run, cause unknown. `PasteThroughputTests` has a timing limit, so a busy Mac can fail a release check.
