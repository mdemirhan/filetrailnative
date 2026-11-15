# Commands

What a new command needs, so that it can be found everywhere a command is looked for: the menus, the command palette (⇧⌘P), Help and Settings → Shortcuts. A command is anything someone can run: a menu item, or something done with a key that has no menu item (Move Half a Page Down, Focus Folder Tree). The decisions on where items go are in [decisions/windows-and-panes.md](../decisions/windows-and-panes.md) ("The menus keep Finder's order and groups", "The command palette lists every command").

## The one table

Every command is a row of `ShortcutCommands.all` (`Sources/FTFoundation/Commands/ShortcutCommandTable.swift`), with or without a key:

- **`label`**: the name as it reads on its own, in Settings, Help and the palette ("View as Icons", not the menu's "as Icons").
- **`group`**: the heading Settings, Help and the palette list it under.
- **`defaults`**: its keys before Settings changes them, often none. Finder's key where Finder has the command. A key no command has today, checked against the table and `ShortcutCommands.refusal(for:)`.
- **`menuPath`**: where the menu has it ("View > Sort By > Name"), or nil for a command only keys run. The palette shows it beside the name.
- **`fixed`**: only for keys shared with text fields or macOS's own (⌘C, ⌘Q). A fixed command is listed in Settings but can't be changed there.

That row is what puts the command in **Settings → Shortcuts** (every row is listed, with a hint in `ShortcutSettingsText.hint` where the label needs one) and in **the command palette** (built from the table, see below). Its keys reach the menu and the window's key handler from here too.

## Running it

- A command the menu, the toolbar or a key sends to a window is an `AppCommand` with the same raw value as its table row. The window carries it out in `MainWindowController.perform`; what it can run now is decided in `CommandAvailability` and `ShortcutPolicy`, and what its menu item shows (dimmed, checked, a title that names what it acts on) in `ApplicationMenu.itemStates`.
- The menu item goes in `ApplicationMenuBuilder`, where Finder would have it, or beside the item of Finder's it is most like.
- A command with no menu item runs from the window's key handler (`runKeyCommand`), and from the palette through `MainWindowController.runPaletteKeyCommand`; one the palette can't run that way doesn't work from the palette until it can.

## The command palette

The palette lists every row of the table and the menu items that aren't in it, so a new command is in it with nothing more to do. Three cases need a line in `CommandPalette` (`Sources/FTFoundation/Commands/CommandPalette.swift`):

- **The menu's title names what the command acts on** (Compress “Photos”, Edit in BBEdit, Show Folder Tree): add it to `menuTitledCommands`, and the palette shows the menu's title in place of the label.
- **A menu item with no table row** (About, Manage Workspaces…): add it to `menuItems`, with its label, place and group.
- **A `fixed` row with no `menuPath`** (Undo, Quit): add its menu to `standardPlaces`, so the palette says where it is.
- **A command the palette shouldn't list**: add it to `excludedCommands` or `excludedMenuItems`, with the reason beside it. Today that is the palette itself, Services, and the five workspace keys, which the palette lists by the workspaces' names instead.

`CommandPaletteTests` walks the table and the built menu and fails on any command or menu item that is neither in the palette nor excluded.

## Help

- Every table row has a line in `HelpContent.shortcutItems` (`Sources/FTFoundation/Help/HelpTopics.swift`), which the Keyboard Shortcuts page lists. `HelpContentTests` fails without it.
- The command palette shows that line under its list while the command is selected, alone, without the key beside it. So it says what the command does and to what, more than its name: "Copy the selected items, to paste into another folder", not "Copy". It is a phrase with no period, 80 characters at most. `CommandPaletteTests` checks all three. A menu item with no table row has its line in `CommandPalette.menuItems`.
- A command that needs more than its line gets a row in the topic it belongs to, saying what it does and where it is.
- `Tests/Golden/help-content.json` records the shortcut list and what Help's search finds: a new or changed line is put in each case's list by hand, and in the searches whose words it now holds or no longer does.

## Goldens

- `Tests/Golden/shortcut-resolution.json` records every command's keys in each case: a new row is added to each case's `bindings`, and a new default key to `commandByShortcut` where it is claimed (in the table's order).
- `Tests/Golden/command-availability.json` lists, case by case, the `AppCommand`s that can't run: a new `AppCommand` is added to the lists where it can't.

They are edited by hand, never written from the code's output (`docs/decisions/code.md`).

## Before it lands

- The tests above pass: `scripts/ci.sh --scope Commands`, `--scope Help`, `--scope Menus`.
- The command is tried in the built app: from its menu item, from its key, and from the palette (⇧⌘P, its name typed, Return).
