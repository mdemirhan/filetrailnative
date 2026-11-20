# Clipboard shelf

The plan for gathering files from several folders on the app's clipboard and pasting them together, each item copied or moved as it was put on. The owner's decision behind it is in [decisions/file-operations.md](../decisions/file-operations.md) ("Each item on the clipboard keeps what it was put there for, and the clipboard can be added to"). The options weighed, with mockups, were in a design page made for the owner on 2026-11-20.

## What is decided

- ⌘C and ⌘X replace the clipboard, to copy and to move, as now. Add to Copied Items (⌃⌘C) and Add to Cut Items (⌃⌘X) add to it.
- ⌘V does what each item was put on for, in one paste. Move Items Here (⌥⌘V) moves everything; nothing copies everything.
- Paste's title counts the items and its subtitle says what it will do ("Moves 4, copies 3").
- One file, one intent: put on again with the other, it switches.
- The clipboard list is split by intent, Cut above Copied, folders inside each.
- A cut item changed is followed or leaves on its own; the rest stay cut.
- No folder with an item of its own on the list.
- Show Clipboard is ⌃⌘V.
- Put Back: in the toast after ⌘C or ⌘X replaces a list built with Add, then in the list's footer ("Before: 7 items · Put Back") until the next Copy or Cut or a quit; it swaps the two lists. Not in the menus or the palette.
- **Two items of one name on the clipboard are settled when the second is put on, never at the paste.** Copy and Cut replace the list, so only an Add can bring a clash. It asks, once per Add however many items clash: Keep Both (Return) keeps both on the list and pastes the one just added with a number; Use This One takes the other off the list; Don't Add (Esc) leaves the clashing items off. The rest of the selection is added either way. The row of an item kept that way says "pasted with a number", and its menu in the list has Use This One Instead and Remove from Clipboard. The buttons don't say Replace: near files that means something goes to the Trash, and here only the list changes. Names are compared as most Macs' disks compare them (ignoring case and how an accented letter is stored). Two folders of one name are numbered too; merging them is not part of this.
- **The paste's conflicts are today's.** A clash with something already in the folder pasted into goes through the paste review and its answers as now, with the same dialog. Two things only are added to it: a Move or Copy chip on each row when a paste holds both, as Replace Older and Skip leave a moved item at its source; and an item kept with Keep Both is numbered by the analysis (in the folder pasted into, as names taken there are) instead of stopping it as "Two of the items are named…". That stop stays for a clash the list didn't settle (a name changed outside the app after it was added), and on a disk that tells case apart (`CopyPasteNames.detectCaseSensitivity`) nothing is numbered that doesn't clash there.

## Steps

One change, in this order, so nothing half-done is ever on screen: a mixed paste can't run until the engine takes a mode per item.

1. **The engine takes a mode per item.** `CopyPasteRequest` and the analysis carry a mode per source path (one mode for the whole request stays the way Copy To, Move To, Duplicate and the panes' F5 and F6 ask). Execution and Replace read the item's mode where they read `context.mode` (about 25 places in `ExecutionNodes`, `CopyPasteReplace`, `CopyPasteAnalysis`, `ExecutionContext`); the journal's `movingCopy` and the Undo log's units are per item already. Same-path and parent-into-child rules are each item's. The review shows a Move or Copy chip on every row of a mixed paste; the progress card, the end notice and Undo's title count both ("Moving 4 and copying 3 items", "Undo Paste 7 Items"). Replace Older and Add Missing keep their meaning per item: what a move leaves stays at its source. `UndoFuzzTests` gain mixed pastes.
2. **The clipboard keeps an intent per item.** `CopyPasteClipboard.ready` holds each path's mode; `ClipboardRules` gains `add` (with the folder rule and the switch), and `follow` works item by item. `ClipboardMarks.mark(for:)` reads the item's own mode. `capturedAt` changes with Copy and Cut only; an Add flashes only what it added. `ClipboardMode` and `CopyPasteMode` are two enums of the same cases (known-issues.md); one of them may go here.
3. **The clipboard list and the toolbar button.** `ClipboardMenuModel` groups by intent, then by folder; a row's mark switches its item. The header counts each intent, the footer says what ⌥⌘V does. The button shows both counts when there are both.
4. **The commands.** Add to Copied Items, Add to Cut Items, Move Items Here, Remove from Clipboard, and, on an item's right-click menu only, Copy Instead of Moving and Move Instead of Copying. Each goes through [process/commands.md](../process/commands.md): the table, `AppCommand`, `CommandAvailability`, the Edit menu (the Adds in the clipboard group, Move Items Here after Paste, Paste's subtitle in `ApplicationMenu.itemStates`), `ContextMenuModel` and `ContextMenuRules`, `TreeFocusBuckets`, the palette, Help's lines and the goldens. The Adds are dimmed where Copy and Cut are, and while a paste of the list runs.
5. **The name check on Add and Put Back,** as above.
6. **Help and features.** Help's Copying and moving topic says how to gather, what ⌘V and ⌥⌘V do and how an item changes intent; features.md gets a line, and the README says it under what differs from Finder.

## Checks

- `ClipboardRules` tests: add, switch, folder and item inside it, following per item, what a paste leaves.
- Engine: analysis and execution of mixed pastes, with conflicts of each kind, across disks, and Undo of them; the fuzz tests.
- The goldens named in process/commands.md, edited by hand.
- In the built app, by a scratch `--automation` scenario (`tools/capture/README.md`): gather from three folders with both Adds, paste with ⌘V and with ⌥⌘V, undo each, rename a cut item in between.
