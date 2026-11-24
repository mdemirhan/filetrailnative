# Search conditions

Planned (2026-11-24). A search can have **conditions** (kind, size, dates, tags, attributes, folders left out) beside the text typed. The mocks the owner agreed to are on the design canvas "File Trail search conditions" (https://claude.ai/artifact/8P6aB3jDuBnPG8ip4VunaS, private to the owner).

It is built on the search's own walk of the disk, which replaced fd first (done, 2026-11-24: "Search walks the disk itself" in [names-and-search.md](../decisions/names-and-search.md), the timings in [records/search-walk.md](../records/search-walk.md)). The walk reads a folder's entries with `readdir`, and an item's flag only once it matched, so a condition on what the entries don't hold (size, dates, tags, attributes) is a read of each item the text and the other conditions kept.

## Conditions

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

**What can be taken from the parked branch.** `claude/apple-intelligence-parked` (commit `a3e62231`, see [apple-intelligence.md](apple-intelligence.md)) has a first version of the model and the reads, written for fd, and to be fitted to the walk: `SearchFilters`, `SearchDateFilter`, `SearchAttribute` and `SearchKind` in `Sources/FTFoundation/Search/DescribedSearch.swift`; the per-item reads in `Sources/FTFileSystem/Search/DescribedItemCheck.swift` and `DatesTaken.longerSide`; the chip and its ✕ in `Sources/FTAppKit/Content/Search/DescribedSearchView.swift`; the chips' wording in `DescribedSearchText.swift`; and their tests. Taken over, they lose what is about descriptions.

## Order of work

1. The conditions' model and how the walk applies them: what a folder's entries hold first (kind, extension, folders left out), then one read of each item kept for size, dates and attributes (`getattrlist` or `fstatat`), then Last Opened, tags, Date Taken and picture size, each only for a search that has them. Tests of each.
2. The bar's +, the chips and the editors; the commands, Help and `features.md`.
3. Tried in the app by hand: Home, a disk image, a FAT disk, a folder dropped on the app, every editor; and the release's search timings (`WalkSearchReleaseTests`) with conditions added.

## Done when

- Conditions can be added, changed and taken out as the canvas draws them, from the bar, the Edit menu and the palette, by mouse and by keys, with Help, Settings → Shortcuts and `features.md` updated.
- A search with conditions costs, over the walk alone, what reading the items it kept costs, and no more.
- `scripts/ci.sh --full` passes.
