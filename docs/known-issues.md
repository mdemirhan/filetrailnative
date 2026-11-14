# Known issues

Limits and open issues, by area; what was fixed is in the history. Background work that may affect battery is in [battery.md](battery.md).

## Folder icons

A folder holding something shows Finder's sheet of paper, read from the folder's count on APFS and HFS+ when the folder around it is listed. That leaves some folders different from Finder:

- **Only hidden items**: a folder with nothing but a `.DS_Store` or a `.git` has the sheet. Finder's draws it as empty, at least as Quick Look does; telling them apart would mean opening every folder.
- **Other disks**: every folder has the sheet, empty or not, as their counts aren't relied on.
- **Changes inside a folder**: the icon changes when the folder around it is next read, not as they happen.
- **The tree, Info for the current folder and the clipboard list**: these don't know the count, so every plain folder has the sheet.

## Copy, Cut and Paste of files stay inside File Trail

File Trail keeps the files you copy or cut on a clipboard of its own, by design: the one the toolbar's clipboard button lists. So files copied or cut in File Trail can't be pasted in Finder or other apps, and files copied in Finder or another app can't be pasted in File Trail. Drag them between apps instead. Copy Path puts the paths on the system's clipboard as text, and text in fields is copied and pasted as anywhere else. An image or text copied in another app can be saved as a new file with Edit ▸ Paste as File (⇧⌘V), and the image or text of a file put on the system's clipboard with Edit ▸ Copy Contents (⇧⌘C).

Paste as File leaves two things for later:

- **Only into the folder on screen.** It isn't offered on a folder of the list or the tree, and ⌘V with nothing copied in File Trail doesn't point to it.
- **A file stopped half written** (File Trail quit or crashed while it was being filled) stays next to where it was going, hidden, as `.<id>.filetrail-partial`. Nothing cleans it up at the next start.

Copy Contents leaves these for later:

- **One file at a time.** Several images could go on the clipboard together, as Notes and Keynote paste them.
- **PDFs aren't copied**, as a picture of a page or as their text.
- **Text in another encoding** (Latin-1, Windows-1252, Shift JIS) is refused rather than guessed.
- **A WebP, AVIF or camera RAW copied and saved again with Paste as File comes back as PNG**: Paste as File keeps only PNG, JPEG, HEIC and GIF as they are.

## The Trash across disks

The Trash lists what is in the Trash of every local disk (`TrashFolders`), as Finder's does. Two things still see only the home folder's:

- **Its size**: Show Info on the Trash, and the Trash's row with folder sizes on. The status bar leaves the size out while other disks' items are listed.
- **Search from the Trash**: it searches the home folder's Trash only. A filter of the list covers every disk.

There is no Put Back, on any disk.

### Finder's Trash can leave out what File Trail trashed on another disk

What File Trail moves to the Trash on a disk other than the startup disk can be missing from Finder's Trash, though it is in the disk's Trash folder and File Trail's Trash lists it. Finder's Empty Trash, which File Trail's Empty Trash asks for, then leaves it there.

To bring such a disk into Finder's Trash, do one of these once:

- Eject the disk and mount it again.
- Move something on that disk to the Trash from Finder.

Finder then shows and empties everything in that disk's Trash, including what was already there. File Trail does neither of these for you: see the workaround below.

What we found, on macOS 27 (Finder 27.0) with APFS disk images:

- Finder shows a disk's Trash only once it has taken that disk on. It does so when it moves something to the Trash there, or when the disk is mounted with this user's Trash folder (`.Trashes/<uid>`) already on it. It stayed that way across a remount.
- `FileManager.trashItem`, which File Trail uses, doesn't make Finder take a disk on. Neither do `NSWorkspace.recycle`, `NSWorkspace.noteFileSystemChanged` or Finder's `update` command. This explains two disks behaving differently: one taken on and one not. We didn't establish how the first disk in the original report was taken on.
- Finder marks the disk's Trash folder hidden when it takes it on (`UF_HIDDEN`, and the invisible bit in `com.apple.FinderInfo`). The mark is a result, not the cause. Setting it by hand doesn't make Finder show the disk, and clearing it doesn't make Finder forget the disk. A remount sets it again.
- Finder's `delete` follows a symlink: asked to delete a link, it trashed the link's target and left the link in place. Nothing of anyone's should be sent through it without guarding against this.

### A workaround we tried and didn't keep

[`finder-trash-workaround.diff`](finder-trash-workaround.diff) has the implementation, with its tests, made against commit `afa0076`. It doesn't apply to later commits, so try it on that one: check it out (`git switch --detach afa0076`), then run `git show main:docs/finder-trash-workaround.diff | git apply`. The diff isn't in that commit, hence `git show`.

Before Finder has taken a disk on, File Trail makes an empty hidden file there, has Finder trash it with AppleScript, and removes it from the Trash. People's own items still go through `trashItem`, so the symlink problem doesn't reach them. This runs in the background after the move, so no delete waits for Finder, and Empty Trash runs it first, for disks whose Trash holds items.

It worked: on a new disk in the built app, trashed items appeared in Finder's Trash very quickly. The request took about 0.2 s from a standalone program. Under `swift test` the same request took between 4 and 125 s while Finder's main thread sat idle. We didn't find out why, and it didn't happen in the app. A test that sends real requests to Finder may run into it.

We decided against it for now, because it:

- makes a fake file to set off behavior Apple doesn't document, which a macOS update could change
- tells a disk Finder knows by the hidden mark, which is undocumented too
- needs permission to control Finder for something as plain as a delete


## Open issues found in the code

Found by reading the code and confirmed there; not fixed yet.

- **A read that never answers keeps a thread.** Listings, details and item lookups run on the shared pool (`Listing/DirectoryService.swift`); a disk that hangs for good holds one of its threads per read, and enough of them (16 here) would stop every listing. Blocking reads on a queue of their own would end that.
- **A tab added unread with the Info panel open asks for its item.** Merge All Windows and the tabs brought back at launch wait unread until they are shown; with the Info panel open, each still asks the disk for its folder's details as it is added.
- **A moved folder that can't be read once its items are gone is taken for gone.** After a move to another disk, the emptied original is looked at before it is removed (`tryRemoveEmptySourceDirectory`, `Execution/ExecutionMoves.swift`); one that can't be read just then is left where it is without a word.
- **A new folder inside a merge that a full disk ends has no line of its own in the result**, as with a Stop: its items are listed, not the folder.
- **Always Open With answered by macOS after File Trail stopped waiting** (10 s) says "macOS didn't answer.", and the apps listed for that kind stay as they were until the window is next brought forward (`OpenWithCatalog`).
- **Stop on a folder size just as it finishes** shows no size until the folder is asked about again: the window forgets the answer the job already has (`WindowFolderSizes.cancel`).
- **Quick Look open while another window comes forward** keeps its panel but shows no item there.
- **A state file that can't be written as JSON** logs the failure again at every later save (`AppStateStore`).
- **The sign in a toast's icon is drawn in the menu's background color**, as the opaque card had it; on glass it should be cut out of the disc.
- **Each key press in the sidebar builds the tree's rows again** (`SidebarModel.keyContext`).
- **One menu test may depend on the tests before it**: `CommandRoutesTests`' check that the menu reads the window it is asked about was seen to fail when all of FTAppKitTests ran in one process (the menu falls back to the window in front). `scripts/ci.sh` runs it in its own group, where it passes; it hasn't been tried in one process since the tests were regrouped.
- **In the code**: `Metrics` has members only its tests read; `ClipboardMode` and `CopyPasteMode` are two enums with the same cases, and `WriteOperationOutcome`/`WriteOperationProgress` might give way to `WriteOperationEvent`; `SidebarIcons.symbol` and `drawFavorite` repeat `SymbolGlyph`, but draw a translucent color differently.

## Why there is no Put Back

Looked into on 2026-11-01 and decided against for now: a put back leaves a stale entry in the Trash's `.DS_Store`, and later deletes could then have an unintended effect. Removing the entry would mean changing `.DS_Store`, which is dangerous: Finder writes that file too, and our writes might need coordinating with its own, which could get tricky.

What the original locations look like, from trashing test files on a disk image:

- **Where they are**: there is no public API and the items carry no xattr for it. Each Trash folder's `.DS_Store` has two records per item, under its name in the Trash: `ptbL`, the original folder relative to the disk (`/sub/deep/`), and `ptbN`, the original name. So a renamed `api.txt 12-12-06-924.txt` has `ptbN` `api.txt`.
- **Who writes them**: both `FileManager.trashItem` and Finder's delete. The former's were there at once; Finder's weren't after 3 seconds and were a few seconds later.
- **What has none**: an item moved in with `mv`, and an item inside a trashed folder (only the folder has a record).
- **Stale records**: they stay after the item leaves the Trash, and are matched by name alone. A file then moved in by `mv` under the same name picked up the old location.

Reading is simple, about 40 lines of script for the B-tree in `.DS_Store`, and restoring could start from Undo's `PlannedMove(putBack: true)`, which also requires the original parent's id. Not checked: the home folder's Trash, which needs Full Disk Access to read and may spell its paths differently; whether Finder offers Put Back for `trashItem`'s items; and what Finder does when the original folder is gone or a record is stale.

## "._" files on FAT, exFAT and some network disks

These disks can't keep a file's extra attributes (Finder tags, the downloaded-from-the-internet mark, a custom icon, a resource fork), so macOS keeps them in a hidden companion beside each item: `._name` beside `name`, in AppleDouble format. Finder neither lists nor counts these; File Trail does:

- **Folder sizes count them**: a companion usually takes a 4 KB block, so a folder of small files measures far more than in Finder. A folder holding a 5-byte and a 3-byte file, with a subfolder, measured 12,296 bytes in 5 files here and 8 bytes in Finder's Info window.
- **With hidden files shown**, the list, the tree and Go To's suggestions show them.

Copy, Cut and Paste already treat them as part of their item, so nothing is lost or left behind.

If this is picked up: the disk says whether it keeps attributes this way (`getattrlist`, `VOL_CAP_INT_EXTENDED_ATTR`, as `NativeFS.usesAppleDouble` asks), and there a `._x` beside `x` holds `x`'s attributes. A listing can match that against the names it already read, with no extra disk call per file. The folder-size walker needs one lookup per `._` entry, and should ask about the disk once per walk. The paste engine's check also reads each file's AppleDouble header; a listing shouldn't, as that would be one small read per file on a slow USB stick.
