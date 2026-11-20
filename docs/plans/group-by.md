# Group By

The plan for grouping a folder's items, in every view and in search results. Designed and agreed with the owner on 2026-11-20, every open question settled as recommended; nothing of it is built yet. Once it is, what it does moves into [decisions/views.md](../decisions/views.md) as decisions, each with its reason, and this file moves to `records/`.

## What it is

- **Every view groups, and search results too.** View ▸ Group By chooses a field; the items are shown under a header for each group, and Sort By orders them inside each group.
- **The fields** are None, Name, Date Modified, Date Created, Date Last Opened, Date Added, Size, Kind and Tags, in the one order of fields and columns ("Fields and columns are listed in one order"), Tags after Kind. Search results add Folder after Name. They are all fields the app already reads: grouping adds no new kind of read from the disk.
- **A pane carries its grouping from folder to folder**, as it carries its order. A pane opened from another takes it; it is saved with the pane (a tab brought back at launch, a workspace); a pane with none of its own starts at None. Search results have their own, as they have their own view and order.
- **A folder's view can keep it**: a sixth setting beside view, order, Folders First, columns and size.

## The groups

Groups with nothing in them are not shown.

| Group By | Groups | Their own order |
|---|---|---|
| Name | The first letter, without case or accents in the user's language (É under E); `0–9` for digits, `#` for anything else | A to Z, as names sort |
| Date Modified, Date Created | The date groups below | Newest first |
| Date Last Opened | The date groups, then Never Opened | Newest first, Never Opened last |
| Date Added | The date groups, then No Date Added (FAT, exFAT, most shares) | Newest first, No Date Added last |
| Size | Zero bytes, Under 100 KB, 100 KB to 1 MB, 1 to 10 MB, 10 to 100 MB, 100 MB to 1 GB, 1 to 10 GB, Over 10 GB; Not Measured for folders not measured yet | Largest first, Not Measured last |
| Kind | Applications, Archives, Disk Images, Documents, Folders, Images, Movies, Music, PDFs, Presentations, Source Code, Spreadsheets, Other: the item's type, looked up once for each extension | A to Z |
| Tags | The item's first tag, then No Tags. An item is never shown twice, so the counts and Select All stay true | A to Z, No Tags last |
| Folder (search results) | The folder each result is in, as its path from where the search started (`Taxes/2025`) | By path |

### Date groups

The boundaries are midnights in the Mac's time zone and calendar, worked out once each time the groups are made, so placing an item is a comparison of two numbers. On Friday 20 November 2026:

- **Future**: after the end of today (a camera's clock, an archive's dates); 21 November and later.
- **Today**: from this morning's midnight; 20 November.
- **Yesterday**: 19 November.
- **Previous 7 Days**: from midnight seven days ago up to yesterday; 13–18 November.
- **Previous 30 Days**: from midnight thirty days ago up to those seven; 21 October – 12 November.
- **Each earlier month of this year, by name**, less what the thirty days took: October is 1–20 October, then September back to January.
- **Each earlier year**: 2025, 2024 and so on.
- **No date** (Never Opened, No Date Added): last, whatever the direction.

On 5 January there are no month groups: the thirty days reach into December, and the rest of December is under the year before, as in Finder. Previous 7 Days and Previous 30 Days show their dates faintly in their header ("Previous 7 Days  13–18 Nov"), as their names alone don't say whether yesterday is in them. A row keeps its date as it is shown today ("Today, 9:12 AM"): the group says which part of the calendar, the row when exactly.

At midnight the groups change: a folder on screen grouped by a date is grouped again on the system's `NSCalendarDayChanged`, which also comes after a wake, a clock change or a time zone change. No timer of the app's own, and nothing at all while no pane groups by a date (a line in [state/battery.md](../state/battery.md)).

### What reading it costs

- Name, Kind, Date Modified, Date Created, Date Added and Folder: nothing the folder read doesn't give. Name uses the sort's own name keys; Kind's types are kept by extension.
- Date Last Opened: read for every item while grouped by it, as while sorted by it.
- Size: folders are measured as when sorted by Size, and each goes into its group once measured, as a row moves when sorted by Size.
- Tags: read for every item while grouped by them. A listing reads at most 500 items' tags today (`ExplorerListing.listedTagLimit`), the others once on screen.

## The order

- **Group By puts the items in groups; Sort By orders the items inside each group.** Grouped by Date Modified and sorted by Name, Today lists its items A to Z.
- **When both use the same field, the sort's direction orders the groups too** (decided 2026-11-20): Date Modified ascending puts the oldest year first and Today last. Otherwise the groups keep their own order, from the table. The groups without a value (No Date Added, Not Measured, No Tags) stay last either way.
- **Folders First puts the folders first inside each group**; grouped by Kind, that is the Folders group first.
- The status bar's count doesn't change. The Sort button's tooltip says both: "Grouped by Date Modified, sorted by Name".

## How each view shows it

- **List**: a group row before each group's rows, floating under the column header while its group scrolls (`NSTableView`'s group rows): a chevron, the group's name in semibold, the dates of a relative date group faintly, and its count ("· 4"). Size bars, sorted by Size, are still measured against the folder's largest item, not the group's.
- **Icons**: a header across the pane before each group, the same as the List's, which stays at the top while its group scrolls; each group starts a new row.
- **Compact List**: the groups side by side, each starting a new column, its header over its columns; the header's name stays at the left edge while the list scrolls sideways. A column holds a header's height fewer rows.
- **Previews**: no header rows (decided 2026-11-20). Each group starts a new row, so a row still fills the pane exactly and every rule about the file on screen at 1 at a time holds as it is; at 2, 4 and 9 a group's last row can have empty places. A Liquid Glass label at the pane's top left names the group of the row on screen and its count ("Yesterday · 3"; at 1 at a time "Yesterday · 2 of 3"). Header rows were considered and dropped: they would make a row other than the pane's height.
- Finder's Icons groups, a row each that scrolls sideways with Show All, were considered and dropped: each group becomes a carousel, and ↓ has no clear meaning in it.

## Collapsing a group

Decided 2026-11-20: groups collapse, and that is not saved in a folder's view.

- A click on the chevron collapses or expands the group; ⌥-click does it to every group, as in an outline. A click elsewhere on a header does nothing, so a stray click never readies a Move to Trash.
- **Collapsing a group deselects what is in it**, and Select All selects what is shown, so Move to Trash never acts on a file not on screen.
- Collapsed groups are part of where the pane is, as its scroll is: Back, Forward and Reopen Closed Tab put them back, and a folder opened afresh shows every group open.
- A header's right-click menu: Select 4 Items in “Today”, Collapse “Today”, Collapse All Others, Expand All Groups, then the Group By submenu.

## Keys, selection and changes on screen

- The arrows move in the order on screen, from one group into the next. In Icons, ↓ from a group's last row goes to the item in the same column of the next group's first row, or to that row's last item.
- Shift-click and ⇧ with an arrow select a range in the order on screen, across groups.
- The filter narrows each group; a group with no match goes, and the counts are of the matches.
- An item saved or renamed moves to its new group, as it would move under a sort; one being renamed stays until Return. New Folder puts the folder in its group (Today, or "U" by name) and scrolls to it for naming.
- A drop lands in the folder as now: a group is not a place.
- A header is an accessibility group; VoiceOver reads "Yesterday, 3 items, expanded".

## Commands

Each as [process/commands.md](../process/commands.md) lays out, so it is in the menus, the command palette, Help and Settings → Shortcuts. None has a key until one is chosen in Settings, as Sort By's items: Finder's ⌃⌘1 to ⌃⌘7 are the workspaces' here.

- **View ▸ Group By**, just above Sort By, as in Finder's View Options: None, then the fields, then Collapse All Groups and Expand All Groups. In search results, Folder after Name, and the fields as there.
- The same submenu in the list background's right-click menu and the toolbar's View Options menu, beside their Sort By.
- **The toolbar's Sort menu** ends with one item, a submenu named for the grouping in use ("Group By: Date Modified"), so the menu stays short (decided 2026-11-20). A section with a heading inside the menu was considered: about 20 items.
- **A Group toolbar button** in Customize Toolbar, on no toolbar until added, as Duplicate Pane's is.
- **The List's column header menu** gets Group by “Date Modified” for the column clicked, checked while grouped by it, so that choosing it again groups by None. It runs the menu's command, not one of its own.
- Finder's Use Groups (⌃⌘0, free today) is left out: None turns grouping off, and a toggle would have to remember a field to turn back on.

## Folder Customization

- `FolderViewSetting.groupBy`, a `groupBy` key in a view's `keeps` in `folder-views.json`. A file written before has none, and loads as a view that doesn't keep it, as the settings are read one by one.
- A Group By row between View and Sort By, in Finder's order: a checkbox titled Group By and a pop-up of the fields. The popover goes from four setting rows to five, the same five in every view, so it still keeps its height as the view changes. A changed row has the orange dot, its tooltip saying what is saved ("Saved: None").
- Everything else is as for the other settings: a change shows at once, Save keeps it, Revert and leaving the folder drop it; the setting is given back to the pane once the folder keeps it; Apply to Subfolders and the nearest view winning whole apply to it.
- Folder Customizations shows a Group tag on a folder that keeps it.
- Search results are not a folder and have no customization, as now.

## Tags (in this round)

Decided 2026-11-20. Grouped by Tags, the tags of every item are read, not only the listing's first 500, as Date Last Opened is read for every item while sorted by it. The home folder's Desktop, Documents and Downloads show no tags of their own, as now (reading them asks for permission).

## Considered and left out

- Group by Application (the app that opens each file): a Launch Services lookup for every item, slow in a large folder.
- Group by Date Taken: it would suit Previews, but reads every photo's metadata, a new kind of read. Possible later, with what Batch Rename already reads.
- Each kind as its own group ("JPEG image", "HEIF image"): too many small groups.
- An item under each of its tags: the counts, Select All and drags would count it twice.
- A choice of date steps (by day, month or year): the relative groups answer what is recent, as in Downloads; by month for a photo folder could come later as other items of the menu.

## Building it

1. **The groups** (FTFoundation, no AppKit): a `GroupByPreference` beside `SortByPreference` (`Preferences/PreferenceTypes.swift`), and one function from the sorted items, the field, the order and Folders First to the groups, with the date boundaries made once from a clock and a calendar given to it (`AppClock`), the size bands, the kinds and the name initials. Tested on its own, the boundaries at the year's start, a time zone change and items without the date included; a `CPUTime.measureThread` test guards making the groups of 150,000 items.
2. **The pane's setting**: carried, saved with the pane and in workspaces, taken by panes opened from another, the app's for a pane with none; search results' own.
3. **The commands**: the table's rows, the menus, the right-click menus, the toolbar's Sort menu and the Group button, the column header's item, the header's right-click menu, Help's lines, the palette.
4. **The views**: List, Icons, Compact List, Previews, each with its keys, selection, collapsing and the place put back by Back and Forward.
5. **The folder's view**: the setting, the row in Folder Customization, the tag in Folder Customizations.
6. **The day changing** and the reads for Date Last Opened, Size and Tags while grouped by them.
7. **The docs**: decisions/views.md, features.md, Help, state/battery.md; this file to `records/`.

The goldens that change are named here so the owner's approval covers them, each edited by hand ([decisions/code.md](../decisions/code.md)): the shortcuts, command availability, preferences, the toolbar, the right-click menus and Help. No new benchmark: the frame times of scrolling stay the release's only one.
