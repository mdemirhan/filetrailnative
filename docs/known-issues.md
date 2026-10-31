# Known issues

Differences and gaps left when the port from Electron finished. None has been decided on yet. IDs are from the port's records, kept in the private archive. Background work that may affect battery is in [battery.md](battery.md).

## Medium

- **VoiceOver in the folder tree** (`B-TREE-015`): rows don't report selected, expanded or level, and the lists have no names. Only the row label is exposed.

## Files and drags

- **Preparing sheet** (`T-00e53ea3`): Return does nothing; the focused Cancel took it in Electron. `PasteFlow.swift:70`.

## Keyboard and focus

- **Keyboard lost after a dialog** (`B-NAV-223`): closing a dialog opened from a text field leaves no pane with the keyboard until a click.

## Lists and panels

- **Outside changes during some dialogs** (`B-NAV-136`, `B-VIEW-187`): the list can change under Go To, Customize Toolbar and notices; only copy-paste dialogs, drags, menus, rename and writes hold changes back.
- **Sorted search results** (`B-VIEW-083`): sorting by a header doesn't reveal the lead item, and a quiet re-order doesn't keep it in view.
- **Folder sizes per tab** (`B-INFO-199`): a calculation in one tab shows no progress in another tab on the same folder.

## Small visual details

- **Dimmed Paste** (`B-VIEW-214`): still shows its shortcut.
- **Always Open With** (`B-VIEW-223`): Option relabels the row before macOS has answered, even for files of different kinds.
- **Selected row behind dialogs** (scenarios 198, 218): gray, where Electron stays blue behind the Undo question and result sheet.

## Tests to watch

This failed only under load and passed alone: `theAppsCatalogForgetsWhenAWindowComesForward`. `FTFileSystemTests` also crashed once in a full run, cause unknown.
