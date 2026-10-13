# File Trail (native)

A native macOS rebuild of File Trail in Swift and AppKit. The Electron app in
`~/src/tsproj/filetrail` keeps shipping until this one reaches parity.

## Build and run

```bash
scripts/build-app.sh
```

```bash
open "build/File Trail.app"
```

Requires macOS 14 or later and Xcode 16 or later. There is no Xcode project: it's a Swift package,
and `scripts/build-app.sh` wraps the binary in an app bundle with an ad-hoc signature. Because
that signature changes with every build, macOS asks again for access to Desktop, Documents and
Downloads after each rebuild.

Debug options:

- `FILETRAIL_TIMING=1` prints how long each navigation took.
- `--bench <folder>` opens each sub-folder of `<folder>` and goes back, three times, prints median timings and quits.
- `--snapshot <file.png>` draws the window into a PNG after it loads and quits (for when screen recording isn't allowed).

## Spike (2026-10-13)

What's built: a window with a Finder-style sidebar (Favorites, Locations, mounted volumes), a
List view (sortable, reorderable, resizable columns; Name always first; widths saved app-wide),
an Icon view (grid that fills the width, Quick Look thumbnails), Back/Forward/Enclosing Folder,
a name filter in the search field, a status bar with item count and free space, native window
tabs (⌘T, Merge All Windows), and the Go menu's places.

| | Electron (v0.7.0) | Native spike |
|---|---|---|
| App size | 320 MB | 384 KB |
| Memory, idle in Home | ~134 MB in 4 processes | 46 MB in 1 process |
| Open a folder of 3,000 files | ~50–80 ms ¹ | ~51 ms (List), ~45 ms (Icons) ² |
| Back to a small folder | ~50 ms ¹ | ~10 ms (List), ~4 ms (Icons) ² |

¹ Measured 2026-10-08 with Playwright, from double-click until a row appears.
² `--bench` on five folders of 3,000 files: from the start of navigation until the window is
drawn, median of 15 runs.

### What the spike taught

- `localizedNameKey` and `localizedTypeDescriptionKey` cost ~145 ms per 3,000 files (a
  LaunchServices call per file). The content type gives the kind once per type and tells
  packages apart; names come from the file system with hidden extensions removed.
- Free space (`volumeAvailableCapacityForImportantUsageKey`) takes ~17 ms, so it is read after
  the folder is on screen.
- Laying out table cells with frames instead of Auto Layout constraints, and not normalizing
  every URL when nothing is selected, took display time from ~60 ms to ~29 ms.
- What remains of a 3,000-file open is ~22 ms of disk reading, ~12 ms of Finder-style name
  sorting and ~15 ms of table layout. Sorting could move off the main thread next.

### Known gaps

- Folders with localized names (`.localized`) show their file-system names, which matters only in non-English systems.
- Nothing has been hand-tested yet: clicks, keyboard, drag and tabs need a hand test. The checks so far are the benchmark and window snapshots.
