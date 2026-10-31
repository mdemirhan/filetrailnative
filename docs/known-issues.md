# Known issues

Nothing is open from the port from Electron: what was fixed is in the history, and what stays different on purpose is in [differences-from-electron.md](differences-from-electron.md). Background work that may affect battery is in [battery.md](battery.md).

## Not yet checked by hand

These have tests, which can't show all of what a person gets:

- **VoiceOver in the sidebar**: rows, levels, disclosure and the lists' names, by listening. The rows are the app's own accessibility elements (`SidebarAccessibility.swift`), not AppKit's.
- **Always Open With**: holding Option with the menu open, once macOS has answered and while it does.
- **Scroll wheel in a marquee**: a real wheel and a trackpad.
- **The row of tag colors in a menu**: pointing at a color and clicking it in a real menu; the tests press it through accessibility, and a capture can't show a native menu.
- **Drop from another File Trail window**: a real drag, that the target window comes forward for its dialog.

## Folder icons

A folder holding something shows Finder's sheet of paper, read from the folder's count on APFS and HFS+ when the folder around it is listed. That leaves some folders different from Finder:

- **Only hidden items**: a folder with nothing but a `.DS_Store` or a `.git` has the sheet. Finder's draws it as empty, at least as Quick Look does; telling them apart would mean opening every folder.
- **Other disks**: every folder has the sheet, empty or not, as their counts aren't relied on.
- **Changes inside a folder**: the icon changes when the folder around it is next read, not as they happen.
- **The tree, Info for the current folder and the clipboard list**: these don't know the count, so every plain folder has the sheet.

## The Trash across disks

The Trash lists what is in the Trash of every local disk (`TrashFolders`), as Finder's does. Three things still see only the home folder's:

- **Its size**: Show Info on the Trash, and the Trash's row with folder sizes on. The status bar leaves the size out while other disks' items are listed.
- **Search from the Trash**: it searches the home folder's Trash only. A filter of the list covers every disk.
- **The tree**: a `.Trash` row, with hidden files shown, opens the home folder's alone.

There is no Put Back, on any disk.

## Tests to watch

`aChangeToTheFolderBeingLeftIsDropped` failed once in a full run on a busy Mac: one more read of the folder being left than its baseline (2026-10-31). Cause unknown.

`detachesWhatAProcessThatIsGoneLeftAttached` failed once in a full run while other builds ran: `hdiutil attach` exited with an error (2026-10-31). Cause unknown; it passed in every other run.

Crashes of the test processes that happened once and haven't come back, cause unknown; `scripts/ci.sh` now keeps the logs of a failed run and names its crash reports:

- `FTAppKitTests`: `WindowWriteActions.coordinator` read an `unowned` value that had gone (2026-10-30 12:39).
- `FTAppKitTests`: an exception during view layout, `NSApplication._crashOnException` (2026-10-30 14:59 and 15:01).
- `FTAppKitTests`: a bad access running a job on the main queue (2026-10-30 20:21).
