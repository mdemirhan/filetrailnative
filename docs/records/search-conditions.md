# Search conditions

Planned and built (2026-11-24), then built again as words typed in the search before it was released: what was decided is "A search's conditions are typed in its text" in [names-and-search.md](../decisions/names-and-search.md).
The + in the results bar, the chips and their editors this plan describes were replaced by it;
the walk and the condition model stand.
Picture Size and Date Taken, which this plan lists, were taken out before release (2026-11-25, the same entry says why).
A search can have **conditions** (kind, size, dates, tags, attributes, folders left out) beside the text typed.
The mocks the owner agreed to are on the design canvas "File Trail search conditions" (https://claude.ai/artifact/8P6aB3jDuBnPG8ip4VunaS, private to the owner).

It is built on the search's own walk of the disk (done, 2026-11-24: "Search walks the disk itself" in [names-and-search.md](../decisions/names-and-search.md)).
The walk reads a folder's entries with `readdir`, and an item's flag only once it matched, so a condition on what the entries don't hold (size, dates, tags, attributes) is a read of each item the text and the other conditions kept.

## As built (2026-11-24)

What shipped, where this plan and what follows it differ: the decisions are "A search's conditions are typed in its text", "How a search's words combine, and what they say" and "Plain Text search finds what the filters find, word by word" in [names-and-search.md](../decisions/names-and-search.md).

- **Words in the toolbar's field**, tinted as typed (`SearchQuery`, `SearchQueryTint`).
  The list under the toolbar (`SearchFieldDropdown`, `SearchSuggestionsView`) offers a condition's values, every word in an empty field or after a condition, and Syntax Help;
  nothing is highlighted once what is typed reads as it is.
- **Advanced Search…** (⌥⌘F, and a button at the field's end; built as Edit Search… and renamed before it was released) opens the search in a box (`AdvancedSearchBox`): its text wraps, it says how the search reads, its buttons type each word, and its list offers only values.
- **The field** is 200 points, 380 while typed in, and once its text outgrows that, as wide as reaches back and forward (`ExplorerToolbar.growSearchFieldIfLong`);
  the system's own limit of 325 points is lifted (`liftSystemSearchWidthLimit`).
- **Words**: a space is AND, a comma OR, `!` not, double quotes a phrase (`NameTerms`) or a tag's or folder's name with a space (`tag:"To Do"`);
  a size alone is that size to its last digit;
  `perm:` takes digits or `ls` letters, with `?` for any.
- **The walk** checks the cheapest first: folders skipped as listed;
  the name, a kind and an extension from the listing;
  then the one `fstatat` the walk makes of an item it keeps, which size, permissions, locked and the dates modified and created read;
  one `listxattr` that says whether an item has tags or a date last opened at all;
  then the date added, an alias, `access` and an empty folder.
  A folder skipped is named as Plain Text names one, and is asked first of all.
  Measured on an M-series Mac: `fstatat` free to the check, `listxattr` 1.7 µs, `getxattr` 15 µs, `access` 8 µs, a folder opened 20 to 45 µs.

## Conditions

As the canvas draws them.
"Conditions", not filters: the results bar already has a filter.

**Where they are.**

- A **+** button in the results bar, after the filter and before Options, opens **Add a Condition**: Kind, Extension, Size, Picture Size;
  Date Modified, Date Created, Date Added, Date Last Opened, Date Taken;
  Tags, Attribute ▸ (Hidden, Can Be Run, Read-only, Locked, Empty, Alias, Symbolic Link);
  Skip a Folder.
  It is one of the bar's buttons in how it gives up room: the filter keeps its 200 pt.
- Picking one adds its **chip** in a row under the bar, with a default, and opens its editor.
  The row is there only while there is a chip;
  it ends with a + and Clear All.
  A dot on the bar's + says conditions are set, as Options' dot does.
- **Edit ▸ Add Search Condition…** (under Find Files… and Show Last Search Results) opens the same menu, starting a search in the pane if none is open;
  **Clear Search Conditions** takes them all out.
  Both in the palette and Help, with no key by default (`docs/process/commands.md`).

**How they behave.**

- A chip reads as a sentence: "Kind is PDF", "Size is larger than 10 MB", "Modified within the last 2 weeks", "Not locked".
  A click opens its editor, a popover of the system's controls;
  every change searches again at once, with no Apply. ✕ takes it out.
- An item is found when it meets every condition and the text.
  The field can be empty when there is a condition: everything in the scope that meets them is found.
- Conditions belong to the search.
  They stay when the text, the scope, Match or Match As change, and go when the search is closed.
  They aren't saved with the pane, as results aren't;
  Show Last Search Results brings them back with the search.
- Keys: Tab reaches the chips from the bar's buttons, ← → go from chip to chip, Space or Return opens one, ⌫ takes it out, Esc closes the editor and keeps what it says.
  VoiceOver reads a chip as its sentence, with Remove as an action.

**Each editor.**

| Condition | Editor | Read from |
|---|---|---|
| Kind | Any of: PDF, Picture, Video, Audio, Document, Spreadsheet, Presentation, Archive, Code, Text, Folder, Application | The name's extension and the folder's type, as today's kinds |
| Extension | Any of, typed as tokens, without the dot | The name |
| Size | is larger than, is smaller than, is between; KB, MB, GB. Leaves out folders | The walk (`ATTR_FILE_DATALENGTH`) |
| Picture Size | the longer side is N px exactly, larger, smaller, at least or at most, with HD, 4K and 8K; `!` for any other. Only pictures meet it | ImageIO, of pictures only (`DatesTaken.longerSide`) |
| Date Modified, Created, Added | is today, yesterday, this week, this month, this year; within the last N days, weeks, months, years; more than N … ago; before, after, between dates | The walk (`ATTR_CMN_MODTIME`, `CRTIME`, `ADDEDTIME`) |
| Date Last Opened | as above; never opened counts as long ago | The system's last-used date of each item, read only when asked |
| Date Taken | as above | The picture's metadata (`DatesTaken.takenDate`), of pictures only |
| Tags | Any of or all of Finder's tags, as Settings → Tags lists them | The item's tags (`FinderTags.read`), read only when asked |
| Attribute | the attribute, Is or Is not. Read-only takes in locked items; Empty is a folder with nothing in it or a file of no bytes; Alias is a Finder alias | The walk (flags, `ATTR_CMN_USERACCESS`, Finder info, a folder's entry count) |
| Skip a Folder | names, as tokens, with names of folders the search has passed suggested | The walk: a folder of that name isn't gone into |

What the walk reads costs nothing more.
Last Opened, Tags, Date Taken and Picture Size are read of each item only for a search that has them, and only of items that met every other condition first;
while they are read the status line says so (built as a count of the items checked: "Searching… 120 results · 3,880 items checked").

**What can be taken from the parked branch.**
`claude/apple-intelligence-parked` (commit `a3e62231`, see [apple-intelligence.md](../plans/apple-intelligence.md)) has a first version of the model and the reads, written before the walk, and to be fitted to it: `SearchFilters`, `SearchDateFilter`, `SearchAttribute` and `SearchKind` in `Sources/FTFoundation/Search/DescribedSearch.swift`;
the per-item reads in `Sources/FTFileSystem/Search/DescribedItemCheck.swift` and `DatesTaken.longerSide`;
the chip and its ✕ in `Sources/FTAppKit/Content/Search/DescribedSearchView.swift`;
the chips' wording in `DescribedSearchText.swift`;
and their tests.
Taken over, they lose what is about descriptions.

## Order of work

1. The conditions' model and how the walk applies them: what a folder's entries hold first (kind, extension, folders left out), then one read of each item kept for size, dates and attributes (`getattrlist` or `fstatat`), then Last Opened, tags, Date Taken and picture size, each only for a search that has them.
   Tests of each.
2. The bar's +, the chips and the editors;
   the commands, Help and `features.md`.
3. Tried in the app by hand: Home, a disk image, a FAT disk, a folder dropped on the app, every editor.

## Done when

- Conditions can be added, changed and taken out as the canvas draws them, from the bar, the Edit menu and the palette, by mouse and by keys, with Help, Settings → Shortcuts and `features.md` updated.
- A search with conditions costs, over the walk alone, what reading the items it kept costs, and no more.
- `scripts/ci.sh --full` passes.
