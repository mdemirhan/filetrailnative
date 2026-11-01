# Known issues

Nothing is open from the port from Electron: what was fixed is in the history, and what stays different on purpose is in [differences-from-electron.md](differences-from-electron.md). Background work that may affect battery is in [battery.md](battery.md).

## Folder icons

A folder holding something shows Finder's sheet of paper, read from the folder's count on APFS and HFS+ when the folder around it is listed. That leaves some folders different from Finder:

- **Only hidden items**: a folder with nothing but a `.DS_Store` or a `.git` has the sheet. Finder's draws it as empty, at least as Quick Look does; telling them apart would mean opening every folder.
- **Other disks**: every folder has the sheet, empty or not, as their counts aren't relied on.
- **Changes inside a folder**: the icon changes when the folder around it is next read, not as they happen.
- **The tree, Info for the current folder and the clipboard list**: these don't know the count, so every plain folder has the sheet.

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

[`finder-trash-workaround.diff`](finder-trash-workaround.diff) has the implementation, with its tests, made against commit `afa0076`. To try it, run `git apply docs/finder-trash-workaround.diff`. It may need adjusting on later commits.

Before Finder has taken a disk on, File Trail makes an empty hidden file there, has Finder trash it with AppleScript, and removes it from the Trash. People's own items still go through `trashItem`, so the symlink problem doesn't reach them. This runs in the background after the move, so no delete waits for Finder, and Empty Trash runs it first, for disks whose Trash holds items.

It worked: on a new disk in the built app, trashed items appeared in Finder's Trash very quickly. The request took about 0.2 s from a standalone program. Under `swift test` the same request took between 4 and 125 s while Finder's main thread sat idle. We didn't find out why, and it didn't happen in the app. A test that sends real requests to Finder may run into it.

We decided against it for now, because it:

- makes a fake file to set off behavior Apple doesn't document, which a macOS update could change
- tells a disk Finder knows by the hidden mark, which is undocumented too
- needs permission to control Finder for something as plain as a delete


## Why there is no Put Back

Looked into on 2026-11-01 and decided against for now: a put back leaves a stale entry in the Trash's `.DS_Store`, and later deletes could then have an unintended effect. Removing the entry would mean changing `.DS_Store`, which is dangerous: Finder writes that file too, and our writes might need coordinating with its own, which could get tricky.

What the original locations look like, from trashing test files on a disk image:

- **Where they are**: there is no public API and the items carry no xattr for it. Each Trash folder's `.DS_Store` has two records per item, under its name in the Trash: `ptbL`, the original folder relative to the disk (`/sub/deep/`), and `ptbN`, the original name. So a renamed `api.txt 12-12-06-924.txt` has `ptbN` `api.txt`.
- **Who writes them**: both `FileManager.trashItem` and Finder's delete. The former's were there at once; Finder's weren't after 3 seconds and were a few seconds later.
- **What has none**: an item moved in with `mv`, and an item inside a trashed folder (only the folder has a record).
- **Stale records**: they stay after the item leaves the Trash, and are matched by name alone. A file then moved in by `mv` under the same name picked up the old location.

Reading is simple, about 40 lines of script for the B-tree in `.DS_Store`, and restoring could start from Undo's `PlannedMove(putBack: true)`, which also requires the original parent's id. Not checked: the home folder's Trash, which needs Full Disk Access to read and may spell its paths differently; whether Finder offers Put Back for `trashItem`'s items; and what Finder does when the original folder is gone or a record is stale.
