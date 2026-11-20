# Decisions: must stay

Part of the owner's decisions: [the index](../decisions.md) lists the other parts.

Things that look removable and are not. Don't change them; if a change seems to need it, ask the owner first. Each has beside it what would break or be lost without it; "(inferred)" marks a reason worked out from the code and written down nowhere else.

## Write engine

- **The coordinator's write slot**: one write at a time for the whole app, so Undo's history is in the order the operations ran, and no two operations work on the same items at once (inferred).
- **Hidden-name staging**: a Replace builds the new item under a hidden name beside the old one and swaps only once it is whole, so a failure, a Stop or a crash never leaves the person with neither item. A staged folder and a Replace share one routine (`stageThenPlace`); a Stop as the last item is written clears a staged folder away and lets a Replace finish, on purpose.
- **The journal**: written before anything is staged, so the next start finishes or undoes what a crash cut short, and a moved item's only copy is never left under a hidden name.
- **The `isStagingName`/`isTemporaryName` checks before recovery touches anything**: recovery removes or moves only what has this app's hidden naming; a damaged or stale journal entry could otherwise point it at someone's own file.
- **`renamex_np(RENAME_EXCL)` everywhere, with the ask-again loop**: a plain rename replaces whatever took the name since it was checked; exclusive rename fails instead, and the loop asks again.
- **`removeEmptyFolder`'s read before `rmdir`**: on macOS `rmdir` also removes a folder holding only "._name" files, deleting them, and such a file may be someone's item.
- **Replace's re-check after staging**: staging a large copy takes a while, and the item sent to the Trash must still be the one agreed to, not one an app saved in its place meanwhile.
- **The counted and lock-scanned permanent delete** (a Replace on a disk without a Trash): an item added to the folder since the review would be lost unseen, with no Trash to get it back from, and a locked item inside stops the delete half way.
- **Never offering delete-for-good on the startup disk or for an unexplained Trash failure** (`Native/TrashItem.swift`): only a disk known to have no Trash is a reason to delete instead; any other failure may be passing, and the offer would lose what the Trash could have kept.
- **The replace-safety checks, made at review and again at run time**: the disk can change between the review and the paste, and the checks guard a destination someone else could have made since.
- **`assertNotWrittenByThisPaste`**: on a disk that takes "A.txt" and "a.txt" for one name, the second item would replace the first, which this paste just wrote and whose original a move has already removed.
- **The `copyfile` status callback in `Sources/CFileTrail/copyfile.c`**: it is how a large file is stopped part way and shows progress, and how a failed write ends the copy; without it copyfile retries a write on a full disk forever, and goes on past a resource fork it couldn't write, after which a move removes the original.
- **The large-file tests**: the only tests of a copy stopped inside a file with nothing left half written, and of a full disk failing the copy where it once hung.
- **Undo and Redo as they are**, but for one thing (2026-11-20): an operation that can't be undone no longer empties the history ("An operation that can't be undone stays in the Undo history" in [file-operations.md](file-operations.md)). They never lose or replace an item and say why each item left as it was is left; the fuzz tests hold them to that (inferred).
- **`UndoFuzzTests`, `BatchRenameFuzzTests`**: random operations with failures, stops and changes made outside the app, checking that no item is lost or replaced; hand-written cases don't reach those orders, and a failure names its seed.
- **No paste review starts while a write runs, and only one runs at a time**: a review describes the disk as it will be when its paste runs; a write or another review under way would make it wrong (inferred).
- **The rules that keep the app's clipboard truthful** (`ClipboardRules`): the clipboard follows its items as they are moved, renamed or removed, so the clipboard button lists what Paste will really take.

## Names and paths

- **Byte-exact path comparison (`sameText`, `NameKeys.Exact`)**: Swift's `==` and hashing treat NFC and NFD as equal, so two names a disk keeps apart would count as one item. A path is kept as the disk spells it, a string from a listing or `realpath`, and never read back from a `URL`: `URL(fileURLWithPath:).path` gives an accent decomposed whatever the disk stores, so it no longer matches the rows' paths byte for byte. A pane's folder is `BrowserPane.folderPath`, never `folder.path` (2026-11-20: read from the URL, a folder stored with a composed accent matched none of its own rows, and New Folder with Selection, Extract, the other pane and the tree all went wrong there). `scripts/ci.sh` fails on a new readback it can tell from the text (`scripts/lib/path-readbacks.sh`); the ones there are, each with its reason, are in `scripts/lib/url-path-readbacks.txt`.
- **`expandReplacement`**: batch rename's replacement syntax (`$1`, `$&`, `$<name>`, `$$`), which `NSRegularExpression`'s own templates spell differently; saved presets hold it.
- **`expandReplacement`**: `$1`, `$&` and `$<name>` in a batch rename's replacement text; it stays whichever engine matches.
- **`NodePath`**: `basename`, `dirname`, `extname` and `join` scalar for scalar; Foundation's path methods normalize names, and the name is kept as renaming it is large ([code.md](code.md)). The first part is inferred.
- **`CopyPasteNames.detectCaseSensitivity`**: some disks can't say whether they tell "A" from "a"; the probe finds out, and a wrong answer means a missed clash or a needless "copy" name.

## Search

- **The `fd` binary**: every search runs as an `fd` process; it ships in the app and a test checks its hash.
- **`FdProcess`'s `posix_spawn`**: Foundation's `Process` would pass "é" decomposed, and a query typed as "é" would no longer find a file named so.
- **The trailing `"--"` in its arguments**: a query starting with "-" (such as "-xrm") would be read as an option of fd.
- **`HiddenFilter`**: fd hides by name alone; items with the hidden flag, or inside a folder that has it, would show in results.
- **The polling of a running search and the background-tab behavior** (one poll a second, search again on return): a search in a background tab keeps going at little cost ([battery.md](../state/battery.md)), and a tab shown again searches what was typed meanwhile.

## Windows and UI

- **FSEvents for folder watching**: the only thing that tells a folder on screen of a change made outside the app; its cost is measured in [battery.md](../state/battery.md).
- **`ExplorerWindows.reconcile()`**: after the system's tab bar moves a tab between windows, it makes each native tab group one explorer window again; without it saved sessions and the 25-tab limit go wrong.
- **`adopt`/`absorb`**: a tab dragged out becomes a window with the panels and size of the one it left; a window whose tabs were dragged into another closes without asking and isn't remembered as the window closed last.
- **The `ExplorerWindowLike` generic with `FakeWindow`**: the window controller's tests run on stand-in windows whose events are fired by hand; real windows would make them slow and timing-dependent (inferred).
- **`WorkspaceSplitView`/`WorkspaceSplitController`**: the split would draw a divider and claim about 5 pt around it, over the pane resizers, with its own cursor and a drag that moves nothing.
- **`FileRefusingFieldEditor`**: files dropped on a text field would type their paths in; unregistering the type instead would pass the drag to whatever is behind the field.
- **`FirstClickGate`**: the click that brings a window forward would also clear a selection, navigate or run a command; `acceptsFirstMouse` alone isn't enough.
- **`SecondInstance`**: a second copy started by hand would run beside the first; it tells the running one to come forward, and quits.
- **`RenameDrafts`**: the list redraws a row when it moves (a re-sort, an item added), replacing the field; what was typed into a rename would be lost.
- **`ExplorerToolbar`'s `applying`/`commitPending` flags**: the toolbar set from the preference would be saved back as a change by the user, and one drag would save several times before the toolbar settled.
- **`ContextMenuSession` holding itself on its menu**: nothing else holds the session; it would be gone before an item is chosen.
- **`holdingTheTab`**: the window can close before the system answers (Open With, Show in Finder), and what follows reads the tab.
- **`SidebarModel`'s request numbering**: numbered across the whole tree, so an old answer can never look like a new one after the requests under way are forgotten (a new root, another tab).
- **`WriteStartingShortcuts.runs(… isRepeat:)`**: a held key would start a file operation, or open a Terminal window, on every repeat.
- **Glass only on toasts, the progress card and plain alerts; sheets, Go To and alerts with lists or fields stay opaque**: glass behind lists and fields lets colorful content smear behind the text.
- **`PlainLabel` and the search field's `SearchTextCell` drawing their own text**: AppKit draws a translucent label or placeholder color twice, and their tests fail if a later macOS stops doing so.
- **Accessibility identifiers and `accessibilityPerformPress()`**: the tests and the screenshot tool find and press views through them.

## State and preferences

- **The `density` migration**: releases v0.8 to v0.15 wrote the four `compact*` keys; without it their sizes setting is lost on upgrade.
- **`PreferencesSanitizer.sanitize`**: a damaged or hand-edited state file must not block launch; each bad value takes its default.
- **`@NullEncoded`**: writes an absent value as `null`, not a missing key, which is part of the file format below.
- **The app-state file format**: a file written by an earlier release must read back the same, and the other way; `AppStateRoundTripTests` and `prefs-sanitize.json` guard it.
- **Coalescing of preference writes to disk while a continuous control is dragged** (the color panel): one write for a burst, not one for every step of the drag.

## Build, tests and tools

- **The `vtool` restamp in `build-app.sh`**: SwiftPM stamps the deployment target (26.0) as the SDK too, and macOS gives an app stamped with an old SDK the old look.
- **`FTTestSupport` as a regular target**: all four test bundles share its goldens, snapshots and temporary folders, and a SwiftPM test target can't depend on another test target (inferred).
- **The release-script tests**: `release.sh` and `build-app.sh` run only at a release; these run their rules (versions, tags, frame-time limits) on every CI run, with stand-ins for the tools (inferred).
- **`AppClock` and `FILETRAIL_NOW`**: freeze "now" so relative dates ("Today at 14:38") are the same in every screenshot and capture.
- **The read-only test seams** (`jobCount`, `watchedPaths`, `rowViewsShown` and the like): each is a test's only way to see something.
- **`ElementFinder`, `MouseEvents`, `KeyEvents`, `AutomationPrefs`, `AutomationDraggingInfo`/`AutomationDrag`**: many tests press things through them.

## No reason found

- **The app's own clipboard** for file Copy, Cut and Paste, not the system's. It is a standing decision of the owner's ([the index](../decisions.md)) with no reason written. Looked in: `docs/decisions.md`, `left-out.md`, `file-operations.md`, `docs/state/known-issues.md`, `docs/records/clipboard-shelf.md`, the code's comments, and the audit plan in git history (`74a79ee6^:docs/audit-plan-master.md`, decision 3).
