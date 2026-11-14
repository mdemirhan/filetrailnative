# Archives

The plan for archives in File Trail. The owner's decisions behind it are in [decisions.md](decisions.md) ("Archives are made and taken apart with the system's libarchive", "Archives will be browsed as read-only folders", and "Search inside archives" under "Left out on purpose").

## Phase 1: Compress and Extract (done)

File ▸ Compress, Extract and Extract To…, also in the right-click menu, run as write operations with the progress card, Stop and Undo. What they do is in decisions.md and in Help (Working with files › Archives).

How Extract writes what it reads (`Sources/CFileTrail/archive.c`):

- libarchive reads the archive; the items are written by File Trail itself, not by libarchive's writer to disk. That writer clears the process's umask around every item, so a file or folder made anywhere else in the app at that moment would be open to everyone. Compress walks the folders itself for the same kind of reason: libarchive's walk makes each folder the process's working directory while it reads it.
- Each item is reached from the hidden folder one part of its path at a time, no part followed when it is a link, and made with a call that fails when the name is taken. So nothing is written through a link an earlier item of the archive made, nothing is replaced, and of two items of one name (or of two names a disk that ignores case takes for one) the first stays as it was.
- Left out, and counted in the note the result shows ("2 items were left out…"): a name from the root or with `..`, an item whose path runs through a link or a file, a second item of a name, a hard link to anything but a file already extracted, a name the disk won't take, and pipes, sockets and devices (a Linux root file system comes out without its `/dev`). A `./` item, the folder a tar was made in, is nothing and isn't counted.
- A name whose bytes aren't UTF-8 (a zip made on Windows in Japanese or Russian, which doesn't say which encoding it used) is kept with each such byte written as `%XX`; names that are UTF-8 stay as they are.
- A file is its owner's alone while it is written. Its extended attributes, its resource fork and the rest of what `__MACOSX` or a tar's `._` file keeps for it, then the archive's quarantine, then its permissions (without setuid, setgid and sticky) and dates are put on it in that order, so a read-only item is quarantined too. Folders get their permissions and dates once the whole archive is out. The folder the items are handed over in is quarantined as well.
- The quarantine is read back from each item once it is on. When the archive is quarantined and its quarantine can't be read, or a file or folder that came out (or the folder they are handed over in) doesn't keep it, the archive fails, says so ("…couldn't be marked as downloaded…"), and nothing of it is left: what came out would run without macOS checking it. A link that won't keep it goes without, as it runs nothing itself. On a disk that keeps no extended attributes at all (some network servers), the items come out without it, as Finder copies onto such a disk and as nothing on it can be quarantined; that is decided once, by the folder the items are handed over in refusing it as something the disk doesn't do (ENOTSUP), before anything is read, so no item of the archive can claim it for itself.
- Access rules (ACLs) an archive keeps, in a zip's `__MACOSX`, a tar's `._` files or the tar's own headers, are not put on what comes out; the item gets the rules any new item in its folder gets. A rule that denies writing attributes, inherited by everything in a folder, would keep the quarantine off (an app in a downloaded zip would then open unchecked), and one that denies deleting would keep a stopped extraction, or Undo, from clearing the items away. copyfile puts the rules it finds in Mac metadata on whatever it unpacks it onto, asked to or not, so each item's metadata is unpacked onto a file of its own with no name, and only its extended attributes are copied from there.
- Stop is seen at the next block of data: of an item being written, of one left out whose data has to be read through to get past it (in a `.tar.gz`, a 7z or a RAR), and, compressing, of the count of the items' bytes made before the zip is begun. That count walks what the zip will hold and no more: links aren't followed, and a disk mounted inside isn't gone into.
- After a failure or a Stop the hidden folder is removed with everything in it; folders are given back to their owner on the way down, so an archive's read-only folders don't keep it there.

## Phase 2: Browsing an archive as a read-only folder

### Opening

- Opening an archive (double-click, ⌘↓, Return when it opens, File ▸ Open, the context menu's Open) browses it. Today it extracts it; whether a setting in Settings › Files › Opening Files keeps Extracting as a choice is decided when this is built. Opening it in Archive Utility or another app is Open With, not a setting.
- One archive opens in place, as a folder does, and Back leaves it.
- Several archives each open in a new tab, in list order, the current tab left as it is. The open-item limit applies, with its notice. The room for their tabs is checked once, before any opens: when the window hasn't room for all of them, none opens and one notice says so ("The 3 archives would each open in a new tab, and this window has room for 1.").
- Extracting, several archives are extracted in one run, as today.
- In a selection of files, folders and archives, files open in their apps, archives in tabs, and folders as they do today.
- The right-click menu always offers Browse Contents, Extract, Extract To… and Open With, whatever the setting.
- Documents that are zips inside (docx, epub, jar, ipa) open in their apps whatever the setting; Browse Contents is in their right-click menu.
- Disk images (dmg, iso) stay disk images, mounted as today.

### Where you are

- A place inside an archive is a path through it: `~/Downloads/x.zip/src/a.txt`. Nothing on a disk can have a path under a regular file, so the archive in a path is always plain: the first part that is an archive file. History, tabs, panes, sessions, workspaces and the path bar keep working with plain paths.
- ⌘↑ from the top of an archive goes to its folder with the archive selected.
- A tab saved inside an archive opens there again; when the archive is gone, it goes where a tab on a missing folder goes.

### How it is read

- The listing reads the disk through `ExplorerFileSystem`. A file system in front of the real one sends paths inside an archive to an index of the archive's contents, kept in memory, and the rest to the disk. Sorting, the filter, every view and folder sizes then work unchanged; Calculate Size is instant.
- The index is read once per archive, kept by its path, size and modified time, and let go when no tab shows the archive.
- A zip or 7z lists its contents in one place and opens at once. A `.tar.gz` and its kind have to be read through to be listed; a large one shows the loading state meanwhile.
- The archive file itself is watched. Changed, it is read again; gone, the tab goes to its folder, as for a folder deleted.
- Names that would reach outside the archive (`/…`, `..`) and `__MACOSX` are left out, parent folders the archive doesn't list are made up, and of two items of one name the first is kept. A link inside is shown as a link and never followed out of the archive.

### What needs a real file

- Quick Look, Open and Open With take the item out first, into a cache folder (`~/Library/Caches/<bundle id>/Archives/<id>/`) emptied at quit and at launch. A file opened from there is read-only, so changes made to it aren't lost silently.
- Copy and Paste out of an archive, and Copy to Other Pane (F5), take the items out into hidden staging on the destination's disk and hand them to the paste as a move there, so the paste review, its conflict answers, the journal and Undo are the paste's own.
- A drag out gives file promises: Finder, another app or the other pane takes the items out only when they are dropped. A drop into an archive is refused.

### What changes inside an archive

- A header like the Trash's: "Inside x.zip · read-only", with Extract All.
- The path bar shows the archive's part with the archive's icon: Downloads › x.zip › src.
- Size is the size taken out, Modified the archive's date for the item. The status bar adds the compressed size: "12 items, 3.4 MB (1.1 MB compressed)".
- The Info panel adds the compressed size, the ratio and whether an item is encrypted; tags, permissions and the default app are left out.
- No tag dots and no custom folder icons.
- The folder tree gives an archive a disclosure triangle only while a pane shows a place inside it.
- The search field is dimmed.
- Left out of right-click menus and dimmed in the menu bar: Paste, Cut, Move to…, Move to Other Pane (F6), Rename, Batch Rename, Duplicate, New Folder, Compress, Move to Trash, Delete Immediately, Add to Favorites, Open in Terminal, Paste as File.
- Kept: Open, Open With, Quick Look, Copy, Copy Path, Copy Contents, Copy to Other Pane (F5), Open in New Tab, New Window and Other Pane, Calculate Size, Extract and Extract To… (of the archive, or of the items selected in it). Show in Finder shows the archive file.
- Nothing inside an archive is changed: adding, renaming or deleting in it would mean writing the whole archive again, without the journal, Undo or `renamex_np` behind it.

## Phase 3: Later

- Protected archives: the password asked in an opaque sheet with a secure field, kept for the session only, for Extract and for browsing. Today they are refused, with Archive Utility named.
- Archives inside archives (a zip in a zip), taken out to the cache and browsed from there.
- Compress… with a sheet: zip, 7z, tar.gz or tar.xz, the level, and a password.
- The formats Archive Utility opens and Extract doesn't yet (see "Next to Finder" below), each where libarchive or Apple Archive reads it without another program.

## Next to Finder

What Phase 1 does as Finder and Archive Utility do, and where it differs. Archive Utility's formats are the document types in its `Info.plist`.

- Same: Compress's names (`Photos.zip`, `Archive.zip`, `Archive 2.zip`); Finder's `__MACOSX` for extended attributes and resource forks; one item out as itself, several in a folder named after the archive, the next number when taken; the archive's quarantine on everything that comes out, read-only items included; the archive left where it is.
- Opening an archive (double-click and the rest) extracts it in File Trail; what it gives is selected where it went, or opens in a new window or tab when that folder isn't on screen, where Archive Utility shows it in Finder.
- More than Finder: RAR and xar; Extract To…; Stop part way with nothing half made left; Undo of Compress and Extract; names in zips marked UTF-8, which Windows reads right.
- Less than Finder:
  - Protected zips: Archive Utility asks for the password; Extract refuses them (Phase 3). An archive with one protected item among plain ones is refused whole, and nothing of it is left.
  - Names that aren't UTF-8: Archive Utility guesses their encoding; Extract writes the bytes it can't read as `%XX`.
  - Formats only Archive Utility opens: cpio and cpgz, `.Z`, Apple Archive (`.aar`) and its encrypted kind, XIP, MacBinary, BinHex, AppleSingle and uuencoded files.
