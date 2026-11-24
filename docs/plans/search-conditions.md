# Search of our own, and search conditions

Planned (2026-11-24). Two parts, in this order: File Trail walks the disk for a search itself instead of running `fd`, then a search can have **conditions** (kind, size, dates, tags, attributes, folders left out) beside the text typed. The second is built on the first. The mocks the owner agreed to are on the design canvas "File Trail search conditions" (https://claude.ai/artifact/8P6aB3jDuBnPG8ip4VunaS, private to the owner).

Both wait on the owner's yes for what they change of standing decisions: "The `fd` binary" in [must-stay.md](../decisions/must-stay.md), and dropping Skip Files Ignored by Git (below).

## Why not fd

fd gives two things: a fast walk of the disk on several threads, and Rust's regex engine, which can't take longer than the name's length. Much of the search code exists to undo or redo what fd does:

- **Hidden items.** fd hides by the name alone, so `HiddenFilter` asks again of every result whether it, or a folder above it, has the flag that hides it.
- **FAT and exFAT.** fd spells names as its folder lists them, so `HeldSpelling` respells each with an accent as the disk holds it, to be the same item as its row.
- **Accents.** fd has to be started with `posix_spawn`, or "é" reaches it decomposed. Plain Text is made into a regular expression of its first 64 characters, as fd refuses one that compiles to more than 10 MB, and the matcher judges each result again.
- **Folders it couldn't read** are found by reading fd's error output line by line.
- **Conditions.** fd can't check dates other than modified, flags, tags or picture sizes, so each item it finds would be read a second time. `--size` leaves out folders and `-e pdf` keeps a folder named `x.pdf`.
- **Results after a write.** "Search results change only where a write acted on them" dropped matching new items in the app, as fd's rules can't be told apart from outside.
- **Shipping it.** A signed helper whose hash a test checks, its licence in Acknowledgements, its version in About, and in the App Store build a helper that has to keep the app's sandbox access, which hasn't been tried.

## What was measured

On this Mac (M-series, 12 performance and 4 efficiency cores), caches warm, two runs each the same within 0.02 s. fd 10.5.0 as bundled, listing files and folders with `--no-ignore --hidden --absolute-path --print0`, against a throwaway C program of the same shape as `foldersize.c`: `getattrlistbulk` on a work queue of folders, reading name, type, size, created, modified and added dates and flags of every item, and printing every path.

| Folder | Items | fd | Ours, 4 threads | 8 threads | 12 threads |
|---|---|---|---|---|---|
| `~/src` | 278,000 | 0.52 s | 0.35 s | 0.38 s | 0.64 s |
| `/Applications` | 658,000 | 0.88 s | 0.81 s | 1.02 s | 2.00 s |

Ours read every attribute the conditions need and was still as fast or faster. It slowed with more threads because the probe had one queue under one lock, taking folders last in, first out; a queue per thread that takes work from others is what the real one should try before choosing the count.

Regular expressions over the 658,000 names, one thread:

| Pattern | `NSRegularExpression` | Swift's `Regex` |
|---|---|---|
| `report` | 0.15 s | 0.36 s |
| `^IMG_\d{4}\.(jpe?g\|heic)$` | 0.12 s | 0.10 s |
| `(?i)lo[ck]al.*\.plist` | 0.17 s | 0.66 s |

About 0.2 µs a name: nothing beside the walk, and spread over its threads.

## Part 1: the walk

A search runs in the app, on a few threads of its own, as the folder-size walk does: `getattrlistbulk` reads a folder's entries and their attributes in one call, a folder found goes on the queue, and a name that matches becomes a result. It takes the place of `FdSearchRuntime` behind `SearchEngine`; `start`, `update` from a cursor and `cancel` stay as they are, and so do the polling once a second and the background-tab behavior in must-stay.md.

What it keeps, as today:

- **Plain Text, Glob and Regex**, matched against the name or the whole path (Match).
  - Plain Text is `NameMatcher`, on the whole text: the 64-character cut goes.
  - Glob is a small matcher of our own (`*`, `?`, `[…]`, `**` across folders in a path).
  - Regex is `NSRegularExpression`, as the highlight and batch rename are, so the three agree on what matches. Its syntax becomes ICU's in place of Rust's; most patterns read the same.
  - Glob and Regex keep smart case: a capital letter in the pattern makes it match case.
- **Search Subfolders** on or off, **hidden items** (a name starting with a dot or with the flag that hides it, and everything inside a folder that is hidden, as `HiddenFilter` decides now), **Skip .git Folders**.
- **"/" is the startup disk alone**, other disks searched from their own top, and nothing found twice through `/System/Volumes/Data`: the folder-size walk already stays on its disk and goes through the firmlinks.
- **Symbolic links are listed by nothing and followed by nothing**; packages are walked into like any folder; archives aren't looked into.
- **Names as the disk lists them**, the same spelling the app's own listing reads with the same call, so a result is the same item as its row.
- **Results stream in**, the search stops at 50,000, Stop stops it, and a folder it couldn't read is noted from the error it gave.

What it drops:

- **Skip Files Ignored by Git** (off unless chosen). Following `.gitignore` as Git does (files in every folder, `!` rules, anchors, `.git/info/exclude`, the global file) is the one large part fd gives for free. Skip .git Folders stays, and Skip a Folder (below) covers `node_modules`, `build` and the like. It can come back later as its own piece of work if it is missed.
- **Rust's regex rules.** In their place, a regular expression gets a time limit, as batch rename's has (`RenamePattern.timeForAllNames`), in CPU time over the whole search: past it the search stops and says the pattern takes too long. ICU's matching tries alternatives in turn, so a pattern like `(a+)+$` can take very long on some names; `enumerateMatches` with `.reportProgress` lets a match be stopped part way.
- **The code that was there for fd:** the bundled binary and its hash test, `FdBinary`, `FdProcess`, `FdSearchArgs`, the NUL-separated output and the error-output reading, `HiddenFilter`, `HeldSpelling`, `PlainTextPattern`'s expression for fd. About 1,300 lines and 11 test files are rewritten or removed.

What has to change with it:

- `docs/decisions/must-stay.md`: the entries for the fd binary, `posix_spawn`, the trailing `"--"` and `HiddenFilter` go (the hidden rule stays, in the walk). `names-and-search.md`: the Plain Text entry (no expression, no 64 characters), smart case, the highlight entry, "Search doesn't look inside archives", and the reason in "Search results change only where a write acted on them".
- About: "Search: fd 10.5.0" goes. `Resources/fd/`, `Resources/Acknowledgements/fd.txt` and its line in `index.json`, `scripts/build-app.sh` (copying and signing the helper), `docs/plans/app-store.md` (the Search row), `docs/app-store-listing.md`, README and `docs/development.md`.

How it is checked:

- While both exist, a test runs fd and the walk over the fixtures (accented names, hidden flags, packages, FAT spellings, unreadable folders, links) in every mode and option and compares what each finds, item for item. It goes with fd.
- A CPU-time test (`CPUTime.measureThread`) guards the walk's speed over a generated tree, as "A few benchmarks gate a release" allows, rather than a bench script.
- A search of the whole disk and of Home tried in the app, timed against fd before it is removed.

## Part 2: conditions

As the canvas draws them. "Conditions", not filters: the results bar already has a filter.

**Where they are.**

- A **+** button in the results bar, after the filter and before Options, opens **Add a Condition**: Kind, Extension, Size, Picture Size; Date Modified, Date Created, Date Added, Date Last Opened, Date Taken; Tags, Attribute ▸ (Hidden, Can Be Run, Read-only, Locked, Empty, Alias, Symbolic Link); Skip a Folder. It is one of the bar's buttons in how it gives up room: the filter keeps its 200 pt.
- Picking one adds its **chip** in a row under the bar, with a default, and opens its editor. The row is there only while there is a chip; it ends with a + and Clear All. A dot on the bar's + says conditions are set, as Options' dot does.
- **Edit ▸ Add Search Condition…** (under Find Files… and Show Last Search Results) opens the same menu, starting a search in the pane if none is open; **Clear Search Conditions** takes them all out. Both in the palette and Help, with no key by default (`docs/process/commands.md`).

**How they behave.**

- A chip reads as a sentence: "Kind is PDF", "Size is larger than 10 MB", "Modified within the last 2 weeks", "Not locked". A click opens its editor, a popover of the system's controls; every change searches again at once, with no Apply. ✕ takes it out.
- An item is found when it meets every condition and the text. The field can be empty when there is a condition: everything in the scope that meets them is found.
- Conditions belong to the search. They stay when the text, the scope, Match or Match As change, and go when the search is closed. They aren't saved with the pane, as results aren't; Show Last Search Results brings them back with the search.
- Keys: Tab reaches the chips from the bar's buttons, ← → go from chip to chip, Space or Return opens one, ⌫ takes it out, Esc closes the editor and keeps what it says. VoiceOver reads a chip as its sentence, with Remove as an action.

**Each editor.**

| Condition | Editor | Read from |
|---|---|---|
| Kind | Any of: PDF, Picture, Video, Audio, Document, Spreadsheet, Presentation, Archive, Code, Text, Folder, Application | The name's extension and the folder's type, as today's kinds |
| Extension | Any of, typed as tokens, without the dot | The name |
| Size | is larger than, is smaller than, is between; KB, MB, GB. Leaves out folders | The walk (`ATTR_FILE_DATALENGTH`) |
| Picture Size | the longer side is larger or smaller than N px, with HD, 4K and 8K. Only pictures meet it | ImageIO, of pictures only (`DatesTaken.longerSide`) |
| Date Modified, Created, Added | is today, yesterday, this week, this month, this year; within the last N days, weeks, months, years; more than N … ago; before, after, between dates | The walk (`ATTR_CMN_MODTIME`, `CRTIME`, `ADDEDTIME`) |
| Date Last Opened | as above; never opened counts as long ago | The system's last-used date of each item, read only when asked |
| Date Taken | as above | The picture's metadata (`DatesTaken.takenDate`), of pictures only |
| Tags | Any of or all of Finder's tags, as Settings → Tags lists them | The item's tags (`FinderTags.read`), read only when asked |
| Attribute | the attribute, Is or Is not. Read-only takes in locked items; Empty is a folder with nothing in it or a file of no bytes; Alias is a Finder alias | The walk (flags, `ATTR_CMN_USERACCESS`, Finder info, a folder's entry count) |
| Skip a Folder | names, as tokens, with names of folders the search has passed suggested | The walk: a folder of that name isn't gone into |

What the walk reads costs nothing more. Last Opened, Tags, Date Taken and Picture Size are read of each item only for a search that has them, and only of items that met every other condition first; while they are read the status line says so ("Reading dates taken and sizes · 1,204 of 3,880 pictures").

**What can be taken from the parked branch.** `claude/apple-intelligence-parked` (commit `a3e62231`, see [apple-intelligence.md](apple-intelligence.md)) has a first version of the model and the reads, written for fd: `SearchFilters`, `SearchDateFilter`, `SearchAttribute` and `SearchKind` in `Sources/FTFoundation/Search/DescribedSearch.swift`; the per-item reads in `Sources/FTFileSystem/Search/DescribedItemCheck.swift` and `DatesTaken.longerSide`; the chip and its ✕ in `Sources/FTAppKit/Content/Search/DescribedSearchView.swift`; the chips' wording in `DescribedSearchText.swift`; and their tests. Taken over, they lose what is about descriptions.

## Order of work

1. The walk behind `SearchEngine`, with the comparison test against fd passing in every mode.
2. fd removed, with the docs and decisions above.
3. The conditions' model and how the walk applies them, with tests of each.
4. The bar's +, the chips and the editors; the commands, Help and `features.md`.
5. Tried in the app by hand: a whole-disk search, Home, a disk image, a FAT disk, a folder dropped on the app, every editor.

## Open for the owner

- Replacing fd: "The `fd` binary" is in must-stay.md.
- Dropping Skip Files Ignored by Git, or keeping it as a later piece of work.
- How many threads the walk uses: chosen by measuring, unless the owner wants it kept to the folder-size walk's 4 for the battery's sake.

## Done when

- Every search runs without fd, finds what fd found in the comparison test, and is as fast as fd on Home and the disk on this Mac.
- Conditions can be added, changed and taken out as the canvas draws them, from the bar, the Edit menu and the palette, by mouse and by keys, with Help, Settings → Shortcuts and `features.md` updated.
- `scripts/ci.sh --full` passes.
