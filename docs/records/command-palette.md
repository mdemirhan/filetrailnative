# Command palette

The plan the command palette (⇧⌘P) was built to, kept for the record; it is done. What it does, and why, is in [decisions/windows-and-panes.md](../decisions/windows-and-panes.md) ("The command palette lists every command"); what a new command needs to be in it is in [process/commands.md](../process/commands.md).

## The parts

1. **The list** (`FTFoundation/Commands/CommandPalette.swift`, no AppKit). From the shortcut table, the keys as Settings has them, what `ApplicationMenu.itemStates` says of each command (dimmed, checked, its title), the menu's titles and the workspaces, it makes one entry per command: an id, the name, its place in the menus, its keys, dimmed or not, checked or not, its group, and how it runs (a menu item's id, a key command of the window's, or one of the system's own items). It matches what is typed with `NameMatcher` (Fuzzy) and orders the rows; it keeps the recent commands. Unit tests, and the test that every command and menu item is in it or excluded.
2. **The recent commands** (`FTFileSystem/AppState`): `recent-commands.json` beside `app-state.json`, the last 20 ids, written as the visited folders are.
3. **The box** (`FTAppKit/Dialogs/CommandPaletteBox.swift`): a `DialogPanelView` dropped below the toolbar with Go To's field shell, rows like Go To's (a symbol, the name with the matched letters bold, the menu place, the keys, a check), section headings while nothing is typed, and a footer line with the keys.
4. **Opening and running** (`MainMenu`, `MenuCommandRouter`, `MainWindowController`): View ▸ Command Palette… (⇧⌘P), a table row `showCommandPalette` in the View group. The menu reads the window's state before the box opens, as a dialog dims everything, and builds the list from it. Running closes the box, the keyboard goes back, and the command goes through `MenuCommandRouter.choose(itemID:)`, or the window's key commands, or the system's item. From Settings or Help the browsing window comes to the front first.
5. **Help**: a line in the Keyboard Shortcuts list and a row in the Windows topic.
6. **Tests**: the list and its order (FTFoundation), the recent-commands file (FTFileSystem), the box's keys and rows with a window never shown (FTAppKit), and a GUI test: ⇧⌘P, a name typed, Return, the command ran in the active pane.

## Left for later

- A command's own hint in the row (Settings has a few): not shown in the palette for now.
