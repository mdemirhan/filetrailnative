# Plan: every path is a `DiskPath`

**Status:** not started.
Written on 2026-11-21 for whoever carries it out, person or agent.
It builds on the work described under "What is already in place";
read that part against the code before starting, since the code is what is true.

**In one sentence:** make `DiskPath` the type of every path the app stores, passes or compares, so that comparing two paths the forgiving way no longer compiles, and delete the bridges that stand in for that today.

## Why

File Trail's rule is that a path is its exact bytes: the composed and decomposed spellings of an accent (NFC, NFD) are two names, because a disk can keep both (`docs/decisions/must-stay.md`, "Byte-exact path comparison").
Two things work against the rule.

1. **Swift's `String` takes the two spellings as equal.**
   `==`, `hasPrefix`, `Set<String>` and `[String: X]` merge two names a disk keeps apart.
   Faults this caused: the Rename sheet pulled a name's accent twin into a batch;
   selecting one of two such rows could act on the other file;
   one folder was answered with the other's listing, size or icon.
2. **Foundation respells paths.**
   `URL(fileURLWithPath:)`, `URL(filePath:)`, `.standardizedFileURL` and `.resolvingSymlinksInPath()` give an accent decomposed whatever the disk stores, and `FileManager`'s path-taking calls that create things do the same.
   A path read back from such a URL no longer matches a listing's rows byte for byte.
   Faults this caused: New Folder with Selection was unavailable in a folder stored with a composed accent;
   Extract opened a second tab there;
   the tree selected no row;
   Move to Trash failed on FAT32 for composed names.

The first part of the work (in place) removed the second cause and fixed the places where the first one bit.
What it left is that the rule is still a convention wherever a path is a `String`: a new line such as `entry.path == other` compiles and compares the forgiving way.
This plan closes that.

## What is already in place

Check each against the code;
names may have moved.

- **The type.**
  `Sources/FTFoundation/DiskPath.swift`: `DiskPath`, a struct over a `String` held as contiguous UTF-8.
  `==`, `hash(into:)` and `<` are by bytes (`ExactBytes`, in the same file).
  `Codable` as a single-value string, so JSON is the bare string.
  `ExpressibleByStringLiteral` and interpolation (the literal initialiser is `@_disfavoredOverload` so `paths.map(DiskPath.init)` means `init(_:)`).
  `.string`, `.name`, `.parent`, `.appending(_:)`, `.isInside(_:)`, `.isAtOrInside(_:)`, the parts by `NodePath`'s rules.
- **The sibling for text that is not a whole path.**
  `NameKeys.Exact` (`Sources/FTFoundation/Names/NameKeys.swift`): names, and the normalised keys `exactDestinationKey` builds.
  It shares `ExactBytes` with `DiskPath` and converts to neither.
- **The boundary with `URL`.**
  `Sources/FTFoundation/DiskPath+URL.swift`: `url(isDirectory:)` (built from the file-system representation, so the bytes are kept), `init?(urlSpelling:)` (reads the URL's `path`; nil for a URL that isn't a file's; the one place a URL's path is read), `asAURLSpells()` (the spelling an earlier version would have saved).
- **The boundary with the disk.**
  `Sources/FTFileSystem/System/DiskPath+Disk.swift`: `asOnDisk()` (`realpath`; follows a link at the end; for a place to go to), `itemAsOnDisk()` (the folder as on disk, then the item's own name as the folder holds it; a link not followed), `namedAsOnDisk()` (the last step alone), `fileURL()` (`url(isDirectory:)` with the disk asked by `lstat`), `nameOnDisk(_:)`, `DiskPath.home` (the home folder's real path, read once).
- **Paths that enter the app are respelled once, where they enter:** typed in Go To, the path bar, Move To and Extract To;
  picked in a panel;
  dropped from another app;
  given at launch or by another app;
  an unmounted disk's folder;
  where a link or an alias leads.
  Navigation takes a path, and a pane keeps its folder as `BrowserPane.folderPath` with no `URL` of it.
- **Keys and comparisons by bytes** in the listing caches, folder sizes, icons and thumbnails, watches, the tree, the clipboard, drag and drop, the Rename sheet, Undo's "changed since" set, Move To's checks, the file list's rows and selection, and saved state.
- **Saved state from earlier versions is taken over** to the listing's spelling when its folder is listed (`Sources/FTFoundation/Preferences/SavedSpellings.swift`, `Sources/FTAppKit/Windows/BrowserPane+SavedSpellings.swift`): folder views, favorites, workspaces, visits, remembered destinations.
  The disk confirms it is the same folder;
  nothing is matched loosely at lookup.
- **The lint guard.**
  `scripts/lib/path-readbacks.sh`, run by `scripts/ci.sh` as the `url-paths` step, fails on a new path read back from a file URL;
  today's few are in `scripts/lib/url-path-readbacks.txt`, each with its reason.
  Its own tests are `Tests/FTFoundationTests/Release/PathReadbackCheckTests.swift`.
- **Tests that guard all this.**
  `DiskPathTests`, `DiskPathURLTests`, `DiskPathOnDiskTests`;
  `ComposedAccentFolderTests`, `ComposedAccentEnteringTests`, `SavedSpellingsInWindowTests`;
  the `TwoSpellings…` and `…AccentTwins…` suites (two spellings of a name in one folder, through stand-in listings);
  `AccentParityTests` (the same behaviours in folders stored composed, stored decomposed and plain must come out the same).
  Run them first and keep them green throughout.

### The bridges this plan deletes

- **Type aliases for the old wrappers:** `ExactKey` (`FTFoundation/Formatting/JSString.swift`), `PathKey` (`FTFileSystem/FolderSize/FolderSizeTypes.swift`), `PathBox` (`FTAppKit/DragDrop/ListDrops.swift`), `SidebarModel.ExactKeyBox`, `ExactPath` (`FTAppKit/Search/SearchAfterWrite.swift`).
- **Property wrappers on saved fields:** `SavedPath`, `NullEncodedPath`, `SavedPathIfAny` (`FTFoundation/Preferences/SavedPath.swift`), and `PreferenceField.ofPath`.
- **Byte-compare helper functions used on paths:** `samePath` (`FTAppKit/DragDrop/ContentPaneDrops.swift`), `sameText` and `startsWith` (`FTOperations/Identity/CopyPasteFingerprint.swift`), `TreePaths.same`, `FolderSizeAdjust`'s private `same`, `JSString.equals`/`.hasPrefix` where their arguments are paths, raw `.utf8.elementsEqual` / `.utf16.elementsEqual` / `.unicodeScalars.elementsEqual` / `.utf8.starts(with:)` between paths, and `WriteEffects.Bytes` with the raw `Set<[UInt8]>` / `[[UInt8]: X]` keys.
- **`DiskPath(x)` / `NameKeys.Exact(path)` conversions at sets, dictionaries and comparisons**, which exist only because the fields are `String`.
- **`NameKeys.pathsMatchIgnoringEncoding`**, once nothing needs it (see "Deliberately loose comparisons").

## The target

1. **Every stored path is a `DiskPath`** (or `DiskPath?`, `[DiskPath]`): model fields, cached values, parameters, return values, keys.
2. **A name is a `String`.**
   A single name (what `basename` returns, what a person types in a rename) is not a path.
   Where names are keys or are compared exactly, they are `NameKeys.Exact`.
   Do not introduce a type for names in this work ([file-name-type.md](file-name-type.md) asks whether one is worth having);
   note in the report where one would have helped or got in the way, as that plan's investigation will want it.
3. **A relative path is not a `DiskPath`.**
   `relativeParentPath` and their kin stay `String`, with a comment saying so.
4. **A `String` becomes a `DiskPath` only where a path is born:** a listing (the C listing's bytes), `realpath`, `nameOnDisk`, the search walk's paths, the mount table, the decoding of saved state and of the journal, the boundary files, a path built from another `DiskPath` (`appending`, `parent`), a literal for a place the system names (`"/"`, `"/Volumes"`, `"/Applications"`), and tests.
   Everything else that makes one (typed text, a panel's answer, a drop, a launch argument, a URL) goes through the boundary first (`asOnDisk()`, `itemAsOnDisk()`, `init?(urlSpelling:)`).
5. **A `DiskPath` gives up its `String` only at a leaf:** a C or POSIX call, text shown to a person, a log line, the hand-written encoders, and `NodePath`'s own functions.
6. **Path arithmetic is on the type.**
   `NodePath` stays as the `String` implementation behind `DiskPath`'s members and for names and relative paths;
   callers with a `DiskPath` call its members, not `NodePath.x(path.string)`.
7. **File-system protocols take and return `DiskPath`** for paths (`WriteServiceFileSystem`, `ExplorerFileSystem`, `AnalysisFileSystem`, `IdentityFileSystem`, `StateFileSystem`, `BatchRenameFileSystem`, `LocalWriteFileSystem` and the rest: about 46 methods), names staying `String`.
8. **Nothing compares two paths except with `==` on `DiskPath`**, or one of the deliberately loose comparisons listed below, each of which says in a comment why it is loose.

## What remains to convert

Counts were taken at commit cd15ef9f over `Sources/` and have fallen since;
take them again before starting (`grep -rnE '\b[a-zA-Z]*[pP]ath[s]?: \[?String' Sources --include='*.swift' | wc -l` is a fair first measure).

- **About 440 stored fields with path-like names and about 2,000 `String`-typed path declarations including parameters**, in 292 of 536 source files (FTFoundation 74, FTFileSystem 53, FTOperations 52, FTAppKit 113).
- **The models** (each family converts together, with its consumers):

| Family | Types | Where | Mind |
|---|---|---|---|
| Listing | `DirectoryEntry`, `TreeChild`, `DirectorySnapshot`, `EntryMetadata`, `ItemProperties`, `FolderChange`, `ListingKey`, `TreeKey` | `FTFileSystem/Listing/ListingTypes.swift`, `ResponseCache.swift` | synthesized `Equatable`/`Hashable` become byte-exact; `DirectoryListingDiff` compares them |
| Search | `SearchRequest`, `SearchResultItem` | `FTFileSystem/Search/SearchTypes.swift` | `relativeParentPath` stays `String` |
| Engine | `CopyPasteAnalysisRequest`/`Node`/`Report`, `…RuntimeConflict`, `…ItemResult`, `…OperationResult`, `…ProgressEvent`, `WriteOperationItem`/`Result`/`Event` | `FTOperations/WriteService/WriteServiceTypes.swift`, `Coordinator/WriteOperationEvent.swift` | `Codable` pinned by the `exec-*` and `analysis-*` goldens |
| Undo | `UndoStep`, `BatchRenamedItem`, `UndoUnit`, `UndoLog` | `FTOperations/Identity/UndoLog.swift` | hand-written `Codable` stays hand-written |
| Journal | `ReplaceJournalEntry`, `PartialFileJournalEntry`, `BatchRenameJournalEntry` | `FTOperations/Journal/WriteJournal.swift`, `FileWriteJournal.swift` | hand-written text; read with `JSONSerialization` |
| Clipboard | `ClipboardPick`, `CopyPasteClipboard`, `ClipboardSourceEntry` maps | `FTFoundation/Clipboard/` | |
| Selection | `ContentSelection` (`paths`, `anchorPath`, `leadPath`), `InlineRenameState` | `FTFoundation/Selection/` | `content-selection.json` |
| Tree | `TreeItemID` (payloads), `TreeNodeState`, `SidebarLocation`, `SidebarVolume` | `FTFoundation/Sidebar/TreeItems.swift` | the raw text form `fs:<path>` is saved in tabs |
| Saved state | `FavoritePreference`, `OpenTabPreference`, `OpenPanePreference`, `ApplicationSelection`, `OpenWithApplication`, `Workspace`, `VisitedFolder`, `Place`, `FolderView`, `AppPreferences`' three paths | `FTFoundation/Preferences/`, `Workspaces/`, `Ranking/` | JSON byte-identical; key order |
| Navigation | `NavigationHistory`, `TabSnapshot`, `PaneSnapshot`, `BrowserPane.folderPath`, `shownFolderPath` | `FTFoundation/Navigation/`, `FTAppKit/Windows/` | |
| Batch rename | `BatchRenameItem`, `BatchRenameTarget`, `BatchRenameRequest.Item`, `BatchRenameInspection` | `FTFoundation/BatchRename/`, `FTOperations/BatchRename/` | `batch-rename-*.json`, `exec-batch-rename.json` |

- **The helpers** (about 480 qualified call sites): `NodePath` (`basename` 154, `dirname` 109, `join` 54, `resolve` 32, `extname` 6), `Paths` (`isInsideTrash` 30 and four more), `TreePaths` (12 functions), `VolumePaths`, `WriteEffects` (8), `NameKeys`' functions, and three copies of `parentDirectoryPath` (`CommandAvailability.swift`, `InternalDragAndDrop.swift`, `ExplorerTabs.swift`; the last splits by `Character`, unlike its twins: keep one, by bytes).
  `ExplorerTabs.volumeRootPath` repeats `VolumePaths`.
- **The engine's own byte-exact code** (FTOperations: 54 `sameText`, 13 `startsWith`, about 175 `NameKeys.Exact`): correct today, by convention.
  It converts last and mechanically.

## Order of work

The models cross module boundaries, so a module cannot be converted alone and stay green.
Go by family.
Each step ends with the build clean, the scoped suites green and a commit;
the full check runs at the end of each step.
Where a converted family meets one not yet converted, bridge with `.string` / `DiskPath(_:)` at that border only, mark the line with a `// path-border` comment, and remove it in the step that converts the other side.
The last step greps for the marker and finds none.

**Step 0.
Baseline.**
Run `scripts/ci.sh` (everything), the release-only tests (`FILETRAIL_RELEASE_TESTS=1`), the tests that drive real windows (`FILETRAIL_GUI_TESTS=1 swift test --filter GUITests`) and note the frame times `FrameTimeGUITests` prints, for the comparison at the end.
Record the counts above.
Read `docs/decisions/must-stay.md`, `docs/decisions/code.md`, `docs/principles.md`, `CLAUDE.md`.

**Step 1.
The type's own surface.**
Give `DiskPath` what callers will need so they never reach for `NodePath` with `.string`: `ext` (as `NodePath.extname`), `resolving(_:)` if `NodePath.resolve` is used on whole paths, `isRoot`, `isEmpty` only if a real use needs it, `components` only if a real use needs it, and `Paths`/`TreePaths`/`VolumePaths`/`WriteEffects` functions taking and returning `DiskPath` (overloads first; the `String` ones go in the cleanup).
Decide `debugDescription`: two spellings print alike today, which makes a failed test unreadable;
print the string and, when it holds a non-ASCII byte, its scalars.
One commit, tests in `DiskPathTests`.

**Step 2.
Listing and search** (FTFileSystem's models and `ExplorerFileSystem`; FTAppKit's rows, which already key by `DiskPath` and now stop converting).
The largest consumer set: every `entry.path`.
Riskiest: per-row cost and the 60-odd `entry.path ==` sites in FTAppKit.
Tests: the listing, search and content suites;
the `TwoSpellings…` suites;
the listing and search goldens byte for byte.

**Step 3.
The engine** (requests, results, events, the coordinator, the write service's file-system protocols, batch rename's engine).
`sameText`/`startsWith`/`NameKeys.Exact(path)` become `==` and the type.
Riskiest: the hand-written `Codable` of `UndoLog` and the journal's text.
Tests: `FileWriteJournalTests` round trip including a decomposed name;
the eight `exec-*` and three `analysis-*` goldens byte for byte;
the Undo and batch-rename fuzz tests at a fixed seed before and after (`UNDO_FUZZ_SEED`, `BATCH_RENAME_FUZZ_SEED`);
the disk-image suites.

**Step 4.
Foundation's models** (clipboard, selection, tree, navigation history, batch rename's plan types, places and ranking).
`ContentSelection`'s public fields become `[DiskPath]`/`DiskPath?`;
`selectedPaths` follows.
`TreeItemID`'s payloads become `DiskPath` with the raw text form unchanged.

**Step 5.
Saved state.**
The three property wrappers go: fields become `DiskPath` / `@NullEncoded DiskPath?` / `DiskPath?`.
Keep every file byte-identical when nothing is respelled (there is a test: keep it), keep `folder-views.json`'s order rule (text order first, bytes only to break a tie), keep `PreferenceField`'s change detection working (it compares with `==`: that is now by bytes, which is the point).

**Step 6.
FTAppKit's remainder** (panes, windows, dialogs, menus, context menus, toolbar, Info panel, Quick Look, Share, settings pages).
`BrowserPane.folderPath` and `shownFolderPath` become `DiskPath`;
an empty path for "no folder" becomes `nil`, not `DiskPath("")`.

**Step 7.
Cleanup.**
Delete the aliases, the helper functions, the `String` overloads of step 1, two of the three `parentDirectoryPath`, every `// path-border` line, and `pathsMatchIgnoringEncoding` if unused.
`NameKeys.Exact` is left for names only: check each remaining use is a name or a normalised key.

**Step 8.
The conventions, persisted** (see "Conventions to persist").
Last, so the guards describe the finished state.

Steps 2 to 6 may be reordered if a different order needs fewer borders;
say why in the report.
Do not start a step in parallel with another: they meet in the same files.

## Things to be aware of

### The reverse hazard

A comparison that was forgiving becomes strict.
Before, a path spelled otherwise than the disk (from saved state, typed text, a URL) still matched;
now it misses, and what a miss costs varies: a re-read is harmless, a selection not made or a favorite not recognised is a regression.
The rule is: **respell once where the path enters, never match loosely at lookup.**
For every comparison a step makes strict, ask where each side was born.
If one side can be spelled otherwise, fix the entry point, and add a test with a folder stored composed, one stored decomposed, and the other spelling asked for.

Known entry points still to check or fix when their family converts:

- A **write's result** names what it made as it was asked, not as the disk stores it.
  HFS+ stores an accent decomposed whatever was asked, so on such a disk the made item's path differs from its row's.
  The write-end selection respells its misses (`namedAsOnDisk()`);
  when the engine's results become `DiskPath`, decide whether the engine should name what it made as the disk has it (`ExecutionPaths.pathAsOnDisk` does this for Undo records only).
  It costs one `getattrlist` per made item: do not add it to a paste of 150,000 files without measuring.
- **Background tabs not yet shown** keep their saved spelling until their folder is listed;
  `StartupTabs` compares them with the launch folder.
- **A favorite's row** in the sidebar before its folder was ever listed;
  `BrowserPane.openKeepingFavoriteRow`;
  `MainWindowController`'s `selectedTreeItemID == "favorite:…"`;
  Settings' favorites pages (`$0.path == path`).
- **`Place`** (remembered destinations) and its `==`.
- **`ExplorerTabs.followMovedItems`**, `StartupTabs.persistedRoot`.
- **`FolderChangeGate.Pending.changedPaths`** (`Set<String>`) and its `pending.path == path`;
  `ExplorerWindows.folderChanged`.
- **`InfoIconView`** compares `request.cacheKey` as text;
  `IconRequest`'s synthesized `Equatable`.
- **FSEvents** paths against the watched root: on APFS, HFS+, FAT32 and exFAT they come as `realpath` spells them (measured: `AccentSpellingSourcesTests`);
  not tried on network shares.
  A miss there means changes are only seen on window focus.
- **Anything that reads a folder on FAT or exFAT.**
  See "A disk whose listing and lookup disagree" below: a new reader of a folder (a walk, a tool's output) must name what it read as the disk stores it.
- **The mount table and `/Volumes`**: macOS mounts a disk labelled with a composed accent at a decomposed folder name;
  the composed case arises only for a disk mounted at a folder of the user's own.

### Deliberately loose comparisons (keep them; each needs its comment)

- `NameKeys.placeKey`, `looseKey`, `nameKey`, `destinationPathKey`, `namesMatchIgnoringCase`: they model how a disk folds case and accents when it decides whether a name is taken.
  They are not identity.
- The Volumes folder checks in `EjectPlanning`, `EjectOutcome`, `VolumeEjector`: a miss would lose Eject or report "ejected" without ejecting.
- `FolderWatches.noteChange`: a changed name against the watched folder's own name;
  a match only reads again.
- `OpenWithCatalog.appKey` and `OpenWithMenu`: an app's key meets only other keys.
- `makeDiskHasTrash`: lowercased on purpose.
- The sidebar's `replaces` comparison and `SidebarModel.openKeepingRow`: a favorite saved in the old spelling still replaces in place.
  Revisit once favorites are always respelled;
  then make them exact.
- `CopyContentsAction`'s `target != path`.
- `NameKeys.pathsMatchIgnoringEncoding`: used only to confirm the disk's own answer for one folder (the tree's kept root), never to match two nodes.
  If that use can ask the disk directly, delete the function.

When a step meets a loose comparison, it stays loose by an explicit call on `.string`, never by leaving a field `String`.

### Facts about `URL` and Foundation (measured on macOS 27)

- `URL(fileURLWithPath:)`, `URL(filePath:)`, `.standardizedFileURL`, `.resolvingSymlinksInPath()`: decompose.
- A URL made from a file-system representation (`DiskPath.url(isDirectory:)`), a `FileManager` listing URL, a file-reference URL, the Trash's resulting URL: keep the bytes.
- A URL made from text (`URL(string:)`, one read from a pasteboard, a panel's answer): its `path` keeps the text's spelling, its file-system representation is decomposed.
  So `init?(urlSpelling:)` reads `path`.
- `NSWorkspace.didUnmountNotification`'s URL is decomposed in both forms.
- `appendingPathComponent` / `deletingLastPathComponent` on a bytes-kept URL leave `path` as it was but decompose the representation: build the path first, then the URL.
- `resolvingSymlinksInPath()` strips `/private` from `/private/var|tmp|etc`;
  `realpath` does not.
- Swift's `URL(fileURLWithPath:)` does not count a link to a folder as a folder;
  `fileURL()` follows that (`lstat`).
- `FileManager.createDirectory(atPath:)`, `createFile(atPath:)` and `String.write(toFile:)` create a composed name decomposed.
  Today they are used only for the app's own files (`StateIO`, `AppLogger`, `LogRotation`, `IconSamples`, two in `MainWindowController+Writes.swift`): leave those, and never use them for a person's item;
  use the engine or POSIX calls.
- `FileManager.contentsOfDirectory` hides `._name` files on FAT and exFAT: tests there list with `readdir`.
- On FAT32 the Trash refuses a decomposed URL for a name stored composed.
  Other system calls given a decomposed URL worked there (`Data(contentsOf:)`, resource values, tags, `CGImageSource`, thumbnails);
  `NSWorkspace.open` and reveal were not tried.

### A disk whose listing and lookup disagree (FAT32 and exFAT, measured on macOS 27)

"As the disk spells it" assumes the disk has one spelling for an item.
APFS does (the stored bytes, from every call) and so does HFS+ (decomposed, from every call).
FAT32 and exFAT do not:

| Source | Says |
|---|---|
| `readdir`, `getattrlistbulk` (so a raw listing, a walk, a search) | always decomposed |
| `getattrlist` for the one item, `realpath`, FSEvents | the spelling the item was **made or first looked up by since the disk was mounted**, whichever spelling asks later |
| `lstat`, `open` by either spelling | found |
| `rename` on FAT32, `unlink` on exFAT, by the other spelling than the one held | `ENOENT` |
| an item nothing has looked up yet, by either spelling | found, and held by that spelling from then on |

So the disk does not tell what it stores.
It holds each item by one spelling for as long as it knows the item, and that is the only spelling every call accepts.
A name typed on a Mac (New Folder, a rename, a paste) is held composed for the rest of the mount;
a stick written elsewhere and plugged in is held by whatever asks first, which is the app's own reading of the folder, so decomposed.
`AccentSpellingSourcesTests` asserts the table for names made in the mount and `HeldNamesTests` for a disk mounted again, so a change in a later macOS is noticed.

The app's one spelling there is **the one the disk holds**.
So the rule has a second half: **whatever reads a folder on such a disk asks the disk for each name.**
`ft_listing_respells_names(fd)` says whether the disk is one of these (by its `statfs` type: `msdos`, `exfat`), and `ft_held_name(fd, name, …)` asks (one `getattrlistat` per name with a non-ASCII byte; a name without one is never asked).
Four readers do this today:

- `ft_read_directory` (`Sources/CFileTrail/listing.c`): every listing's rows and the tree's children.
- `PosixFileSystem.names(in:)` (`Sources/FTOperations/Identity/WriteServiceStats.swift`): every folder the write engine reads or walks, so what it then renames or unlinks is found.
- `process_dir` (`Sources/CFileTrail/foldersize.c`): a sub-folder's path in the folder-size walk, so its size is kept under the path its row has.
- `search_list` (`Sources/CFileTrail/search.c`): every search result's name and every folder a search walks into (`ft_held_name_on`, as the folder-size walk does).

Not respelled, on purpose: the archive walks (`archive.c`, `fts`; they only open what they read, which either spelling finds, and a member's name inside the archive is then the decomposed one), `TrashState` and `NewFileTemplates` (they compare a name with nothing from elsewhere).

What it costs (disk images, this Mac): nothing on any other disk and nothing for plain names.
On FAT32 the first asking of a folder's names is 100 to 260 µs a name and grows with the folder (10,000 names: about 2 s);
on exFAT 40 to 60 µs (10,000 names: about half a second).
Asked again while the disk still knows the items, 1 to 2 µs a name.
Every name with a non-ASCII byte is asked, also one that has only one spelling (most CJK);
telling those apart needs a table of what can be composed, which was not hand-rolled.

Known limits:

- The disk can forget an item (it lets go of what it has not used for long) and then hold it by the next spelling that asks.
  A path the app kept from before may then differ from a fresh listing's until the folder is read again;
  on FAT32 a rename by the kept path fails only if another app asked by the other spelling in between.
- A search decides by its root whether results are respelled: one started above a FAT or exFAT disk (in `/Volumes`) leaves that disk's results as its folders list them.
- A name longer than 1,023 bytes decomposed is left as listed.
- Unmeasured, and to be measured before anyone relies on them: network shares (SMB, NFS, WebDAV), NTFS, and FAT/exFAT on a macOS older than 27.
  A disk of a kind not in the list is taken at its listing's word, as before.

The disk suites `AccentParityHFSTests`, `AccentParityFAT32Tests` and `AccentParityExFATTests` run the whole parity scenario on images and hold an accented folder against a plain one on the same disk.
Any step that adds a reader of a folder, or a comparison of a listed path with one from elsewhere, must leave them with no difference.

### The boundary's own edges

- `asOnDisk()` follows a link at the end: right for a place, wrong for an item (use `itemAsOnDisk()`).
- Only one missing last part is handled: `/real/new1/new2` comes back unchanged.
- They block on the disk.
  On the main actor, go through `BlockingWork`;
  where a listing is about to be read anyway, let the listing's path do the respelling.
- `nameOnDisk` answers with the disk's name for a mount point: take it only when it is another spelling of the same name (as `namedAsOnDisk()` does).
- `DiskPath.home` is the real path.
  `NSHomeDirectory()` differs when home is reached through a link;
  `TrashFolders` keeps `homeAsSpelled` beside it on purpose.
  Both follow `CFFIXED_USER_HOME`.
- `url(isDirectory:)` of `""` or a relative path resolves against the working directory;
  a trailing slash is dropped on the way back.

### "Is inside" has several rules

`DiskPath.isInside` follows `Tests/Golden/paths-nested.json`: `/a/b` is inside `/a`, every other absolute path is inside `/`, nothing is inside itself or `""`, `/a/b` is not inside `/a/`.
These local rules differ;
check each before replacing it, and keep it (by bytes) where the difference is used:

- `SearchResultsAfterWrite.isAtOrInside`, `FolderSizeAdjust.isInside`, `WriteEffects.isSameOrInside`, `FolderSizeCache`'s `parentOf`/`forEachHolder`: accept a folder spelled with a trailing slash, and `/a//b` as inside `/a`.
- `TreePaths.isWithinRoot` / `isWithinTreeRoot`: include equality, put relative paths inside `/`, and have the other-disk rule.
- `ClipboardRules.deepestHolder` / `parentPrefix`, `DragRules.isInsideAny`: walk up by code units with their own answers for relative and empty paths.
- `WindowFolderSizes.askAgainInside`, `FdSearchRuntime.HiddenFilter`: a byte prefix of folder plus `/`.
- Move To's `insideItself`: the folder starts with `item + "/"`, by bytes.

### Slicing by `Character`

A combining mark right after a slash glues to it as one `Character`, so `hasPrefix`, `dropFirst(n)`, `split(separator: "/")` and `lastIndex(of: "/")` on a `String` path are wrong for a name that starts with a combining mark.
Known sites: `TreePaths.hasHiddenSegment` and `childPath`, `AppWriteOperations`' parsing of `fs:`, `SearchResults.relative`, `ExplorerListing.suggestionQuery`, `ExplorerTabs.parentDirectoryPath`.
Path arithmetic on `DiskPath` must work on bytes or scalars, never `Character`s;
add one test with a name beginning `\u{301}`.

### Encoding and saved formats

- No saved file's format changes and no golden's expected output changes.
  `git diff --stat Tests/Golden` must be empty at every commit. 33 of the 48 goldens hold paths.
- The Undo types and the journal keep their hand-written `Codable` (`docs/decisions/must-stay.md`, "The journal");
  they only swap `String` for `.string` and `DiskPath(_:)`.
- Strings from `JSONSerialization` are bridged;
  `DiskPath.init` makes them contiguous once.
  Do not build a `DiskPath` twice for one lookup on a hot path.
- `TreeItemID`'s raw forms (`fs:<path>`, `favorite:<path>`, `location:<path>`, `favorites-root`, `locations-root`) are saved in tabs: unchanged, read and written by bytes.
- `DiskPath`'s `<` is byte order.
  It is not the order names are shown in (that is the collator's), and it is not `String`'s `<` for non-ASCII text.
  Wherever a `sort` on paths decides a saved file's order or what a person sees, keep what it does today.

### Equality that comes for free, and what it changes

When a model's path field becomes a `DiskPath`, its synthesized `Equatable` and `Hashable` become byte-exact without a line changing.
Find each model's `==` users before converting it: change detection in the preference store (`keys(differingFrom:)`), `DirectoryListingDiff`, diffable updates of the list and grid, `didSet` guards that skip work when a value is "unchanged".
A model that two spellings used to make "equal" will now differ;
that is right, but a `didSet` that then fires for a respelling may do visible work once.

### Performance

- Rows are looked up per cell and the selection per row while scrolling.
  Build a row's `DiskPath` once where the rows are built;
  never in a draw path.
  `==` is a `memcmp` and cheaper than `String`'s;
  making a `DiskPath` from a native Swift string copies nothing, from a bridged one copies once.
- `name` and `parent` go through `NodePath`, which builds scalar arrays.
  If they land in per-row code, measure, and give `DiskPath` a byte-based `name` if needed.
- No benchmarks are added (`CLAUDE.md`, "Benchmarks").
  The gate is the release's frame times: run `FrameTimeGUITests` at the end and compare with step 0.
  Where a speed fix needs a guard, use a CPU-time test (`CPUTime.measureThread`).
- `CommandAvailabilityTests.buildsTheMenuStateForABigFolderWithEverythingSelectedWithoutAFreeze` sits at about two thirds of its one-second bound in a debug build and has crossed it once in a parallel run;
  if it fails, measure it alone before blaming a change.

### Tests and their kits

- Test literals compile unchanged (`ExpressibleByStringLiteral`);
  a test that passes a `String` variable needs `DiskPath(_:)`.
  Change tests mechanically and say how many.
- Five stand-in disks implement the file-system protocols;
  two already key by `NameKeys.Exact`.
  A stand-in that keys by `String` cannot hold two spellings: give it `DiskPath` keys when its protocol converts.
- `TemporaryDirectory.path` (`Tests/FTTestSupport`) is `/var/folders/…`, not the real path, though its comment says otherwise.
  Tests comparing with `asOnDisk()` take `FolderIdentity.realPath` first.
  Fixing the helper is welcome, as its own commit.
- Make accented folders in tests with `mkdir(2)` and `open(2)`, never `FileManager`, which respells.
- A real APFS folder cannot hold both spellings of a name: such tests use a stand-in listing.
  Disk-image tests (`DiskImage` in `Tests/FTTestSupport`) cover HFS+, FAT32, exFAT;
  follow the neighbours on which are release-only.
- Two menu tests fail only when all FTAppKit suites share one process (`docs/state/known-issues.md`): do not run `--scope 'FTAppKitTests'`.
- Out of scope, noted: a name that is not valid UTF-8 is repaired to U+FFFD on listing and cannot be addressed afterwards.
  `DiskPath` cannot hold it either.
  Leave it;
  add a line to `docs/state/known-issues.md` if it is not there.

## Tests to be done

For every step:

1. The step's own new tests fail before the change and pass after (say so in the commit body or the report).
2. `scripts/ci.sh --scope '<the families touched>'` while working;
   `scripts/ci.sh` (everything) at the end of the step: build with zero warnings, all tests, the `url-paths` guard, the format lint.
3. `git diff --stat Tests/Golden` is empty.
4. `AccentParityTests`, the `TwoSpellings…`/`…AccentTwins…` suites, `ComposedAccent…` and `SavedSpellings…` suites green.

At the end, once:

5. `FILETRAIL_RELEASE_TESTS=1 scripts/ci.sh` (the 150,000-file paste, the disk-image suites that are release-only, the guards' own tests) and `FILETRAIL_LARGE_FILE_TESTS=1` for the large-file suites.
6. The fuzz tests at the day's seed and at the seed used in step 0.
7. `FILETRAIL_GUI_TESTS=1 swift test --filter GUITests`, and the frame times against step 0: no clear slowdown of a median or of the share of late frames.
8. `scripts/ci.sh --full`.
9. A hand check in the built app (`tools/capture/README.md`): in a folder stored composed and one stored decomposed, open, rename with an accent, New Folder with Selection, Extract, Move To typed in the other spelling, add and recognise a favorite, quit and reopen.
   Say what `report.json` and the pictures show.
10. A saved-state check: copy a real user-data folder from before this work (or write one as an earlier version would, with `DiskPath.asAURLSpells()`), launch on it, and confirm tabs, favorites, folder views and workspaces come back and each file is rewritten at most once.

New tests this plan adds, beyond each step's own: a stand-in disk holding two spellings run through the whole write path (paste, rename, Trash, Undo) once the engine's protocols take `DiskPath`;
a name beginning with a combining mark through path arithmetic;
the guards' own tests.

## How to work in this repository

- Read `CLAUDE.md` and `docs/principles.md` first.
  Work in a worktree of its own (`.claude/worktrees/<name>`, branch `claude/<name>`), never in the main checkout;
  commit there;
  nothing goes to `main` until the owner says, and nothing is pushed.
- One commit per change that can stand alone, the subject at most about 72 characters saying what is now true, a blank line, then plain sentences.
  No `Co-Authored-By` trailer.
  A step of this plan is several commits;
  a step's bookkeeping in this file goes into the commit that did the work.
- One `scripts/ci.sh` or `swift test` at a time on the Mac;
  `scripts/ci.sh` waits for any other run itself, and a `swift test` of your own goes through `scripts/with-test-lock.sh` (`CLAUDE.md`).
  A run that stalls or fails now and then is looked into (`docs/process/debugging.md`), not run again.
- Goldens are expected results kept by hand;
  none should need a change here.
  If one seems to, stop and ask.
- Comments describe the app on its own terms: no "previously", no step numbers, no record ids.
- Do what the step says.
  What else is found goes into the report, not into the change.
- Where a choice is the owner's (a behaviour that changes for a person, a format, a rule in `docs/decisions`), stop and ask with a recommendation.
- If agents are used for parts of a step, each gets its own worktree, is told the commit to start from (an agent's worktree starts at an older commit), and its commits are cherry-picked and reviewed.

## Conventions to persist

So that a later change cannot quietly undo this.
Step 8 writes them;
nothing here is optional.

1. **`docs/decisions/must-stay.md`**: rewrite "Byte-exact path comparison" as the rule the type now holds: a path is a `DiskPath`;
   a name is a `String` or a `NameKeys.Exact`;
   where a `DiskPath` is born and where it gives up its string;
   the boundary files;
   "respell once where a path enters, never match loosely at lookup";
   the list of deliberately loose comparisons.
   Date it and say what it replaces.
2. **`docs/process/paths.md`** (new, listed in `docs/README.md` and under "Read first" in `CLAUDE.md`): a short how-to for anyone writing code that touches a path.
   What type to use;
   a table "I have X, I need Y" (typed text → `asOnDisk()`; a panel's or a drop's URL → `init?(urlSpelling:)` then `asOnDisk()`/`itemAsOnDisk()`; a `DiskPath` for a system call → `url(isDirectory:)` or `fileURL()`; a name to show → `.name`; a C call → `.string`);
   the don'ts (`URL(fileURLWithPath:)`, `url.path`, `FileManager` path-taking creators for a person's item, `hasPrefix` on a path's string, a `String` field for a path, `Set<String>` of paths, sorting paths with `<` for display);
   how to test (the three folder kinds; `mkdir(2)`; a stand-in listing for twins);
   the facts about `URL` from this plan.
3. **`CLAUDE.md`**: three lines under a "Paths" heading pointing to the two documents above and naming the guards.
4. **Lint guards in `scripts/ci.sh`** (extend `scripts/lib/path-readbacks.sh` or add `scripts/lib/path-conventions.sh` beside it, each check with an allow-list file keyed by file and line text, as the existing one is, and with its own tests in `Tests/FTFoundationTests/Release/`).
   Each fails naming file and line, says the rule in one sentence and points to `docs/process/paths.md`:
   - a path read back from a URL (exists);
   - `URL(fileURLWithPath:` or `URL(filePath:` outside the boundary files;
   - a stored property, parameter or return named `path`, `…Path` or `…Paths` typed `String`, `String?` or `[String]` in `Sources/` (the allow-list holds relative paths and the leaves, each with its reason);
   - `Set<String>` or `[String:` on a line whose declaration is named as paths;
   - `FileManager`'s `createDirectory(atPath:`, `createFile(atPath:`, and `write(toFile:` outside an allow-list of the app's own files;
   - `.string.hasPrefix(`, `.string ==`, `.string !=` between two paths (a loose comparison is written through a named helper that says why).
   These read text, not types: say in each what it cannot see.
   They are a net under the compiler, which is the real guard once the fields are typed.
5. **Tests that stay**: `AccentParityTests` and the twin suites are the behavioural guard;
   a comment at the top of each says what it protects and that a new feature touching paths adds its step there.
6. **`docs/process/reviews.md`**: one line under what a reviewer looks at: a change that touches a path is checked against `docs/process/paths.md`.
7. **This plan** moves to `docs/records/` when done, with its status line saying what was done and what was left.

## When it is complete

All of these hold, and the report says how each was checked:

- No stored property, parameter or return value that holds a whole path is a `String` in `Sources/`, except the allow-listed leaves and relative paths, each with its reason.
- The aliases, the three property wrappers, the helper functions named above and every `// path-border` line are gone;
  `NameKeys.Exact` is used for names and normalised keys only.
- No comparison of two paths other than `==` on `DiskPath` or a listed loose comparison with its comment.
- `scripts/ci.sh --full` passes: zero warnings, every test, every guard, the format lint.
  The release-only, large-file and GUI tests pass.
  Frame times show no clear slowdown against step 0.
- `git diff --stat <start>..HEAD -- Tests/Golden` is empty, and saved files round-trip byte for byte when nothing is respelled.
- `AccentParityTests` covers composed, decomposed and plain folders with no known-issue left open, or each one left is listed with why.
- The conventions above are written, the guards are in `scripts/ci.sh` with their tests, and the guards fail on a scratch line of each kind (shown in the report, then removed).
- The hand check and the saved-state check were done and are described.
- A report in the form of `docs/process/reviews.md`: what was done, what was checked and how, what was not, what was found and left with a recommendation for each.
  The owner decides on landing.

It is not complete if any step was landed with a failing or skipped test, if a golden changed, or if a comparison was loosened to make a test pass.

## Risks, and backing out

- **The size.**
  Most files change.
  Keep steps small enough to read;
  a step whose diff cannot be reviewed is split.
- **A strict comparison that should have been respelled first.**
  The parity suite and the twin suites are the net;
  when one fails, fix the entry point.
- **Speed in the list.**
  Measured at the end;
  if it slows, the fix is in where the keys are built, not in going back to `String`.
- **Each step is its own commits**, so a step can be taken back alone as long as the steps after it have not started.
  After the cleanup step, backing out means reverting from the end.

## Questions for the owner before starting

1. Names stay `String` in this plan.
   Whether they should get a type of their own, with no `==` so each comparison says which question it asks, is a plan of its own that starts with an investigation: [file-name-type.md](file-name-type.md).
   Nothing here depends on its answer.
2. Should the engine name what it made as the disk has it (one disk call per made item), or should callers keep respelling their misses?
3. Is "no folder on screen" better as `DiskPath?` (this plan) or as an empty path, as today?
