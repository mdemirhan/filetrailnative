# Known issues

Nothing is open from the port from Electron: what was fixed is in the history, and what stays different on purpose is in [differences-from-electron.md](differences-from-electron.md). Background work that may affect battery is in [battery.md](battery.md).

## Not yet checked by hand

These have tests, which can't show all of what a person gets:

- **VoiceOver in the sidebar**: rows, levels, disclosure and the lists' names, by listening. The rows are the app's own accessibility elements (`SidebarAccessibility.swift`), not AppKit's.
- **Always Open With**: holding Option with the menu open, once macOS has answered and while it does.
- **Scroll wheel in a marquee**: a real wheel and a trackpad.
- **Drop from another File Trail window**: a real drag, that the target window comes forward for its dialog.

## Tests to watch

`aChangeToTheFolderBeingLeftIsDropped` failed once in a full run on a busy Mac: one more read of the folder being left than its baseline (2026-10-31). Cause unknown.

Crashes of the test processes that happened once and haven't come back, cause unknown; `scripts/ci.sh` now keeps the logs of a failed run and names its crash reports:

- `FTAppKitTests`: `WindowWriteActions.coordinator` read an `unowned` value that had gone (2026-10-30 12:39).
- `FTAppKitTests`: an exception during view layout, `NSApplication._crashOnException` (2026-10-30 14:59 and 15:01).
- `FTAppKitTests`: a bad access running a job on the main queue (2026-10-30 20:21).
