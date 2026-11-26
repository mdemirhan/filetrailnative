# Decisions: Archives

Compress, Extract and Extract To, and the plan to browse archives.
Part of the owner's decisions: [the index](../decisions.md) lists the other parts, and [principles.md](../principles.md) says how a decision is weighed and when to ask about one.

- **Archives are made and taken apart with the system's libarchive.** macOS ships it without its headers, so its two headers are kept in `Sources/CFileTrail/libarchive` and nothing is added to the app;
  only the formats it reads by itself are turned on, so no other program is run.
  That is why `.tar.zst` and `.tar.lz4` are not offered: the system's libarchive reads them only with a `zstd` or `lz4` tool installed.
  - **libarchive only reads an archive and writes a zip.**
    The app itself puts what comes out on the disk and walks the folders it compresses, as libarchive's own way of doing either changes the whole app's umask or working folder for a moment, under every other thread.
  - **Compress makes a zip as Finder's does**, each item's extended attributes and resource fork kept in `__MACOSX` for `ditto` and Archive Utility to put back.
    On a disk without attributes it leaves out the `._` files that hold them, as they are the attributes of items already in the zip;
    elsewhere a `._name` file is someone's own and goes in (2026-11-20).
  - **Extract reads** zip, tar (plain or with gzip, bzip2 or xz), 7z, RAR and xar, and a single file compressed with gzip, bzip2 or xz.
    An archive holding one item gives it, one holding several a folder named after the archive.
    A name taken gets the next number, counting on from one the name ends in ("Scan 3.zip" beside a "Scan 3" gives "Scan 4"), as Archive Utility does, for what comes out and for a zip's own name.
    Kept on 2026-11-20;
    dropped: numbering the name whole ("Scan 3 2"), as Convert Images names its copies.
    It is made out of sight and put in place whole.
  - **What comes out can't do more than the archive's own file could.**
    It gets the archive's quarantine and loses setuid bits;
    nothing is writable by anyone but its owner (a zip made on Windows gives 644, not 664);
    names reaching outside the folder are left out;
    a link that came out is a file, and what it points to isn't looked at.
    Access rules (ACLs) in an archive are not applied, as one could keep the quarantine off or the items from being deleted.
    An archive whose items can't be given its quarantine fails and leaves nothing, except on a disk that keeps no extended attributes at all (they come out without it, as Finder copies them there) and, on exFAT and FAT, for a `._name` file of the archive's own, which is left out and counted (2026-11-20).
  - **A bad item is left out and counted, not a reason to stop**: one that is no file, folder or link (a device, a pipe), a second item of a name already written, and one whose path runs through a link.
    A hard link is a second file on a disk that keeps none (exFAT, FAT), where the archive would otherwise fail whole.
  - **Names come out composed** ("é" as one character), as Archive Utility gives them and other systems read them.
    A zip's names that aren't UTF-8 are read in the one encoding the zip fits (Shift JIS, GB18030, Big5, CP949 or Windows-1252, the user's languages first, else CP437, the format's own), as zips from Japanese, Chinese and Korean Windows are common and Archive Utility guesses too (2026-11-20).
    Every name the zip doesn't mark as UTF-8 is read in it, also one whose bytes happen to be UTF-8, so a zip's folders don't split in two;
    a name it can't read is left out and counted.
    In other archives, or where no encoding fits, such bytes stay `%XX`.
  - **Data that isn't what the archive says it holds (a checksum that doesn't match) fails and leaves nothing**, but for gzip, whose checksum libarchive doesn't look at.
    A folder that takes nothing new refuses before anything is extracted or compressed.
  - **A hole an archive names (a sparse file: a disk image) costs nothing** on a disk that keeps holes.
    On one that doesn't, it is refused when the disk hasn't room for it, and otherwise written a piece at a time, so Stop ends it.
  - **Protected archives are refused for now**, with Archive Utility named.
  - **Opening an archive extracts it here**, several in one run, rather than handing it to Archive Utility;
    only Open With hands it to an app, and File Trail doesn't list itself in Finder's Open With for archives.
    A folder or a package named as an archive is, opened with other items, is handed to the system like them.
    A link to an archive gives its items beside the link.
  - **A key held down extracts once**, as it mounts a disk image once.
    After that its repeats open nothing until the key is let go, as what came out is selected by then and would be opened.
  - **What came out is selected and scrolled to** when it went into a folder a pane of the tab shows, and otherwise opens in a new window or tab, as "Open disk images and archives in" says: one for each folder something went into, and a folder that came out alone opens on itself.
- **Archives will be browsed as read-only folders** (not built yet).
  The plan, and what it decides, is [plans/archives.md](../plans/archives.md): opening an archive will browse it, Open With still hands it to an app, documents that are zips (docx, epub, jar) open in their apps with Browse Contents in their context menu, and nothing inside an archive is changed.
