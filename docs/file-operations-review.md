# File operations review: findings

**Status:** both high findings and all nine medium ones are fixed, each with tests (H1, H2, M1 to M9; the commits
after `4c048a4`). The eighteen low findings in the table further down are open. What follows is the review as it was
written, before the fixes.

Reviewed at commit `4c048a4`: copy, cut and paste (move), duplicate, Replace, rename, batch rename, New Folder, Move to
Trash, Delete Immediately, Empty Trash, the write journal and crash recovery. Undo and Redo were left out.

**How it was done.** Four independent reviews, each in its own worktree, driving the real engine with temporary probe
tests on real disk images: APFS, case-sensitive APFS, HFS+, exFAT, FAT32 and a read-only HFS+ (macOS 27, where exFAT
and FAT32 are FSKit volumes). "Reproduced" below means a probe showed it; the probes and images are removed. I then
checked the main claims against the code. Nothing was changed.

**Not covered by anyone:** a real SMB or NFS share (no-Trash was simulated), iCloud placeholders, a volume ejected in
the middle of a copy, and running Empty Trash for real.

Paths are under `Sources/FTOperations/` unless they start with `Sources/`.

## High

### H1. Delete Immediately walks into a disk mounted inside the folder and empties it
- **Status:** reproduced for the delete itself (`rm(recursive:)` on a folder holding a mounted APFS image deleted
  everything on the image, then failed with EBUSY on the mount point). Not run end to end through the Trash.
- **Where:** `WriteService/WriteServiceFileSystem.swift:171-186` (`removeTree` never compares `st_dev`), called from
  `LocalOperations/DeleteImmediatelyOperation.swift:193`. `Coordinator/WriteGuards.swift` looks only at the top paths.
- **Scenario:** a folder with something mounted inside it (a disk image at a custom mount point, a share under
  `~/mnt/…`) is moved to the Trash and then deleted immediately, or deleted for good on a disk without a Trash.
  Everything on the mounted volume is deleted, then the operation reports "The item is in use."
- **Fix:** refuse to descend into a folder whose device differs from the top item's; better, scan for one before
  deleting anything. Consider refusing to trash a folder that holds a mount point.

### H2. Moving `._` companions picked alongside their items strips the items' attributes and resource forks
- **Status:** reproduced, exFAT to APFS, cut: `foo.txt` had `com.apple.ResourceFork` and a tag at the source and
  none at the destination; status "completed"; source emptied.
- **Where:** `Analysis/CopyPasteAnalysis.swift:5-14` and the top-level loop. `withoutAppleDoubleFiles` (`:403`) is
  applied only to a folder's children (`:337`), never to the picked items.
- **Scenario:** on exFAT, FAT32 or a share that uses `._` files, with hidden files shown, select all and move to
  another disk. `._foo.txt` goes first as an ordinary file and its original is deleted; `foo.txt` then arrives bare.
  In the other order nothing is lost but each companion raises a "source deleted" question. `docs/known-issues.md`
  says these are treated as part of their item; that holds only inside a pasted folder.
- **Fix:** in the review, drop a picked `._x` when `x` exists beside it and `isAppleDouble(._x)` is true.

## Medium

### M1. A move that replaces an item in a folder allowing adds but not removals strands the moved item under its hidden name for good
- **Status:** reproduced on APFS with `chmod +a "everyone deny delete_child"` on the destination folder.
- **Where:** `Replace/CopyPasteReplace.swift:57-68` (the source is renamed to the hidden name before anything shows
  the old item can leave), `:252-264`; `WriteServiceFileSystem.swift:135` (`canModifyFolder` is only `access(W_OK)`).
- **What happens:** the source is gone, the item sits as `.note.txt.filetrail-xxxxxxxx`, and the message promises a
  fix at the next start, which fails the same way at every start. Likely also on NAS shares that grant create
  without delete (not tested on one).
- **Fix:** before moving the source aside, prove the folder lets an item leave (make, rename and remove an empty
  probe file once per destination folder), and refuse the Replace otherwise. This also covers M5.

### M2. On FAT32, Move to Trash fails with "doesn't exist" for names stored precomposed
- **Status:** reproduced through `TrashItem.live()` and a Replace for "café", Korean, Vietnamese and kana names
  created under their NFC spelling; `lstat` finds the file. Fine on exFAT, HFS+ and APFS. The Move to Trash command
  uses the same call but was not run.
- **Where:** `Native/NativeTrash.swift:11` (`URL(fileURLWithPath:)` re-spells the path).
- **Fix:** build the URL from the name as the disk spells it (`fileURLWithFileSystemRepresentation`), or retry with
  the other spelling on ENOENT while `lstat` succeeds.

### M3. "The name is too long" is judged in UTF-8 bytes; every disk tested limits UTF-16 units
- **Status:** reproduced on all five volume types: 255 CJK characters (765 bytes) can be created, 256 can't.
- **Where:** `Sources/FTFoundation/Contracts/ItemNames.swift:6,24`; `Sources/FTFoundation/Names/NumberedNames.swift:38-52`.
- **What happens:** a name over 85 CJK characters, 63 emoji or 127 Cyrillic letters can't be renamed (even by one
  character) or made as a folder. In a batch rename one such item blocks the whole batch. Numbered names are cut
  earlier than needed. Names listed decomposed (HFS+, exFAT, FAT) reach the limit sooner.
- **Fix:** count `utf16.count` against 255 and leave the rest to the disk's own ENAMETOOLONG, which is already worded.

### M4. The hidden temporary name loses attributes on `._`-file disks for names starting with `_` or near the length limit
- **Status:** reproduced on exFAT and FAT32: `_config.yml` copied, moved or duplicated arrives without its tag
  ("completed"); with a resource fork the move fails with "A disk error occurred." A 244-byte name loses its tag too.
- **Where:** `Execution/ExecutionFiles.swift:144-156` (`"." + name + ".filetrail-xxxxxxxx"`, so `_x` becomes `._x…`,
  a name those disks refuse attributes on; and the padded name leaves no room for its own `._` companion).
- **Fix:** a temporary name that never begins with `._` and leaves 2 bytes spare. Recovery's `isStagingName` must
  know the new form.

### M5. A copy into a folder that refuses removals leaves whole hidden copies with no record and no word
- **Status:** reproduced in the setup of M1, copy mode: a full-size `..note.txt.filetrail-….filetrail-…` not in the
  journal, and an empty hidden folder named again at every start.
- **Where:** `Execution/ExecutionFiles.swift:54-66` (the cleanup's failure is swallowed; files under 32 MB have no
  journal entry).
- **Fix:** M1's check, or name the leftover in the item's error and journal it whatever its size.

### M6. A catastrophic regular expression freezes the Rename sheet
- **Status:** reproduced: `(a+)+$` on one name of 20 a's takes 8 s, 22 take 55 s, 28 didn't finish in 3 minutes.
- **Where:** `Sources/FTFoundation/BatchRename/JSRegExp.swift:71` (no limit); the plan is computed on the main actor
  at every settings change (`Sources/FTAppKit/BatchRename/BatchRenameSheetModel.swift:178`).
- **Fix:** a time budget per name, as the search highlight has, shown as a settings error; or plan off the main
  thread and cancel on the next keystroke.

### M7. Trash on a read-only disk is taken for "no Trash", and deleting for good is offered
- **Status:** reproduced on a read-only HFS+ image: "…because its disk has no Trash", with a Delete button that then
  fails with "The destination is read-only." Nothing is lost.
- **Where:** `Native/NativeTrash.swift:57`, `Native/TrashItem.swift:57-66`.
- **Fix:** check `MNT_RDONLY` before marking `.noTrash`; say the disk is read-only and offer nothing.

### M8. A disk that goes away while "delete for good?" is open leaves the moved item hidden, and nobody is told
- **Status:** reproduced on an HFS+ image forced off while the question was open: the error names no hidden item, and
  only the next launch's recovery restores it.
- **Where:** `Replace/CopyPasteReplace.swift:252-267` (the hidden-name message is gated on `isPathTaken`, false when
  the disk can't be read); `Sources/FTAppKit/WriteOperations/AppWriteOperations.swift:93-94` (the retry covers only
  entries left at launch).
- **Fix:** name the hidden path unless the item is known gone; add entries a running operation leaves to the retry;
  better, ask the no-Trash question before moving the source.

### M9. A journal entry whose folder no longer exists is kept and retried forever
- **Status:** reproduced: three recovery runs each kept all four entries and gave the notice "…which isn't
  connected. Connect it…".
- **Where:** `Recovery/CopyPasteRecovery.swift:147-150,223-254`; `BatchRename/BatchRenameExecution.swift:555-559`.
- **Fix:** tell a missing folder on a mounted volume from a missing volume; drop the entry with one truthful notice.

## Low

| # | Issue | Status | Where |
| --- | --- | --- | --- |
| L1 | Case-only renames the disk takes for the same name are refused as "already exists" (Greek `ΦΩΣ`→`φως`, `straße`→`STRASSE`): the app's fold is narrower than APFS's and exFAT's | reproduced | `LocalOperations/RenameOperation.swift:68-75` |
| L2 | exFAT: a case-only batch rename of a name containing Σ is reported "no longer exists" though it happened, and Undo records nothing (a macOS 27 exFAT driver bug; `mv` shows it too) | reproduced | `BatchRename/BatchRenameExecution.swift:343-350,479` |
| L3 | Batch rename: one item that can't move aside late in a chain leaves another as "b 2", even with Skip or Block; with the stuck item earlier everything is put back | reproduced (locked item; ENOSPC on FAT32) | `BatchRename/BatchRenameExecution.swift:238-289,387-427` |
| L4 | Delete Immediately fails on a tree whose paths pass 1024 bytes, after deleting what it could reach | reproduced | `WriteServiceFileSystem.swift:171-186` |
| L5 | Stop has no effect inside one folder being deleted for good | from reading | `DeleteImmediatelyOperation.swift:136-141,193` |
| L6 | A delete that fails part way reports only the blocking item, not that part of the folder is gone | reproduced | `DeleteImmediatelyOperation.swift:186-210` |
| L7 | Empty Trash holds the write slot for as long as Finder takes (up to a day), with no way out | from reading | `Sources/FTFileSystem/System/TrashState.swift:52-56` |
| L8 | A rename or New Folder whose pre-check hangs keeps the slot reserved with nothing to stop | from reading | `Coordinator/WriteCoordinator.swift:214-222` |
| L9 | Hidden staging names can pass HFS+'s limit (it counts decomposed UTF-16 units), so some valid names can't be replaced there | reproduced | `Sources/FTFoundation/Names/CopyPasteNames.swift:182-205` |
| L10 | An unreadable journal is set aside silently; a single entry this build can't parse is erased at the next write | reproduced | `Journal/FileWriteJournal.swift:106-117` |
| L11 | A person's own `._x` file copied beside `x` to a `._`-file disk is overwritten by the disk's attribute file (a move detects it; a copy would report success) | reproduced for a move | `Execution/ExecutionNodes.swift:285-309` |
| L12 | A folder whose ACL denies its own deletion is emptied by a move to another disk, then left behind | reproduced | `Execution/ExecutionNodes.swift:206-243` |
| L13 | The preview's clash check lowercases where APFS folds fully (ß = ss), so preview and run can disagree; handled safely at run time | reproduced | `Sources/FTFoundation/Names/NameKeys.swift:29-42` |
| L14 | Replace Text recomposes the untouched part of a name (visible to byte-comparing tools) | reproduced on FAT32 | `Sources/FTFoundation/BatchRename/BatchRename.swift:134` |
| L15 | Inline rename drops a change of accent encoding alone (Swift `==`) | reproduced | `Sources/FTFoundation/Selection/RenameRules.swift:19` |
| L16 | `prepareBatchRename` doesn't validate `destinationName` (not reachable from the sheet) | from reading | `BatchRename/BatchRenameOperation.swift:38-60` |
| L17 | The staging folder is made before its journal entry; a crash between leaves an empty hidden folder | from reading | `Replace/CopyPasteReplace.swift:81-89` |
| L18 | "The old … was moved to the Trash" is said even when it was deleted for good | from reading | `Replace/CopyPasteReplace.swift:237,249,261` |

L1, L2 and L13 share a cause (the app's case fold against the disk's). For L1 the fix is to take a destination that
resolves to the source's own id, and isn't listed as a second entry, for the item itself.

## Checked and found right

- **Never replaces by accident:** `renameExclusive` gives EEXIST on all five volume types. exFAT answers ENOTSUP to
  `RENAME_EXCL` and takes the lstat-then-rename fallback recorded in `docs/decisions.md`.
- **Replace:** no path ends with neither item in place or the old one deleted unasked. Copy and cut, file and folder,
  same disk and across disks, file over folder and the reverse, `X.TXT` over `x.txt`, NFC over NFD: all complete on
  all five volume types with the per-volume Trash, and leave no hidden names.
- **Full disk** (FAT32, exFAT, HFS+): nothing partial left, originals kept, the rest marked not started.
- **FAT32's 4 GB limit:** fails at once with "The file is too large for this volume."; original kept.
- **Read-only volume:** copy into, move within and out of, rename, New Folder and batch rename are all refused
  cleanly, and the write slot is free afterwards.
- **Two names differing only in case going to a disk that ignores case:** refused at review, nothing written.
- **Symbolic links:** copied, renamed and trashed as links; Delete Immediately never descends through one.
- **Folder into itself:** refused through a link, another case spelling, and a relative link.
- **Attributes on exFAT and FAT32 for ordinary names:** tags and resource forks arrive, and companions travel.
- **Batch rename:** swaps, chains, cycles, case swaps, and a folder with its items in one batch are right on all five
  volume types; regular-expression replacement tokens match JavaScript; counters don't overflow.
- **Trash:** a locked item fails and the others go on; a folder and its child count once; an open file is trashed;
  a volume root is refused.
