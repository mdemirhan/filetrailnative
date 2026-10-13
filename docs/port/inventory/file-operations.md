# File Trail file operations engine: inventory for the Swift/AppKit port

Repo root: `/Users/tcmudemirhan/src/tsproj/filetrail`. Read-only analysis; no files were modified. Paths below are relative to the repo root, cited as `file:line`.

Short names used throughout:
- **Core**: `packages/core/src/fs/`
- **Boot**: `apps/desktop/src/main/bootstrap/`
- **Contracts**: `packages/contracts/src/`
- **Native**: `packages/native-fs/src/`

The policy docs `docs/UNDO_PLAN.md` and `docs/FILE_OPERATION_RISKS.md` were read in full. The second one lists 27 accepted risks; port those as "won't fix", not as bugs.

---

## 0. Architecture in one page

**Copy engine (Core).** A paste runs in five stages:
1. `WriteService` (`writeService.ts`) holds the copy engine's own one-at-a-time slot and runs analysis jobs.
2. `buildCopyPasteAnalysisReport` (`copyPasteAnalysis.ts`) builds a review tree.
3. `resolveAnalysisWithPolicy` (`copyPastePolicy.ts`) turns the tree plus the policy and per-item overrides into resolved nodes with actions.
4. `executeCopyPasteFromAnalysis` (`copyPasteExecution.ts`) runs them.
5. Progress, runtime questions and the final result (with an `undoLog`) go out as `CopyPasteProgressEvent`s.

**Coordinator (Boot `writeOperations.ts`).** This is the global single **write slot** (`activeWriteOperationId`, around :266). It covers:
- paste, copy_to, move_to, duplicate (all delegated to `WriteService`);
- rename, batch rename, new folder, trash, delete immediately, undo/redo (all "local" operations);
- Empty Trash;
- crash-recovery retries, through `runWriteAlone`.

It also throttles progress, records finished operations into the Undo history, and enforces the Trash and system-folder protections.

**Crash journal (Boot `writeJournal.ts`).**
- File: `userData/replace-journal.json`, a JSON array.
- Entry kinds: `replace`, `partial_file`, `batch_rename`.
- Recovery runs at startup before any write service exists, then retries every 60 s while the slot is free.

**Undo** (`undoLog.ts` in Core; `undoHistory.ts`, `undoPlan.ts`, `undoExecution.ts` in Boot):
- The history is in memory only and capped at 1,000,000 item steps.
- Every step is re-checked on disk just before it runs.
- Undo only renames exclusively or moves to the Trash. It never overwrites or deletes.

**Native addon (Native).** `copyfile(3)`, `renamex_np(RENAME_EXCL)`, `lchflags`, ACL get/set, `NSFileManager trashItemAtURL:resultingItemURL:`, `NSURLIsPackageKey`, `pathconf(_PC_CASE_SENSITIVE)`, `getattrlist VOL_CAP_INT_EXTENDED_ATTR`, `getmntinfo`. Each runs on the libuv threadpool. Node's `original-fs` supplies the rest: lstat, stat, realpath, readdir, readlink, mkdir, rm, rmdir, chmod, utimes, access(W_OK).

**Action enum** (`Contracts/ipc.ts:286`): `paste | copy_to | move_to | duplicate | trash | delete_immediately | rename | new_folder | batch_rename | undo | redo`. Empty Trash is the internal action `"empty_trash"`.

**Shared limits:**
- `MAX_PATHS_PER_REQUEST = 100_000` (`limits.ts:6`).
- `MAX_ITEM_NAME_BYTES = 255` UTF-8 bytes (`itemName.ts:5`).

---

## 1. Operations and their algorithms

### 1.1 Common preprocessing (every copy-like operation)

**Normalize the request** (`copyPasteAnalysis.ts:39`):
- `resolve()` every path, then dedupe.
- `withoutNestedPaths` (`Contracts/paths.ts:4`) drops any path that has a picked ancestor. If "/" is picked, everything under it is dropped.

**Coordinator guards** (`writeOperations.ts:1912` `copyPaste:analyzeStart`):
- `assertNotIntoTrash(dest)`: refuses with "Nothing can be pasted into the Trash." The check is `isInsideTrash` (`Contracts/trash.ts:5`): `~/.Trash[/…]` or `/Volumes/X/.Trashes[/…]`, compared after NFD + lowercase.
- For cut mode only:
  - `assertNotProtectedPath`: refuses `isTrashFolder`, i.e. `~/.Trash`, `/Volumes/X/.Trashes`, or `/Volumes/X/.Trashes/<uid>`.
  - `assertNotSystemLocation(..., "moved")` (`writeOperations.ts:2334`).
- `ensureNoWriteOperationInFlight` (`writeOperations.ts:648`).
- One analysis per window; the window's older analyses are forgotten.
- An analysis is cancelled if its window crashes, closes or navigates (`watchAnalysisOwner`, `writeOperations.ts:1763`).

**System locations refused** for trash, delete, move and rename (`writeOperations.ts:2294-2374`):
- Fixed paths: `/`, `/Users`, `/Volumes`, `/System`, `/System/Volumes/Data`, `/Applications`, `/Library`, `/private`, `/usr`, `/bin`, `/sbin`, `/etc`, `/var`, `/opt`.
- Any `/Volumes/<name>` (a whole disk).
- `~` and `~/{Desktop,Documents,Downloads,Library,Movies,Music,Pictures,Public,.Trash}`.
- Paths are compared lowercased. Each protected path's dev:ino is also compared, using `stat`.
- Any folder whose dev differs from its parent's (a mount point) is refused: "“X” is a disk, so it can't be …".
- Only folders are protected; files and symlinks pass.
- Copying a system folder is allowed; moving one is not.

**Renderer analysis loop** (`renderer/hooks/useExplorerActions.ts:2100-2260`):
- Polls `copyPaste:analyzeGetUpdate` every 120 ms.
- If `report.issues` is non-empty:
  - `same_path` items in cut mode started from the clipboard, a drag or Move To are dropped silently (moving into the folder they are already in).
  - `source_missing` items in a clipboard paste are dropped and reported.
  - The request is then re-analyzed with the remaining paths.
  - Any other issue blocks the whole paste with a message.
- The review sheet appears when the report has conflicts, or for drag / Move To when there is a `large_batch` warning.
- Otherwise the paste starts with `DEFAULT_COPY_PASTE_POLICY = {file:"skip", directory:"skip", mismatch:"skip"}` (`writeServiceTypes.ts:354`).

### 1.2 Copy / Paste (`paste`, `copy_to`) and Duplicate (`duplicate`)

- **Duplicate** is a copy into the items' own folder. Analysis sees `pastingIntoSourceFolder` (decided by identity: `captureFolderFingerprint` follows a symlinked destination) and gives each item a `resolveDuplicateName` " copy" name. That is a "new" item, not a conflict (`copyPasteAnalysis.ts:157-172`).
- Copy mode reserves first the names of items that keep their own name (`:141-149`), so a " copy" name never takes one of those.
- In search results, Duplicate works only when every item is in one folder (renderer `startDuplicateOfSelection`).

**Execution, per top-level resolved node** (`copyPasteExecution.ts:283-313`):
1. If the signal is aborted: the rest are recorded as `cancelled` ("Not started because the operation was stopped."), or `skipped` if their action was skip.
2. `executeResolvedNode` (`:575`):
   1. `skip`: done.
   2. `detectRuntimeConflict` (`:2466`), then a question loop (section 2.5).
   3. `performNode` (`:869`).
   4. On `DestinationTakenError` (an EEXIST found while writing), re-detect and loop, up to `MAX_RUNTIME_ATTEMPTS = 5` (`:76`).
   5. On other errors, `findLockedRefusal` maps EPERM/EACCES to "“X” is locked. Unlock it in Finder's Get Info and try again." when the source, the destination, or either parent has lock flags.
3. `closeUndoUnit` (`:360`) stamps the created items.

**`performNode` (`:869`):**
- `renameOnly` folders: section 1.3.
- `overwrite`: if the destination still exists, `executeReplace` (section 3.1). If it is gone, the action becomes `create`.
- Cut on the same dev and not a merge: `tryRenameForCut` (section 1.3).
- Directory:
  - If `issueCode === "source_unreadable"`, fail with "This folder couldn't be read, so it wasn't copied/moved. <reason>".
  - If `create` or `keep_both` at the top level (not already staging): `executeStagedDirectory` (`:941`).
  - Otherwise `executeDirectoryNode` (`:1255`).
- File or symlink: `executeLeafNode` (`:1166`).

**`executeStagedDirectory` (`:941`).** A whole new folder is built hidden, then renamed into place:
1. In cut mode, `assertRemovableAfterCopy(deep)` (`:1094`) checks the whole tree first. For the source and its parent:
   - locked (lock flags) → "“X” is locked…";
   - `canModifyFolder` (access W_OK) on the parent, and on the folder itself for a directory → EROFS: "wasn't moved, because its disk is read-only"; EACCES/EPERM: "…you don't have permission to remove …";
   - recurses into non-skipped children.
2. `reserveStagingFolder` (`:2303`): mkdir of a `temporarySiblingPath` (section 3.2). Up to 10 attempts; EEXIST means try another name.
3. Journal `{kind:"replace", stagingPath, finalPath, sourcePath, moved:false, staged:false, movingCopy?: true for cut}`. If the journal write fails, remove the staging folder and fail.
4. Run `executeDirectoryNode` on the node rebased to the temporary path, in a context with:
   - `mode:"copy"`, `recordsUndo:false`;
   - `stagingFor: <real mode>`;
   - `metadataLaterFor: temp` and `folderMadeAt: temp` (the folder is not made again, and its metadata waits);
   - `displayPath` maps temp paths back to final paths, so progress and questions never show hidden names.
5. On error or abort: `discard()` sets the journal to `staged:false`, removes the staging tree, and removes the entry. Abort throws `CancelledWithItemsError([])`: nothing is left in either place.
6. Aborted after the build: discard as well.
7. If (cut and any child failed) or (any child incomplete and the source is a package): discard. The item fails with:
   - "“X” wasn't moved because some items in it couldn't be copied. Nothing in it was moved.", or
   - the incomplete-package message (`:2291`).
   Only the not-completed child items are reported.
8. Otherwise:
   1. `recordedComplete = true`, journal `staged:true`;
   2. `unlockForMove(temp)` and `openForMove(temp)` (chmod u+w if a read-only folder);
   3. `moveExclusive(temp → final)`;
   4. `restoreAfterMove` (mode first, then flags).
   On EEXIST: `DestinationTakenError`, so the item is asked about again.
9. `applyDirectoryMetadata` on the final folder, errors ignored. Remove the journal entry, `noteChanged`, `recordCreated` (copy mode).
10. In cut mode, `removeMovedSources` (section 1.3).
11. An ordinary (non-package) folder copy with failed children is still put in place, with the failures listed. The status is `failed` with a null error and `childFailureCount` set.

**`executeDirectoryNode` (`:1255`):**
1. For `create`, `keep_both` and `overwrite`: plain `mkdir` (never recursive, so a deleted parent is not recreated). Skipped when `destinationPath === folderMadeAt`. EEXIST → `DestinationTakenError`. ENOENT → `explainMissingFolder` (`:2432`): "The folder “P” no longer exists."
2. Count progress +1 and emit.
3. `merge`: `expectCantUndo("merge")`.
4. Children run sequentially:
   - check abort between them, throwing `CancelledWithItemsError(done so far)`;
   - a failing child is recorded and the loop continues;
   - a `StagingCleanupError` propagates (it aborts the whole hidden copy);
   - children that are not completed are tracked as `keptNames`.
5. If any child is incomplete while staging, and this folder is a package that was created here: remove it, failing with `StagingCleanupError` if it cannot be removed, and fail the package ("incomplete package").
6. Metadata goes on last: `applyDirectoryMetadata` (`:1404`):
   - `copyMetadata`, i.e. native `copyfile(COPYFILE_METADATA|NOFOLLOW_SRC)`;
   - when moving, `utimes` the source mtime back;
   - fallback: `chmod(mode)` plus `utimes(mtime)`, with ENOTSUP/EOPNOTSUPP ignored;
   - for a move whose metadata copy failed, the source is added to `metadataNotCopied`, so the original folder is kept.
   - Metadata failures never fail the folder.
7. Cut: `tryRemoveEmptySourceDirectory`. Copy (not staging for cut): `describeAddedDuringCopy` (`:2799`), which names items added to the source folder after the review, ignoring `.DS_Store` and AppleDouble companions.

**`executeLeafNode` (`:1166`), via `writeLeaf` (`:1211`):**
- **Symlink:** `copyFile(src, dst)`. Native copyfile with NOFOLLOW_SRC makes the link itself, with its xattrs, flags and dates. EEXIST → `DestinationTakenError`.
- **File:** `copyFileContents` (`:2182`):
  - Inside a hidden folder (`folderMadeAt != null`): `writeIntoHiddenFolder` writes straight to the final name. On failure, remove the partial file; if it cannot be removed, throw `StagingCleanupError`.
  - Otherwise:
    1. if the target exists → `DestinationTakenError`;
    2. `partialPath = temporarySiblingPath(target)`;
    3. if the file is ≥ `JOURNALED_FILE_BYTES` = 32 MiB (`:2353`), add journal `{kind:"partial_file", partialPath, finalPath}`;
    4. `writeFileContents(src, partial)`;
    5. `unlockForMove(partial)`, `moveExclusive(partial → target)`, `setFlags(target, flags)`;
    6. on failure, `removeStagedItem(partial)`;
    7. finally, remove the journal entry only once the partial is certainly gone (`isGone`, `:2265`: ENOENT and the parent is still a directory).
- **`writeFileContents` (`:2355`):** `fs.copyFile(src, dst, signal, onProgress)`.
  - EEXIST → taken; ENOENT → `explainMissingFolder`.
  - ENOTSUP/EOPNOTSUPP on a FIFO or socket → "“X” is a special file (such as a pipe or a socket), which can't be copied."
  - On failure, delete the destination only if this copy created it and it is a file.
- **`restoreDroppedFileMetadata` (`:1239`):** chmod or utimes only if the copy's mode or mtime differs from the source's. Never fails the item, and never touches a locked copy whose metadata arrived intact.
- **Cut:** `copyStillWhole` (`:2665`: the same kind, the same size when known, the same link target), then `tryDeleteMovedSource` (`:2675`):
  - source gone → OK;
  - fingerprint changed → "It changed while it was being moved, so the original was kept.";
  - else `rm(src, {recursive:false})`; on error, "It was copied, but the original couldn't be removed. …".
  - If the copy is not whole: `COPY_NOT_WHOLE_MESSAGE` (`:2650`).

**Terminal status** (`resolveTerminalStatus`, `:2954`):

| Situation | Status |
|---|---|
| Cancelled | `partial` if anything completed, else `cancelled` |
| Any item failed | `partial` if anything completed, else `failed` |
| Any item skipped | `partial` |
| Otherwise | `completed` |

`summary.topLevelItemCount` counts only result items whose source was picked (`:2928`).

### 1.3 Move (Cut + Paste, Move To, drag-move) — `mode: "cut"`, action `move_to`

**Analysis (folders on the same disk).** If the source dev equals the destination dev, a cut folder gets `renameIfFree`. When there is no conflict it is marked `renameOnly`: its children are **not read**, and `totalBytes` becomes null (`copyPasteAnalysis.ts:252-259, 401, 882-908`).

**Execution:**
- **`renameOnly`:** only `tryRenameForCut` is allowed (and not when the action is overwrite). Anything else (EXDEV, or a destination conflict at runtime that is not about the source) fails with "“X” wasn't moved because its destination changed after the move began. Try moving it again." (`:876-885, :1147`).
- **`canRenameForCut`** (`:1156`): cut mode, the destination dev is known, the node's source dev equals it, and the action is not `merge`. Then `tryRenameForCut` (`:2393`):
  - `renameExclusive(src → dst)` (native `renamex_np RENAME_EXCL`);
  - EXDEV → fall through to copy + delete;
  - EEXIST → `DestinationTakenError`;
  - on success: record a `moved` undo step, count the whole subtree as done, emit.
- **Copy + delete (other disk):**
  - `assertRemovableAfterCopy(shallow)` first.
  - `expectCantUndo("other_disk_move")` unless merging.
  - Folders are staged hidden (`executeStagedDirectory`) and placed whole, then `removeMovedSources` (`:1756`) walks the reviewed tree. A file original is removed only if its copy (rebased from the temp path to the final path) still matches the fingerprint recorded in `copiedForMove`, then via `tryDeleteMovedSource`. Skipped or cancelled subfolders are kept. Each folder gets `metadataKeptMessage ?? tryRemoveEmptySourceDirectory`.
  - Files: copy, verify, delete inline.
- **`tryRemoveEmptySourceDirectory`** (`:2713`):
  - gone → OK;
  - the folder changed (`canRemoveMovedSourceDirectory`, `:2851`: same kind, mode, ino and dev) → "Its items were moved, but the original “X” changed during the move, so it was kept.";
  - `rmdir`. The app's rmdir is `removeEmptyFolder` (`writeServiceTypes.ts:365`): it readdirs first and throws ENOTEMPTY if the folder lists anything. This exists because macOS rmdir silently deletes "._" files.
  - On ENOTEMPTY/EEXIST, `describeLeftInMovedFolder` (`:2750`):
    - if everything left is `.DS_Store` or an AppleDouble companion of a planned item, remove those and rmdir;
    - otherwise name the new items: "“x” was added to “F” while it was being moved, so it was left in the original “F”."
- **Mount points:** a cut folder that contains a mounted disk is refused at analysis as `source_unreadable` ("can't be moved because a disk is mounted inside it") when going to another disk, or when merging on the same disk (`copyPasteAnalysis.ts:262-274, 726`).
- **Move into the same folder:** a `same_path` issue (`:184-196`).
- **Add Missing** is not offered for moves in the review sheet (it would split a folder): `allConflictsChoicesFor` in `renderer/lib/copyPasteReview.ts:118`.
- **Clipboard:** cut-paste sends `clearsCutClipboard: <capturedAt>`, so whichever window owns the paste clears the cut clipboard when it ends.

### 1.4 Drag-and-drop (renderer `lib/internalDragAndDrop.ts:85-110`)

**Copy or move** (`resolveInternalDropOperation`):
- Option → copy.
- Command → move. Option+Command → copy (there are no aliases).
- Otherwise: same disk → move, different disk → copy.
- "Same disk" means the dev ids from `system:getDiskIds` (Boot `diskIds.ts`, `stat().dev`) for every source **parent folder**, and for every dragged directory itself, compared with the target. The fallback is the volume-root path prefix.
- A drag from another app that does not allow move (`effectAllowed` not in `move|copyMove|linkMove|all|uninitialized`) becomes a copy (`allowedBySource`).

**Drop validation** (`validateInternalDrop`):
- the target is one of the dragged items → `same_path`;
- a move into the folder the items are already in → `already_in_target`;
- the target is inside a dragged folder or package → `parent_into_child`;
- a search-results drag onto the content area → unsupported.

A copy drop runs `startCopyToDestination` (action `copy_to`; into the items' own folder it makes " copy" duplicates). A move drop runs `startMoveToDestination` (action `move_to`). Both use the default skip policy, and the review appears when there are conflicts or a large batch.

### 1.5 Move to Trash (`writeOperations.ts:1352`, handler `:2081`)

**Before queuing:**
- `assertNotProtectedPath`;
- `assertNotAlreadyInTrash`: "“x” is already in the Trash.";
- `assertNotSystemLocation(..., "moved to the Trash")`, run inside `prepareWithReservedSlot`.

**Execution:**
1. `paths = withoutNestedPaths`.
2. Read the home folder's dev via `nativeItemSize(home)`.
3. For each item, sequentially (abort leaves the rest as cancelled):
   1. Emit progress (current path).
   2. `before = itemSize(path)` for the folder-size cache.
   3. `lstatUnlessMissing`: if missing, it counts as **completed** (no failure).
   4. Read the id, the parent id (`stat`, cached per folder) and `stampWithoutId` (only when there is no usable id).
   5. `trashPath = fs.trash(path)`, which is `createTrashItem` (`trashItem.ts:21`) wrapping native `nativeTrashItem`.
   6. A null `trashPath` means the location is unknown, so the operation becomes `{undoable:false, reason:"trash_location_unknown"}`.
   7. Otherwise one undo unit `{trashed, from, trashPath, id, parentId, stamp?}` per item.
4. On failure:
   - if the error code is `ENOTRASH` and the item can be told apart (it has an id, or a stamp where `looksTheSame` is meaningful), remember `withoutTrash[path] = {id, stamp}` for the sender window;
   - the item result gets `noTrash: true` and "“x” couldn’t be moved to the Trash because its disk has no Trash." (`:2567`).
5. Final status as in `resolveLocalTerminalStatus`. A stop reads "Stopped after N items were moved to the Trash."

**`createTrashItem` error classification** (`trashItem.ts`):
- locked → `lockedMessage`;
- on the startup disk (item dev equals home dev), or the item is unreadable, or no-Trash can't be inferred → the Trash's own message;
- no-Trash is inferred when the code is `ENOTSUP`/`EOPNOTSUPP`, or there is no code and `diskHasTrash(path) === false`. It then throws `{code:"ENOTRASH", cause}` with "…This disk may not have a Trash."

**No-Trash flow (renderer `useExplorerActions.ts:196`).** If **all** failures are `noTrash`, the window asks "Delete immediately?" (dialog `confirmDeleteWithoutTrash`). Delete Immediately on those paths is then allowed by `itemsWithoutTrash` even though they are not in a Trash. The record is per window, and is cleared when the window's page reloads (`did-navigate`).

### 1.6 Delete Immediately (`writeOperations.ts:1504`, handler `:2097`)

**Guards:**
- `assertNotProtectedPath`;
- `assertNotSystemLocation(..., "deleted")`;
- `assertDeletableImmediately` (`:409`):
  - each path must either be in this window's `itemsWithoutTrash` and still the same item (`assertStillAskedItem`, `:459`: the same id, or for id-less items `looksTheSame`, `:189`: kind + mtime + (size, or entryCount for a folder)), or
  - be really inside a Trash. `placeInTrash` uses the realpath of the parent: `isInsideTrash` must hold for both the given path and the real path. A Trash folder itself is refused, and a path outside gives "“x” isn't in the Trash, so it can't be deleted immediately."

**Execution, per item:**
1. Re-check `assertStillAskedItem` or missing. Gone counts as completed.
2. `rm(path, {recursive:true, force:true})`.
3. `deletingBegan` becomes true after a success, or after a failure that left the item missing, unreadable or a directory (so it may be partly deleted).
4. Lock detection uses `error.path` (the inner failed item) and the top-level path.

Undo: `{undoable:false, reason:"deleted_for_good"}` if `deletingBegan`. Otherwise the history is unchanged.

### 1.7 New Folder (`writeOperations.ts:1249/1312`)

- **Prepare:**
  - `assertNotIntoTrash`;
  - the name is `folderName.trim()` (validated by `itemNameSchema`, i.e. `getItemNameError`);
  - the parent must `stat` as a directory.
  - If the name is taken and `nextFreeName` is set: `nextFreeFolderPath` (`:1339`): "name 2", "name 3", …; if the name already ends in " N", continue from N+1; up to 10,000 tries. Otherwise "An item named “x” already exists."
- **Execute:** plain `mkdir` (non-recursive). The undo step is `{created, path, id, stamp}`. If `diskHasTrash(parent)` is false (or cannot be told), the result is `{undoable:false, reason:"no_trash"}`.

### 1.8 Rename (`writeOperations.ts:1013/1087`)

**Prepare (inside the reserved slot):**
- `assertNotProtectedPath`, `assertNotSystemLocation(..., "renamed")`.
- Name trimmed; same path → "Choose a different name."; the source must lstat, else "“x” no longer exists."
- **`renamesItself`** (a case-only or normalization-only change) holds when all of these are true:
  - the destination lstat succeeds;
  - `namesMatchIgnoringCase` (NFC + lowercase);
  - the same dev:ino, **or** either side has no usable id (FAT/exFAT empty files);
  - the parent's `readdir` does **not** contain the exact new spelling (`listsSeparateEntry`). This tells two hard links, or two items on a case-sensitive disk, apart.
- Destination exists and not `renamesItself` → "An item named “x” already exists."

**Execute:** `renamesItself ? rename() : renameExclusive()`. Errors are mapped by `findLockedRefusal` or `describeWriteError` (ENOENT → "no longer exists", EEXIST → "already exists").

**Undo:** `{moved, from, to, id, itemKind, parentId}`, read *after* the rename. Reading it never turns a finished rename into a failure.

The renderer asks before a name starting with "." (dialog `confirmDotName`).

### 1.9 Batch Rename

See section 5.

### 1.10 Empty Trash (`writeOperations.ts:1817`, `systemHandlers.ts:368`)

- Refused if the slot is busy: "The Trash can't be emptied while another operation is running…".
- It takes the slot as its own operation (`emptyTrashOperationId`) and runs `osascript -e 'with timeout of 86400 seconds' -e 'tell application "Finder" to empty trash' -e 'end timeout'`.
- History: records `deleted_for_good` unless the failure is one of AppleScript errors -1743, -1744 or -600 (`trashLeftAsItWas`, `:2578`), which mean nothing was emptied.
- Always invalidates `~/.Trash` caches and notifies windows (`filetrail:trashEmptied`).
- Quitting does not wait for it.
- Trash state (`getTrashState`, `systemHandlers.ts:333`) checks `~/.Trash` and `/Volumes/*/.Trashes/<uid>`; a Trash holding only `.DS_Store` counts as empty.

### 1.11 Undo / Redo

See section 4.

### 1.12 Quit / shutdown (`writeOperations.ts:1862`)

- `closing = true` (new operations get "File Trail is quitting."), detach window listeners, cancel the active operation (unless it is Empty Trash), then wait for idle up to `SHUTDOWN_WAIT_LIMIT_MS = 15_000`.
- Unanswered questions resolve to null when cancelled, so they fail with "Runtime conflict was not resolved".

### 1.13 Multi-window hand-off

- An operation whose window crashes, closes or navigates is handed to `successorOf(sender)`. The new owner gets `filetrail:writeOperationAdopted` with the latest progress, and can fetch it again with `writeOperation:getAdopted`. With no successor, it is cancelled (`attachSender`, `:685`).
- Only the owner may cancel or answer questions.
- Other windows get broadcasts with the items trimmed by `itemsForOtherWindows` (`Contracts/writeEffects.ts:90`).
- The analysis report sent to a window is trimmed: children only under `directory_conflict` nodes (`trimAnalysisReportForWindow`, `:2406`).

---

## 2. Conflict detection and choices

### 2.1 Analysis report (`copyPasteAnalysis.ts:51-332`)

**Destination checks:**
- `captureFolderFingerprint` (a symlink to a folder counts as that folder).
- Missing → issue `destination_missing`; not a directory → `destination_not_directory`.
- Case sensitivity is asked once per analysis (`detectCaseSensitivity`, section 2.6).

**Issues for each source, in order:**
1. **Source missing** (lstat fails) → `source_missing`.
2. **Same item** → `same_path`, when any of these holds:
   - `sourcePath === destinationPath`;
   - cut mode into its own folder (by identity);
   - the source and the destination candidate are the same dev:ino.
3. **Into itself** → `parent_into_child` ("Cannot paste X into its own descendant."), for a directory source when any of these holds:
   - `realpath(dest) === realpath(src)`;
   - `realpath(dest)` starts with `realpath(src) + "/"`;
   - the source's dev:ino is among the ids of the destination and all its ancestors (`folderIdsHolding`, `:753`). This catches `/System/Volumes/Data` firmlink spellings and case-different paths.
   - If realpath throws: `source_missing`.
4. **Two sources land on one name** → `duplicate_destination_name` (e.g. `a/x` and `b/X` on a case-insensitive disk). The key is `destinationPathKey` = NFD, then lowercased unless the disk is case-sensitive (`copyPasteNames.ts:152`).
5. **Case-only clash inside a pasted folder** (from a case-sensitive source to a case-insensitive destination) → `nameCollisions`, added as `duplicate_destination_name` "…because the destination doesn't tell upper and lower case apart."
6. **Mount point inside a moved folder** → `source_unreadable` (section 1.3).

**`analyzeNode` (`:369`), recursive:**
- Fingerprints the source and the destination (`captureFingerprint`: lstat → `{exists, kind file|directory|symlink, size (files only), mtimeMs, mode, ino (null if not a safe integer, i.e. FAT/exFAT empty files near 2^64), dev, symlinkTarget}`; `copyPasteFingerprint.ts:10, 335`).
- **`classifyConflict` (`:852`):**
  - destination missing → `null` (new);
  - directory vs directory → `directory_conflict`, **unless either one is a package**, in which case it is a `file_conflict` (replaced or kept whole, never merged);
  - same non-directory kind (file/file, symlink/symlink) → `file_conflict`;
  - anything else (file vs folder, symlink vs file, …) → `type_mismatch`.
- **Packages:** `isPackageFolder` asks native `NSURLIsPackageKey` and falls back to the extension list (`copyPasteNames.ts:16-54, 129`). That list: action, app, appex, band, bundle, component, docset, fcpbundle, fcpxbundle, framework, imovielibrary, kext, key, logicx, mdimporter, mlmodelc, mlpackage, mpkg, musiclibrary, numbers, pages, photoslibrary, pkg, playground, plugin, prefpane, qlgenerator, rtfd, saver, scriv, sparsebundle, textbundle, workflow, xcarchive, xcodeproj, xcworkspace, xpc.
- **`wholePackage`:** a source directory with a non-directory-conflict clash has its children analyzed with `insideWholePackage` (the destination is never looked at).
- Children are read sorted. On FAT/exFAT/SMB, AppleDouble companions are dropped (`withoutAppleDoubleFiles`, `:517`): `._name` beside `name`, **and** `isAppleDouble` holds (the volume uses AppleDouble per `getattrlist VOL_CAP_INT_EXTENDED_ATTR`, and the file starts with the magic `00 05 16 07`).
- When merging, a source `.DS_Store` is skipped if the destination already has one.
- A readdir failure on the source sets `issueCode: "source_unreadable"`. That folder fails alone at execution; the rest of the paste continues.
- **Destination counts** for conflict nodes with a directory destination:
  - `destinationTotalNodeCount`: a recursive count excluding `.DS_Store`; null if unreadable.
  - `destinationOnly`: `{count, samplePaths ≤5}` of what exists only at the destination (kept by Merge, lost by Replace). Null for a package (`file_conflict`).
- **`replaceBlockedReason`** (`findReplaceBlockedReason`, `:678`), also annotated recursively into directory conflicts:
  - "It is the item being pasted.";
  - "It contains the item being pasted." (via realpath, ancestor ids, case-insensitive);
  - "It contains another item being pasted." (`holdsAnyOf`);
  - "It is another item being pasted." (`isAnyOf`, by identity, so hard links count).
- **`keepBothDestinationPath`:** precomputed with names reserved across siblings (`annotateKeepBothNames`, `:644`).

**Warnings:**
- `large_batch` when there are more than 100 nodes or more than 1 GiB (thresholds `writeService.ts:129-130`);
- `cut_requires_delete` for every cut.

### 2.2 Conflict classes and the choices offered

From `Contracts/copyPasteChoices.ts`:

| Class | Review choices (`copyPasteReview.ts:68`) | Notes |
|---|---|---|
| `file_conflict` (file/file, symlink/symlink, package vs folder or package) | Keep Both, Replace, Skip | No Merge |
| `directory_conflict` (plain folder vs plain folder) | Merge, Keep Both, Replace, Skip | |
| `type_mismatch` | Keep Both, Replace, Skip | |

- `isChoiceAllowedForConflict`: `merge` only for `directory_conflict`.
- **`choiceForConflict`:** a per-item override (if allowed) wins over the policy for its class. If the result is `overwrite` and `replaceBlockedReason != null`, it is downgraded to `merge` for a directory conflict and `keep_both` otherwise. The sheet and the engine both use this function.

**"For all conflicts" buttons** (`copyPasteReview.ts:102`):

| Button | file | directory | mismatch |
|---|---|---|---|
| Skip | skip | skip | skip |
| Add Missing | skip | merge | skip |
| Keep All | keep_both | merge | keep_both |
| Replace | overwrite | overwrite | overwrite |

Add Missing is hidden for cut mode, or when there are no directory conflicts. The sheet's initial policy is all-Skip.

### 2.3 Resolution (`copyPastePolicy.ts:142 resolveNode`)

- The action is the explicit (inherited) action; else `create` when there is no conflict; else `choiceForConflict`. A missing policy for a class with no override throws "Missing file conflict policy."
- `keep_both`: `resolveDuplicateName` with names reserved across the whole operation, then the destination is normalized to "new".
- Children's action (`:219`):
  - when the parent is `keep_both`, `overwrite`, or the explicit action is `create` → all children `create` (a fresh folder);
  - `merge` or `create` → each child resolves itself, and overrides keep applying inside a merged folder;
  - `skip` → children skip.

### 2.4 Keep Both and duplicate naming (`copyPasteNames.ts:89`)

**Splitting the name** (`splitNameExtension`, `:160`):
- multi-part extensions `.tar.gz`, `.tar.bz2`, `.tar.xz`, `.tar.zst`;
- for files, `extname`;
- for folders, the whole name is the base unless the folder is a package (macOS or the list says so), in which case the extension stays at the end ("Tool copy.app", "Talk copy.key", but "Movie.fcpxbundle copy" when macOS says it is not a package).

**Numbering:**
- `COPY_SUFFIX_PATTERN = /^(.+?) copy(?: ([2-9]|[1-9]\d+))?$/` (`:56`): "x copy" continues as "x copy 2"; "x copy 5" continues as "x copy 6".
- Not matched: "copy.txt" becomes "copy copy.txt"; "draft copy 1.txt" becomes "draft copy 1 copy.txt"; "a copycat.txt" becomes "a copycat copy.txt".
- Candidates: " copy", " copy 2", " copy 3", …, up to 10,000 attempts. After that: "Couldn't find a free name for “x”."

**Free name check:** a candidate is free only if it is not in the reserved set (keyed by `destinationPathKey`) **and** lstat returns ENOENT. Any other lstat error counts as taken.

**`fitName` (`:186`), keeping names within 255 UTF-8 bytes:**
- if `suffix + ext` alone is ≥ 255 bytes, the extension is folded into the base;
- otherwise the base is truncated by whole grapheme clusters (`Intl.Segmenter`), then `trimEnd()`.

**Other numbering schemes in the app:**
- New Folder: "name 2"…
- Undo Keep Both and batch rename: "name 2.ext" via `addNumberToName`.
- Replace fallback visible name and crash recovery `kept_visible`: `resolveDuplicateName`, i.e. " copy".

### 2.5 Runtime conflicts (found during execution)

**`findRuntimeConflict` (`copyPasteExecution.ts:2478`):**
- **Source side first:**
  - a folder compares identity only (`sameItemIdentity`: exists, kind, and ino/dev when both are known);
  - a file or link compares the full fingerprint (`fingerprintsEqual`: kind, size, mtime, mode, symlinkTarget, and ino/dev when both known);
  - result: `source_changed` or `source_deleted`.
- **Destination, by action:**
  - `create` / `keep_both`: anything present → `destination_created`;
  - `overwrite`: missing → no conflict (it becomes a copy); not `isAsApproved` (`:2576`; folders compare identity only, so a `.DS_Store` written by Finder does not count) → `destination_changed`, or `destination_created` if nothing was there at review;
  - `merge`: missing → `destination_deleted` (a deleted folder is never recreated silently); not a directory → `destination_changed` with class `type_mismatch`.

**Choices offered** (`getRuntimeConflictChoices`):

| Situation | Choices |
|---|---|
| `source_deleted` | Skip |
| `trash_unavailable`, or nothing at the destination now | Replace ("go ahead"), Skip |
| Directory conflict | Replace, Merge, Keep Both, Skip |
| Otherwise | Replace, Keep Both, Skip |

An answer not in the list is refused and the question stays open (`writeService.ts:257`).

**"Do the same for the rest"** (`applyToRemaining`): scoped by `getRuntimeConflictScope` to `"trash_unavailable"` or `"<source|destination>:<missing|conflictClass>"`. It is reused only when the saved answer is allowed for the new conflict (`writeService.ts:343-350`).

**Each question gets a unique id** (`conflictId-<n>`, `:675-698`), registered before the progress event is emitted, so an immediate answer is not lost.

**Question loop rules** (`:589-626`):
- at most 5 questions per item: "“x” kept changing, so it was left.";
- `assertNotWrittenByThisPaste` (`:720`): if this paste already wrote that name (or the same inode in that folder), fail with "…another item of this paste has the same name on this disk, which doesn't tell upper and lower case apart.";
- a source-side answer keeps the planned destination, so a destination change is still asked about separately;
- a changed source of a different kind (a file that became a package, a package saved anew, a folder that became a file) is re-analyzed (`readChangedSourceAgain` and `analyzeItemAgain`, `:807`), keeping the planned destinations of children the review saw, and enlarging `totalItemCount`;
- `merge` chosen when the item is no longer a folder: "“x” is no longer a folder, so it can't be merged and was left."

**Renderer side.** A question that cannot be serialized to the window is auto-answered "skip" (`writeOperations.ts:526`).

### 2.6 Case sensitivity, normalization, locks, permissions, cross-volume

**Case sensitivity** (`detectCaseSensitivity`, `copyPasteNames.ts:231`):
1. native `pathconf(_PC_CASE_SENSITIVE)`;
2. else probe: lstat an entry (or the folder itself) under its ASCII-case-swapped name. Same ino → insensitive; ENOENT → sensitive. No ids → unknown;
3. default: insensitive.

**Comparison keys:**
- `destinationPathKey` = NFD, lowercased unless case-sensitive.
- `placeKey` in undo = NFD + lowercase always.
- Rename's `namesMatchIgnoringCase` = NFC + lowercase.

**Locks:**
- `LOCK_FLAGS = UF_IMMUTABLE(0x2)|UF_APPEND(0x4)|SF_IMMUTABLE(0x20000)|SF_APPEND(0x40000)`; `USER_LOCK_FLAGS = UF_IMMUTABLE|UF_APPEND` (`copyPasteErrors.ts:51-57`).
- `unlockForMove` (`copyPasteExecution.ts:2009`) refuses SF flags and clears the UF flags, returning the original flags to restore.
- Replace refuses a locked destination before anything changes (`:1468`).
- Copies keep the lock: copyfile carries the flags, and the lock is re-applied after renaming into place.

**Permissions:**
- `openForMove` (`:2030`) gives a read-only folder u+w for the rename (macOS 14 refuses otherwise), then restores it.
- `canModifyFolder` (`access W_OK`) is checked before a cross-volume move copies anything.

**Cross-volume:** same-dev renames; EXDEV falls back to copy + verify + delete.

**Symlinks:**
- always copied as the link (copyfile NOFOLLOW_SRC);
- a destination folder given as a symlink is followed;
- `realItemPath` resolves the parent but not the item.

**FAT/exFAT empty files:** ids are unusable (`fileIdOf`), so identity comparisons fall back to kind, stamps and paths.

---

## 3. Safety mechanisms

### 3.1 Replace (`executeReplace`, `copyPasteExecution.ts:1443`): the user never ends up with neither item

**Steps 1-4: refuse before anything changes.**
1. `assertDestinationDoesNotContainSource`: "is the item being pasted, so it can't replace itself" / "contains the item being pasted".
2. A directory destination that holds another pasted item: refuse.
3. The destination is another pasted item: refuse.
4. The destination is locked: refuse.

**Step 5.** If the destination is not as approved, raise `DestinationTakenError`, which re-asks.

**Step 6.** A cut that cannot rename gets `assertRemovableAfterCopy(deep)`.

**Steps 7-8: stage the new item under a hidden name.**
- `temporaryPath` is the hidden sibling. Journal entry: `{stagingPath, finalPath, sourcePath, moved, staged}`.
- **Same-dev cut:** first journal `{moved:true, staged:true}`, then `moveExclusive(source → hidden)`. On EXDEV, fall back to copying.
- **Otherwise:** a directory gets `reserveStagingFolder`; journal `{moved:false, staged:false}`; `performNode` builds a plain copy into the hidden path (`recordsUndo:false`).
  - If an item inside was skipped because it changed (a runtime skip), the old item would be lost, so the Replace is undone: "“x” wasn't replaced because “y” in it changed and was skipped."
  - If anything inside failed: "…wasn't replaced because some items inside couldn't be copied." Only the failures are listed.
  - On success: journal `staged:true`.

**Step 9: swap.**
- `unlockForMove` and `openForMove` on the hidden item.
- `removeReplacedItem` (`:1837`):
  - **With a Trash:** `assertReplacedItemUnchanged` (fingerprint as approved), record the undo step, then `trash(dest)`. A null path → `markCantUndo("trash_location_unknown")`. Push `trashedPaths` and `replacedPaths`.
  - **Error `ENOTRASH`:** a directory needs a known approved count (the review count, or a count taken now); if it cannot be counted, refuse. Then ask a `trash_unavailable` runtime conflict:
    - "skip" → `undoStaging` (move a moved source back to where it was, or delete the copy), and report skipped;
    - "overwrite" → `findLockedInside` (refuse if anything inside is locked); `assertReplacedItemUnchanged` again, **including that the recursive count equals the approved count** (an item added during the question is never lost); `markCantUndo("deleted_for_good")`; `rm -rf`.
  - Any other trash error fails the item; nothing is deleted.
- `moveExclusive(hidden → final)`:
  - EEXIST → `DestinationTakenError`, re-ask;
  - any other error after the old item was removed → move to a **visible** " copy" name next to it, and fail with "The old “x” was moved to the Trash, but the new one couldn't take its name, so it was saved as “x copy”. <reason>";
  - if even that fails and there is a journal → "…It will be put there the next time File Trail starts." The journal entry is kept, `staged:true`.
- `restoreAfterMove`; `applyStagedFolderMetadata` (folders built by copy only); record the undo step: `moved` for a same-dev rename, `created` for a copy, `trashed` before either.

**Step 10.** Remove the journal entry. For a cut that copied: `removeMovedSources`.

**Undoing a failed stage** (`undoStaging`):
1. moves the source back from the hidden name if it was moved there;
2. otherwise sets the journal to `staged:false` **before** removing the hidden copy (`recordIncomplete`, `:2325`). This stops a partly removed copy from later being "finished" as if whole. If that journal write fails, the copy is left whole for recovery.
3. `removeOwnStaging` (`:2342`): no-op if `isGone`; else lstat (throws if unreachable, so the journal entry stays), then `removeStagedItem`.

**`removeStagedItem` (`:2067`):** `rm -rf`. On EACCES/EPERM, `makeFoldersWritable` recursively clears UF lock flags, sets ACL to none (`setAcl(null)`, e.g. a copy of ~/Documents with "everyone deny delete"), chmods folders 0700, then retries.

### 3.2 Hidden names

| Use | Name | Recovery pattern |
|---|---|---|
| Replace staging, folder staging, large-file partial | `"." + basename + ".filetrail-" + 8 hex` (`randomBytes(4)`), passed through `fitName` for 255 bytes; 10 attempts (`temporarySiblingPath`, `:1992`) | `STAGING_NAME = /^\..*\.filetrail-[0-9a-f]{8}$/s` (`copyPasteRecovery.ts:135`) |
| Batch rename blockers | `.filetrail-rename-` + 12 hex (`randomBytes(6)`) (`batchRenameExecution.ts:545`) | `/^\.filetrail-rename-[0-9a-f]{12}$/` |

Recovery only ever moves or removes items whose names match these patterns. Every progress event and question maps hidden paths back to the final names (`displayPath`).

### 3.3 Exclusive renames

- Every engine rename is `renameExclusive`, i.e. native `renamex_np(from, to, RENAME_EXCL)` (`native_rename.c:70`).
- On ENOTSUP, fall back to `lstat(to)` → EEXIST if it exists, else `rename(2)`. This leaves an accepted race window.
- Plain `rename()` is used only for case-only self-renames (rename, batch rename, undo).
- `mkdir` is non-recursive. `copyfile` uses `COPYFILE_EXCL`.

### 3.4 Cross-volume move verification

- Removal is refused up front when the originals cannot be removed (locks, W_OK on the parent and on the folder itself).
- Folders are built hidden and placed whole.
- An original is removed only if its copy still matches kind, size and link target (`copyMatchesSource`, `:2655`) **and** the original's fingerprint is unchanged.
- Folders are removed with readdir-guarded rmdir.
- A folder whose metadata could not be copied keeps its original.
- Stop is **not** honored while the originals are being removed (accepted risk).

### 3.5 Crash journal

**Format** (`Boot/writeJournal.ts`; types in `writeServiceTypes.ts:420-470`):
- File `~/Library/Application Support/<app>/replace-journal.json`: a JSON array of entries keyed by `id` (16 hex characters).
- `add` replaces an entry with the same id; writes are serialized.
- Each write goes to `file.tmp`, then `rename`. **There is no fsync** (accepted risk).
- A write failure throws "File Trail couldn't save its recovery information" (with an ENOSPC-specific message about the startup disk).
- An unreadable file is renamed `replace-journal.json.unreadable-<ms>` and the journal starts empty.

**Entries:**
- `replace` (`kind` may be absent in old entries): `{id, stagingPath, finalPath, sourcePath, moved, staged, movingCopy?}`.
- `partial_file`: `{id, partialPath, finalPath}`, only for files ≥ 32 MiB.
- `batch_rename`: `{id, items:[{temporaryPath, originalPath, newPath}]}`, one entry per folder-depth level.

**Recovery at startup** (`bootstrap.ts:227-235`; `recoverWrites`, `writeJournal.ts:82`). This runs before the `WriteService` exists. `answerWithinMs = 3000`: each folder involved must answer an lstat within 3 s, or the entry is `unreachable` and kept. Order:

1. **Partial files** (`removePartialFile`, `copyPasteRecovery.ts:106`):
   - lstat; ENOENT with the parent present → `nothing_left`;
   - a name that does not match the pattern → `nothing_left`;
   - else `removeStagedItem`.
   - Legacy: a "part" file inside a hidden folder removes that folder.
2. **Replaces** (`recoverEntry`, `:179`):
   - the staging item is gone (with the parent present) → `nothing_left`; unreachable → kept;
   - a name that does not match → `nothing_left`;
   - `moved`: if the final path is free, move it there (`finished`); else if the source path is free, move it back (`restored`); else to a visible " copy" name (`kept_visible`). It is never removed;
   - not moved: `staged` and the final path free → move into place (`finished`; a folder placed this way lacks its own tags and dates); else `removeStagedItem` (`removed_copy`);
   - moves go through `moveUnlocked` (unlock, move exclusively, relock).
3. **Batch renames** (`recoverBatchRename`, `batchRenameExecution.ts:577`). For each matching temporary item, try in order: the original path, the new path, then the original name numbered 2..10000. The person is told "A rename of several items was cut short… “a” is back under its old name; “b” is named “c”…".

**Notices at startup:**
- an item still under a hidden name (failed);
- an item being moved to a disk that is not connected (moved and unreachable);
- a `movingCopy` folder that was finished: "…It is in X now, and the original is still in Y too."

**Retry:** `retryRecovery` every 60 s (`RECOVERY_RETRY_INTERVAL_MS`) while not busy, only for entries left over from startup. The write part runs through `runWriteAlone` (`writeOperations.ts:672`), which needs the slot to be free and takes it. It reports "“x” is in place now, in “F”."

### 3.6 Write slot (one write at a time)

- `ensureNoWriteOperationInFlight` refuses with "Another write operation is already running." (or "File Trail is quitting.").
- `prepareWithReservedSlot` (`:659`) holds the slot with the sentinel id `"preparing-write-operation"` during async prechecks, so a concurrent request is refused. `getActiveOperation` hides the sentinel.
- **`WriteService` has its own slot:**
  - `startCopyPasteAnalysis` throws if an operation is active or another analysis is running (`ANALYSIS_BUSY_ERROR`);
  - `startCopyPaste` throws `WRITE_OPERATION_BUSY_ERROR`;
  - when a new analysis starts, finished analyses are pruned except those still open in other windows' reviews.
- **Release:** `emitLocalWriteOperationEvent` (`:877`) handles terminal events in this order: invalidate caches, then `recordUndo`, then free the slot, then send to the window. So history order matches operation order, and a renderer reacting to the end can start the next write.
- **Paste terminal:** the write-service subscriber (`:485`) does the same.
- **Unexpected end:** a local operation that throws gets a synthesized failed event ("The operation stopped unexpectedly: …").

### 3.7 Stop / cancel semantics

- **Stop is checked:**
  - between top-level items, between children of a folder, and between undo steps or batch levels;
  - inside a file copy, through the native stop flag (`stoppableCopy.ts`): `Int32Array(4)`; element 0 is the stop flag; elements 2-3 hold the bytes copied as an int64, read every 250 ms for progress. copyfile's callback returns `COPYFILE_QUIT` during the data stage, the copy fails with ECANCELED, which becomes an AbortError.
- **What a stop leaves behind:**
  - a cancelled hidden folder is discarded whole (copy or move: nothing is left in either place);
  - a cancelled Replace removes its hidden copy and leaves the old item untouched;
  - items not started are reported `cancelled` with "Not started because the operation was stopped."
- **Local operations** (trash, delete, batch, undo) report "Stopped after N items were moved to the Trash" (or deleted, renamed, undone, redone).
- **A stop that arrives as the last item finishes** stops nothing (batch rename and undo).
- **Native error handling:** on a copyfile failure stage, xattrs are skipped except the resource fork, whose failure ends the copy with the write's errno.

### 3.8 Progress events and cadence

- **Engine:** emits `running` at the start, after each leaf or folder creation, during a large file (bytes from the native counter, polled every 250 ms and only when the count grew), `awaiting_resolution` with a `runtimeConflict`, and a terminal event carrying `result` (`completedItemCount`, `totalItemCount`, `completedByteCount`, `totalBytes`, `currentSourcePath`, `currentDestinationPath`).
- **Step counting** (`countExecutableSteps`, `:2870`):
  - skipped nodes are not counted;
  - a merged folder does not count itself;
  - a renamed subtree counts all of its items at once;
  - `totalBytes` is null when any renamed-whole folder exists.
- **Coordinator throttle** (`deliverProgress`, `:594`): plain `running` updates go out at most every `PROGRESS_UPDATE_INTERVAL_MS = 100` ms (trailing timer, newest wins). Questions and terminal events go out immediately and flush any pending update.
- **Local operations** emit `queued`, then `running` per item, then terminal.
- **Undo progress** counts steps plus batch items (`itemStepCount`).

---

## 4. Undo

### 4.1 Log format (`Core/undoLog.ts`)

```text
ItemId = {dev, ino} | null   // null for FAT/exFAT empty files, or unreadable
ItemKind = file | directory | symlink | other
ItemStamp = {kind, size(file), mtimeMs, entryCount(dir, excluding .DS_Store and paired ._name),
             entryNames?: sha1(sorted names joined by \0)}
UndoStep =
  moved{from, to, id, itemKind, parentId, fromTrash?, stamp?, locked?}
  created{path, id, stamp}
  trashed{from, trashPath, id, parentId, stamp? (only when id is null)}
  batchRenamed{items:[{from, to, id, itemKind}]}
UndoUnit = {steps[]}          // one per top-level picked item
UndoLog = {undoable:true, units} | {undoable:false, reason}
CantUndoReason = merge | deleted_for_good | no_trash | other_disk_move | trash_location_unknown
```

- `parentId` is read with `stat` (links followed; `readFolderIdOnce` caches it per operation).
- Created items are stamped when their unit closes. A folder's id is read at creation time.

### 4.2 What each operation records

| Operation | Record |
|---|---|
| Rename | 1 unit `[moved]` |
| Batch rename | 1 unit `[batchRenamed(movedItemsOf …)]`: every item whose final basename differs, including "b 2" or a hidden-name leftover; nothing if no items |
| New folder | `[created]`, or `no_trash` |
| Trash | one unit per item `[trashed]`; any null `trashPath` → `trash_location_unknown`; nothing if nothing went |
| Delete Immediately, Empty Trash | `deleted_for_good` (not recorded if nothing was touched, or Finder refused before starting) |
| Paste / copy / duplicate | per top-level unit: `created` (copy, keep both, staged folder; a partly failed folder too) or `moved` (same-dev rename). Replace = `trashed(old)`, then `created` or `moved(new)` at its real final path (possibly the visible " copy" name) |

**Cannot be undone:**
- `merge`: a merged folder that changed anything (`expectCantUndo` + `noteChanged`; a merge that found everything already there leaves Undo unchanged);
- `other_disk_move`;
- `deleted_for_good`: a Replace on a disk with no Trash;
- `trash_location_unknown`.

The coordinator then turns a log into `no_trash` if any `created` item's folder is on a disk without a Trash (`pasteUndoLog`, `writeOperations.ts:317`).

**`diskHasTrash`** (`Boot/diskHasTrash.ts`):
- realpath of the nearest existing ancestor, plus the remainder;
- the longest matching mount from `nativeListMounts` (`getmntinfo`), compared case-insensitively;
- result: `isLocal`, default true;
- an exception is treated as false.

An empty log (`units.length === 0`) leaves the history unchanged.

### 4.3 History (`Boot/undoHistory.ts`)

- **`record` (`:79`):** clears Redo. A non-undoable log (or `empty_trash`) also clears Undo and sets `cantUndo` (menu "Can't Undo"). Otherwise push `{id, action, units, moves, size}`.
- **Size cap:** `UNDO_HISTORY_MAX_ITEM_STEPS = 1_000_000` across both lists. The oldest entries are evicted from the bottom of Undo, then Redo, never the entries just changed.
- **`finish(direction, entryId, {done, leftover})` (`:108`):**
  - throws if the entry is no longer on top;
  - pops the entry;
  - pushes the leftover back on the same list;
  - pushes `done` as a **new** entry on the opposite list (each attempt is its own entry).
  - A `generation` counter increments on every change.
- **Menu labels** (`labelOf`, `:163`):
  - "Rename"; "Rename of N Items";
  - "New Folder";
  - "Move to Trash of “x”" / "… of N Items";
  - "Duplicate of …", "Move of …" (`move_to`), "Copy of …" (`copy_to`);
  - `paste` → "Move" if any non-fromTrash `moved` step, else "Copy" (`moves` is kept for the entry's lifetime).
  - Computed from the units left, so a stopped Undo of 3 items reads "of 2 Items".

### 4.4 Plan (`Boot/undoPlan.ts`)

**`reverseStep` (`:52`):**

| Step | Reverse |
|---|---|
| `moved` | `move(to → from)` |
| `moved fromTrash` | `trash(to)`, `putBack:true`, `unlock` = `locked` |
| `created` | `trash(path)`, `unlock:true` |
| `trashed` | `move(trashPath → from)`, `putBack:true`, `itemKind` = stamp kind, `stamp` |
| `batchRenamed` | `batch(to → from)` |

Units are run newest first, and the steps inside a unit in reverse order.

**`checkMove` (`:283`):**
- **Look up the source** (`lookUp`):
  - ENOENT/ENOTDIR → missing;
  - other errors → `retry`, so the step stays on the list.
- **Identity** (`isExpectedItem`, `:226`):
  - the same id, or
  - relaxed (not a put-back): the same kind at the path, so an app's safe-save with a new inode still counts;
  - without ids: the kind only.
- **Id-less put-back:** the stamp must match (`sameStamp`: folders by count and names digest; files by size and mtime). An unreadable folder listing → retry.
- **Reason texts:**
  - missing: "“x” is on “Disk”, which isn't connected." / "“x” isn't in the Trash any more." / "“x” is no longer in “F”."
  - replaced: "…is on a disk that was disconnected since…" (same ino, different dev) / "The “x” in “F” is another item now."
- **Parent folder** (stat):
  - missing or not a directory → "Its folder “F” no longer exists.";
  - id mismatch → "…was replaced by another folder" (or "…is on a disk that was disconnected since…").
- **Target:**
  - free, or vacated by an earlier step in the unit (by id, or by `placeKey` when there is no id) → OK, unless an earlier step filled it (`nameTaken`);
  - otherwise `findsItself` (`:367`): a case or normalization variant, the same id or no ids, and the readdir does not list the exact spelling → `renamesItself`; else `nameTaken`.

**`checkTrash` (`:383`):**
- requires an exact id match (not relaxed);
- `changed` = the stamp differs (a missing stamp with a null id counts as changed, so the person is asked).

**`checkBatch` (`:435`):**
- refused items keep their names; the rest make way for each other;
- the target is `dirname(from)/basename(to)`;
- `nameTaken` unless the occupant is a batch item at that exact place (by id).

**`findQuestions` (`:525`):**
- looks at up to 16 units concurrently (`mapAtMost`), results in unit order;
- produces `nameTaken[{name, path}]` and `changed[{name, path, putBack, replaced}]`;
- within a unit: a missing step is skipped (continue); a refused step stops the unit (break).

### 4.5 Execution (`Boot/undoExecution.ts`; coordinator `writeOperations.ts:2114-2225`)

**`undo:prepare`** (does not take the slot):
- refused with `busy` if the slot is taken or the app is closing;
- refused with `nothing` while another prepare runs, or when the list is empty;
- refused with `cant_undo`;
- else `findQuestions` within `UNDO_CHECK_WITHIN_MS = 10_000`. A timeout gives "A disk didn't answer while Undo looked at its items. Choose Undo again once it does."
- Returns a ticket (`dir:entryId:generation:n`), the label, the action, and the names to ask about. Tickets from other generations are pruned.

**Renderer questions** (all or nothing):
- name taken: Cancel / Keep Both (default Keep Both);
- changed: Cancel / Move to Trash (default Cancel), with a message such as "“1 copy.kt” was changed after it was duplicated…".
- Up to 5 names are listed.

**`undo:start`:**
- verifies the entry is still on top with the same generation, else "Something changed since Undo was chosen. Choose it again.";
- recomputes the questions inside the reserved slot (10 s limit);
- refuses if any new `changed` or `nameTaken` appeared: "“x” was changed after Undo was chosen…" / "Another item took the name “x”…";
- queues a local operation with `changedAgreed` = the paths asked about.

**`runUndo` (`:83`):**
- For each step:
  - stop check;
  - `onStepStart` progress;
  - `runStep`, with outcome `done`, `skipped`, `failed` or `stopped`.
- **Inside a unit:**
  - a `skipped` step that is not missing **blocks** the remaining steps of the unit. Their messages: "“x” was left in the Trash, because the item in its place couldn't be moved away." / "…because the step before it couldn't be undone."
  - a `failed` step and the earlier steps of its unit go to the leftover;
  - a `done` step with no produced step (Trash did not say where) marks the unit unrecorded, so nothing of it goes to Redo.
- `leftover` = units a stop did not reach, plus failed units.
- `done` = units actually done, which go to the other list.

**`moveBack` (`:342`):**
- a put-back with an id: `liftRestrictions` (`:412`): unlock (user flags), chmod u+w on a read-only folder, remove an ACL containing `:deny:`;
- `renameInto` (`:516`): if the name is taken, use `freeNumberedPath` ("a 2.txt"…; a plain folder takes the number at the end, a package before its extension); `rename` when `renamesItself`, else `renameExclusive`; on EEXIST, retry the next number, up to 3 attempts;
- restore the lifted restrictions on the target. If they could not be restored, note "…its lock or permissions couldn't be put back. Set them in Finder's Get Info.";
- produced step: `moved{fromTrash?, stamp of target, locked?}`.

**`moveToTrash` (`:605`):**
- `checkTrash`;
- changed and not agreed → failed and kept ("…was changed after Undo was chosen, so it was left as it is.");
- `unlock` with an id → `liftRestrictions`, then `fs.trash`, then restore the restrictions **on the Trash path**;
- produced step: `trashed`; `removedItems` adjusts folder sizes.

**`renameBack` (`:682`), batch undo:**
- any unreadable item → the whole batch is retried;
- otherwise `runBatchRename` with `onConflict:"number"`, separator " ";
- an item that took a number only because a failed batch item still holds its name "waits": it is recorded as done to the numbered name **and** left over from there;
- per-item error classification.

**Write-error classification** (`classifyUndoWriteError`, `:271`):

| Codes | Outcome |
|---|---|
| ENOENT, ENOTDIR, EEXIST | `outside_change`: skipped and dropped |
| ENOTRASH (only when the cause was ENOTSUP or the disk is known to have no Trash), EROFS, EXDEV | `permanent`: skipped, dropped and explained |
| Anything else | `retry`: kept on the list ("⌘Z tries again what couldn't be undone") |

**After the run:**
- `history.finish(done, leftover)`, inside a try block;
- status: cancelled → partial or cancelled; problems → partial or failed; else completed.
- If the whole run throws unexpectedly, the entire entry stays as leftover.

**What is undoable:** see the table in section 4.2. Undo of Delete Immediately, Empty Trash, merges, other-disk moves, Trash on disks with none, and unknown Trash locations is impossible: Undo reads "Can't Undo" and both lists are cleared.

---

## 5. Batch rename

### 5.1 Settings

`apps/desktop/src/shared/batchRename.ts:27-115`; schema `Contracts/ipc.ts:699`.

**Modes:**
- `replace`: `find`, `replaceWith`, `matchCase`, `useRegex`.
- `add`: `addText`, `addWhere` after/before.
- `format`:
  - `nameFormat` index / counter / date; `formatWhere` after/before;
  - `customName` (default "File") or `keepNames`;
  - `startAt` (≥0, default 1), `step` (≥1);
  - `digits` auto/2/3/4/5 (default 5);
  - `separator` " " / "-" / "_" / "";
  - `dateSource` created / modified / taken / today;
  - `dateFormat` ymd, ymd_hm, ymd_hms, dmy, dmyy, mdy, yymd, ym, or custom;
  - `dateSeparator` "-" "_" "." " " "";
  - `customDatePattern` (default "YYYY-MM-DD at HH.mm").
- `case`: `caseStyle` lower / upper / title.

**Common settings:**
- `applyTo` name / extension / both, for all modes except format, which always keeps the extension;
- `onConflict` number / skip / block (default number).

**Sanitizing:**
- `sanitizeBatchRenameSettings`: unknown values take the default; text is clamped to 255 characters; numbers are clamped to 999,999,999.
- Presets: at most 50; a name must be non-empty and unique case-insensitively, at most 80 characters.

### 5.2 Name computation (`proposeNames`, `:302`)

- **Splitting** (`splitItemName`, `:224`): the extension follows the last dot. There is none for a folder, a leading-dot-only name, or a trailing dot. Packages count as files here (the `isFolder` flag comes from the request).
- **Replace** (`:358, :449`):
  - the find text is NFC-normalized and the name part too;
  - plain text is escaped; flags `g` plus `i` unless matchCase, plus `u`;
  - every match is replaced;
  - regex replacements expand `$$ $& $\` $' $1..$99 $<name>` (`expandReplacement`, `:485`): two digits only if that group exists; unknown tokens are kept literally;
  - a broken regex gives the settings error "The pattern isn’t valid: …" and nothing is renamed.
- **Add:** text before or after the part.
- **Case:** lower, upper, or title (an `\p{Ll}` after the start or after `[\s_\-.([{]` is uppercased; the rest is unchanged).
- **Format** (`:558`):
  - the tag is a number (`formatNumber`: `startAt + index*step`; counter zero-padded to `digits`, or for auto to the width of the last number) or a date;
  - dates use tokens YYYY, YY, MM, DD, HH, mm, ss; `[text]` is kept literally;
  - a custom pattern without a token gives the error "Put at least one of YYYY, YY, MM, DD, HH, mm or ss in the date pattern";
  - date taken missing → the created date is used, flagged `usedCreatedForTaken`; a missing date leaves the item unchanged.
- **applyTo:**
  - `extension`: an extension replaced with nothing drops the dot;
  - `name`: spaces at the stem's ends are trimmed, so "a copy.txt" minus "copy" gives "a.txt";
  - an empty stem with an extension sets the `emptyName` flag (an invalid name).
- **Trimming:** the whole name is trimmed. A name equal in NFC to the old one counts as unchanged.

### 5.3 Plan / conflict policy (`planBatchRename`, `:805`)

**Per folder:**
- `nameKey` = NFD, lowercased unless the folder is case-sensitive;
- an unknown folder is assumed to hold only the batch items.

**Invalid or impossible items** (left as they are; they keep their names taken):
- `getItemNameError` failures: empty, "." / "..", contains "/" or NUL, more than 255 bytes, or `emptyName`;
- `cannotRename`, from `batchRename:inspect` (`batchRenameInspect.ts`): gone, the Trash, the folder locked, the folder not writable, the item locked, or `assertNotSystemLocation`.

**Taken set:** all folder names, minus the old names of items being renamed (this allows swaps), plus the names of items left as they are.

**In order, first come first served:**
- a free name is given;
- a taken name, by policy:
  - **number:** `findNumberedName` with Format's separator (if non-empty) or " ", starting from `nextNumber[name]` (default 2), up to 100,000. Numbering an item back to its own name means unchanged; a numbered name that is too long becomes an invalid problem;
  - **skip:** `skippedTaken`. Skips then cascade along the chain: the item that was given a skipped item's old name is skipped too;
  - **block:** `taken`, which blocks the whole rename until fixed.
- `becomesHidden`: the new name starts with "." and the old one did not.
- Counts: rename, unchanged, skipped (skippedTaken plus cannotRename), blocking.

`addNumberToName` (`:240`) puts " N" before the extension (at the end for a folder) and truncates the stem by graphemes to fit 255 bytes. If nothing would be left, the name stays too long.

### 5.4 Execution

Coordinator: `writeOperations.ts:1128/1150`. Engine: `runBatchRename`, `batchRenameExecution.ts:64`.

**Prepare:**
- drop items whose name is unchanged ("Nothing would be renamed." if none are left);
- duplicates → "“x” is in the list twice.";
- `assertNotProtectedPath`, `assertNotSystemLocation`.

**Run:**
1. **Levels, deepest first** (by path depth), so a folder and items inside it can be renamed together. Folders already renamed carry their children's result paths along (`followFolderRename`).
2. **Blockers:** items whose old name (`looseKey` = NFD + lowercase, per folder) is wanted by another batch item.
3. **Journal per level** (`batch_rename` entry with each blocker's temporary path, original path and new path), written **before** any move. If the journal write fails, every item at that level fails: "It wasn't renamed. …"
4. **Move blockers aside:** `renameExclusive(src → folder/.filetrail-rename-xxxxxxxxxxxx)`. A taken temporary name fails the item.
5. **Rename each item in request order** (`renameItem`, `:316`):
   - a case-only self-rename (`renamesItself`, `:421`) uses `rename()`. It applies when the loose keys are equal, both lstat to the same id (or ids are unusable), and either the disk is known case-insensitive with only the case changing, or the readdir lacks the exact new spelling;
   - else `renameExclusive`. On EEXIST:
     - **number:** `numberedName(dest, isFolder, numberSeparator, n)`, n from 2 to 10,000;
     - **skip:** `leaveUnrenamed` as skipped;
     - **block:** failed.
6. **`leaveUnrenamed` / `restoreFromTemporaryName`** (`:365/:399`): a blocker goes back to its old path; if that is taken, its old name numbered; else it stays hidden (reported with "(hidden)").
7. **Stop:**
   - before any item of the level has been renamed, everything goes back;
   - once a swap is under way (all blockers moved aside and at least one renamed), items already moved aside still finish, so no name is left stolen;
   - a stop arriving with the last item does not count.
8. **After each level:** the journal keeps only items still hidden. Their folders are not renamed later ("…an item in it is still under a hidden name.").
9. **Results:** each item `{sourcePath, destinationPath, status, error}`. Lock errors via `findLockedRefusal`. The undo step is built from `movedItemsOf`.

---

## 6. Native calls per step

| Step | Native / system call |
|---|---|
| File copy (paste, partial file, hidden-folder write, symlink copy) | `nativeCopyFile` → `copyfile(src, dst, state, COPYFILE_ALL \| COPYFILE_CLONE \| COPYFILE_NOFOLLOW_SRC \| COPYFILE_EXCL \| COPYFILE_DATA_SPARSE)` (`native_copyfile.c:112`). The status callback (`:73`) handles the stop flag (QUIT during COPY_DATA), progress (`COPYFILE_STATE_COPIED`), skipping xattr errors except the resource fork, and QUIT on data errors. CoW clone happens through COPYFILE_CLONE; `clonefile` is never called directly. |
| Folder metadata after its contents | `nativeCopyMetadata` → `copyfile(COPYFILE_METADATA \| COPYFILE_NOFOLLOW_SRC)` (`:152`), then `utimes` to restore the mtime on a move. Fallback: `chmod` + `utimes`. |
| Folder creation, staging folder | `mkdir` (non-recursive) |
| Exclusive rename (move, swap, recovery, batch, undo) | `nativeRenameExclusive` → `renamex_np(RENAME_EXCL)`; on ENOTSUP, `lstat` + `rename` (`native_rename.c:70`) |
| Case-only rename | `rename(2)` (`original-fs`) |
| Case sensitivity | `nativeIsCaseSensitive` → `pathconf(_PC_CASE_SENSITIVE)` (EINVAL → null) |
| AppleDouble volume | `nativeUsesAppleDouble` → `getattrlist` `VOL_CAP_INT_EXTENDED_ATTR` (`:266-271`), plus reading the 4-byte magic |
| Package detection | `nativeIsPackage` → `NSURL getResourceValue:NSURLIsPackageKey` |
| Lock flags | `nativeGetFlags` → `lstat st_flags`; `nativeSetFlags` → `lchflags` |
| ACLs | `nativeGetAcl` → `acl_get_link_np(ACL_TYPE_EXTENDED)` + `acl_to_text`; `nativeSetAcl` → `acl_from_text` or `acl_init(0)` + `acl_set_link_np` |
| Trash | `nativeTrashItem` → `-[NSFileManager trashItemAtURL:resultingItemURL:error:]` (`native_trash.m:113`). Returns the resulting path, or null. Error mapping: POSIX domain or underlying → errno; Cocoa: FeatureUnsupported → ENOTSUP, NoSuchFile → ENOENT, NoPermission → EACCES, ReadOnly → EROFS, OutOfSpace → ENOSPC, FileExists → EEXIST, …; `kFSOperationNotSupported` (-1426) → ENOTSUP. Includes `cocoaCode` and `localizedDescription`. |
| Removal | Node `rm` (recursive, force) and `rmdir` (guarded by readdir) |
| Permission precheck | `access(W_OK)` |
| Item size for folder-size cache | `nativeItemSize` |
| Mount table, disk has Trash | `nativeListMounts` → `getmntinfo` (`MNT_LOCAL`) |
| Disk ids for drag | `stat().dev` |
| Dates taken (batch rename) | `nativeDatesTaken` (EXIF via ImageIO) |
| Empty Trash | `osascript` → Finder `empty trash` |

Swift equivalents to use: `copyfile` (call it directly; there is a C API), `renamex_np`, `NSFileManager.trashItem(at:resultingItemURL:)`, `lchflags`, the `acl_*` functions, `URLResourceKey.isPackageKey`, `pathconf`, `getattrlist`, and `getmntinfo`.

---

## 7. Test checklist (port as XCTest cases)

Grouped by area. The titles are the original `it()` names, condensed; `%s` marks parametrized variants. About 1,300 cases across roughly 65 files.

### A. Analysis / review (`copyPasteAnalysis.test`, `copyPasteReviewEdges`, `copyPasteReviewData.realfs`, `writeService.test`, `copyPasteLargeTree`)
- [ ] Normalizes paths; a new file into an empty destination.
- [ ] Same-folder copy resolves to a Keep Both (" copy") name; same-folder cut is blocked as a self-target.
- [ ] Top-level and nested conflicts are flagged recursively; destination and source issues are detected.
- [ ] Refuses a directory into its own descendant, including one reached by another spelling (symlink, case, firmlink).
- [ ] Can't Replace an item pasted too under another spelling.
- [ ] Sources from different folders landing on one name → `duplicate_destination_name`.
- [ ] Falls back to `source_missing` when realpath checks fail.
- [ ] Folder moved on its own disk: renamed whole without reading inside; read through a symlink etc. (`%s`).
- [ ] Large-batch (by count and by size) and cut warnings.
- [ ] `destinationTotalNodeCount`: recursive, counts dotfiles and symlinks, 0 for empty, null for file conflicts, counts a mismatch folder, null for new items or readdir failure, deep trees, mixed kinds, cached for nested conflicts, propagates abort; symlink sources are first-class nodes.
- [ ] Case-sensitive volume: case-variant names land side by side; Keep Both reserved by exact case; the volume is asked once per analysis; disk reads scale with the items pasted.
- [ ] Disk mounted inside a folder: refuse moving to another disk; copy includes the disk; same-disk move works; refuse merging on the same disk.
- [ ] Case detection: probes itself when asking the volume fails; uses the folder's own name when it is empty or unreadable; skips names without letters and defaults to insensitive; can't tell without ids or when the lookup fails.
- [ ] `destinationOnly` is unknown when a nested folder is unreadable; `.DS_Store` is not counted.
- [ ] `fitName` keeps an absurdly long extension as part of the base.
- [ ] Review data: Keep Both names reserved across the paste; destination-only items listed with nesting; a folder a pasted file would replace counts as lost entirely; Replace blocked for a container of the source; per-item choices override the policy; standing answers through the write service.
- [ ] More than ~125k items: analyze and copy without stack overflow.
- [ ] `.asar` files copied and analyzed as files.
- [ ] Execute bits preserved; unsupported chmod is non-fatal.

### B. Policy and choices (`copyPastePolicy.test`, `Contracts/copyPasteChoices.test`, `copyPasteBlockedReplace`)
- [ ] File conflicts: overwrite, skip, keep both.
- [ ] Directory conflicts: merge, skip, keep both; children inherit.
- [ ] Mismatch policy for type conflicts.
- [ ] An incomplete policy is rejected (`%s`).
- [ ] Children of "/" joined without a double slash.
- [ ] Explicit runtime actions override the policy.
- [ ] Children of an overwritten directory become creates.
- [ ] Merge only for two folders; only Skip when the source disappeared; only go-ahead or skip when the destination is gone.
- [ ] Standing answers scoped to the same kind of conflict.
- [ ] Replace downgraded to the safe choice (merge or keep both) when blocked, whether set for all or per item; also enforced by the paste itself; also for a folder holding another pasted item reached by another spelling.

### C. Naming (`copyPasteNames.test`, `Contracts/itemName.test`, `copyPasteRuntimeSafety` duplicates)
- [ ] Keep Both path from the source basename; files with and without extensions.
- [ ] A copy of a copy is numbered ("x copy" → "x copy 2", "plan copy 2.md" → "plan copy 3.md", "big copy 99999" → "big copy 100000").
- [ ] Look-alikes untouched ("copy.txt" → "copy copy.txt", "draft copy 1.txt" → "draft copy 1 copy.txt", "a copycat.txt" → "a copycat copy.txt").
- [ ] The first suffix is used when free.
- [ ] Folders keep their whole name except bundles; document packages keep the extension last; macOS's package answer wins over the extension.
- [ ] `.tar.gz` and similar count as one extension.
- [ ] Any lookup error other than ENOENT means taken.
- [ ] Case folding only on case-insensitive volumes; case sensitivity detected by a swapped-name lookup.
- [ ] Names limited to 255 UTF-8 bytes; truncation by graphemes; Keep Both shortened to fit.
- [ ] `getItemNameError`: dots and colons OK; empty, "." and ".." rejected; "/" and NUL rejected; byte limit.
- [ ] `isMacOSPackageName` in any case.
- [ ] Duplicating several items: each copy named apart when one copy's name is another item's name; the same names whatever the order.

### D. Execution: copy and merge basics (`copyPasteExecution.test`, `.realfs`, `writeService.test`, `copyPasteNative.realfs`, `copyPasteSymlinkMetadata`)
- [ ] Copy a file with a completed result; counts only what Add Missing copies toward bytes.
- [ ] Overwrite; Merge with nested actions; hidden files and folders.
- [ ] Replace a folder, deleting destination-only items; no prompts for descendants of a replaced folder.
- [ ] A file overwritten by a directory (mismatch); Keep Both for files and for directories (with children copied).
- [ ] Symlinks copied as links; a link keeps its own xattrs (`%s`).
- [ ] Mode and mtime kept and re-applied only when dropped; mtime set on directories after their contents; utimes absent, ENOTSUP or EOPNOTSUPP ignored; a folder whose date can't be set doesn't fail; utimes uses the source mtime for both atime and mtime.
- [ ] Progress bytes reported during a file copy; a copyFile error fails the operation.
- [ ] Locked file copied stays locked; folder Finder tags, mode and date kept; a locked folder copied with its items.
- [ ] Partial and failed statuses when later or first items fail; skipped → partial.
- [ ] Doesn't remove an item after a failed copy unless it created it; asks about a file that takes its name while being copied.
- [ ] Folder metadata applied after its items, and the date put back after a move; mode/date fallback when metadata can't be copied.
- [ ] An unreadable folder is left in place with "wasn't moved".
- [ ] Merge into a folder at the top of the disk.
- [ ] A pipe can't be copied (special-file message).

### E. Moves (per-file cut, rename fast path, cross-volume) (`copyPasteExecution.test`, `copyPasteMoveCleanup`, `copyPasteVolumes.realfs`, `copyPasteLocked.realfs`)
- [ ] Source removed only after a successful copy; a changed source is preserved; source deleted externally; empty source dir removed; a non-empty one kept when children were skipped; dir mode changed externally → kept; rm failures reported while continuing; nested mixed actions; rm called once per file; runtime skip preserves the source; runtime overwrite deletes it inline; a nested failure propagates to the parent's status; a mutated source → failed.
- [ ] Same-dev rename for a file, a symlink and a directory (whole subtree); cross-dev falls back to copy + delete; EXDEV fallback; non-EXDEV rename errors fail; copy mode never renames; merge never renames; the inode is preserved.
- [ ] Rename + overwrite moves the old item to the Trash (for a file and for a directory); no Trash → delete only if the person agrees, and everything is put back on skip; overwrite dir↔file; the pre-delete is skipped if the destination vanished.
- [ ] Cancel between renames; a runtime-created destination folder for a file is classed as a mismatch; a renamed-whole folder counts as one item of unknown size, and is left untouched on EXDEV or when its name was taken meanwhile (no question).
- [ ] Mixed-dev batches.
- [ ] Moving folders with hidden files; emptied source folders removed even though their mtime changed; a source folder changed before cleanup is preserved.
- [ ] Cross-disk: file; folder; Replace removes the original only once the new one is in place; items added during the move are named; a folder with only Finder's `.DS_Store` is removed.
- [ ] Original kept if: its copy was deleted before cleanup; the copy is short; a link target changed; a single file's copy came out short; the folder's metadata couldn't be copied.
- [ ] Originals that changed after review and that the person went on with (file, folder saved anew, folder→file, file→folder) are removed; the message names the item as what it is.
- [ ] Case-sensitive source: stop before pasting a folder with case-variant names; names that stay apart paste fine.
- [ ] Disk fills up: the move fails with the reason, keeps the original, leaves no partial file.
- [ ] Empty files on FAT/exFAT (`%s`): asks instead of refusing; moves among other empty files; replaces inside a merge.
- [ ] FAT32 AppleDouble: the attributes go with the item; the `._` file isn't copied as an item.
- [ ] Locked: a locked file to be moved says it is locked; a locked folder isn't copied to a disk it then can't remove; a read-only source folder → nothing copied, with the reason.
- [ ] Moving to another disk with Replace refuses, before anything is replaced, a locked file or a folder holding one.

### F. Replace safety (`copyPasteConflictSafety.realfs`, `copyPasteEdgeCases`, `copyPasteRuntimeSafety`, `copyPasteScenarioMatrix`, `copyPasteStagedDiscard`, `copyPasteLocked`, `copyPasteFolderSafety`)
- [ ] Refuse replacing a folder containing the item pasted (`%s`), through a symlinked folder (`%s`), or a folder by a file it contains; a destination through a symlinked folder treated as the source folder.
- [ ] Replaced items go to the Trash (copy and same-disk move); no Trash → ask (`%s`); the Trash refuses → fail without offering delete-for-good; a replacing folder moved back when the person skips the no-Trash question.
- [ ] The hidden name never shown.
- [ ] Item changed after review → asked again; already gone → copied without asking.
- [ ] Keeps going after failures (also inside folders), reporting every item; items never started are reported on stop.
- [ ] Merges into a folder that appeared during the paste; the existing file kept when the replacement can't be written; the existing folder kept when items in the replacement can't be copied.
- [ ] Moving a replacing folder from another disk removes the originals last; a moved folder whose items were skipped while merging is kept.
- [ ] Asks instead of moving over an item that appears at the last moment; no re-ask when only a folder's timestamp changed (`.DS_Store`); asks when the merge target was deleted (`%s`).
- [ ] A folder whose every item failed reports failed with a count.
- [ ] Keeps asking forever is prevented (5 attempts) for an item that changes after every answer, or a name taken every time.
- [ ] Asks about a folder or symlink target appearing mid-copy; asks before merging into a folder that became a file.
- [ ] Stop inside a folder copy leaves nothing; stop while building a replacement leaves the existing item.
- [ ] Last step of Replace: name taken in the gap → re-ask; no name possible → left to the next start; an SF-locked item refused; asks before deleting for good without a Trash.
- [ ] A replacing cross-disk move reports an original it couldn't remove; refuses to replace an item with itself even when that became so after the review; recovery relocks a hidden item it can't move.
- [ ] The folder holding another pasted item: blocked in review; Replace for all → merge; merged once the other item moved out first.
- [ ] Both sides changed → both asked; only the source changed → asked once.
- [ ] The swap can't take the old name → visible name.
- [ ] Symlinked destination folder; duplicate into its own folder through a symlink.
- [ ] Source changed kind: file→package copied as the whole package; replaced with the whole package, never an empty folder; a package saved anew copied with its new files; file→folder moved whole; folder→file; symlink→file; no longer a folder with Merge → left; still asks about a destination child that changed.
- [ ] Items added after review are named in a copy result (not `.DS_Store`).
- [ ] `.DS_Store` merge: the destination's kept without asking (`%s`); the pasted one copied when the destination has none.
- [ ] Picking: refuse the startup disk into its own folder; an item picked with its folder copied/moved once; a folder counts as one picked item.
- [ ] The destination folder vanishes mid-paste → not recreated, and reported as gone.
- [ ] Folders copied or moved whole: nothing copied if an incomplete package can't be cleared away; a move with failures moves nothing; a package with failures or a skipped item copies nothing; an ordinary folder placed with what it has; a hidden copy holding a deny-delete ACL is removed; a package moved whole when its replace target is gone; a skipped subfolder stays when moving the rest; an app inside a failed folder is left out, as is an app with an item skipped deep inside; a stop at the last item moves nothing; the record of an uncleanable hidden folder is kept; a stop part way leaves nothing hidden; the folder is journaled while built.
- [ ] A large file journaled while copied, released on failure.
- [ ] The item a Replace removes is the one that was there: one saved in its place during the copy is kept; no delete-for-good of a folder that gained an item, or one swapped in during the lock scan, or one placed while the no-Trash question was open.
- [ ] AppleDouble look-alikes on APFS are copied and moved as items; a `._` file added to a moved folder is kept and named; a `._` file the move skipped keeps its folder.
- [ ] A moved folder that stays keeps its `.DS_Store`.
- [ ] Replace inside a merged folder is checked; the old folder is kept when an inner item changed and was skipped; the hidden copy is removed when the Replace can't be journaled; a moved folder changed during the move is reported kept; nothing deleted from a folder holding a locked item on a disk without a Trash.
- [ ] A file is written under a hidden name and named only when complete; a locked file's lock is kept once named.
- [ ] Scenario matrix: prompt once when the Keep Both name gets created after planning; a folder that gained an item goes to the Trash with it; no re-ask for `.DS_Store` only.
- [ ] Staged discard whose removal stops part way: removed at the next start, not placed as whole (copy, and Replace undo); left whole if its record can't be changed.
- [ ] Read-only folders: copied and kept read-only; replacing with a read-only folder; a staged copy with read-only subfolders removed.
- [ ] Unreadable folders: everything else pastes, and the unreadable one alone fails.
- [ ] Locked: Replace with a locked file stays locked; Replace of a folder with a locked folder; refuse replacing a locked item before changes; a large copy stopped at once leaves nothing.

### G. Partial large files (`copyPastePartialFile`, `stoppableCopy`)
- [ ] Nothing left when stopped part way (`%s`); nothing left, with the reason, on `%s` errors.
- [ ] Name taken at completion → asked, and its own part cleared; can't take the name → fail and clear.
- [ ] A part that can't be cleared stays journaled; crash leftovers removed at the next start.
- [ ] A file that failed inside a hidden folder: the folder is placed without it; if its part can't be removed, the folder isn't placed.
- [ ] Stoppable copy: no flag when nothing can stop it; raises the flag and rejects; passes other errors through after a stop; reports bytes while running and stops reading after; doesn't start an already stopped copy.

### H. Fingerprints and errors (`copyPasteFingerprint.test`, `copyPasteErrors.test`, `undoLog.test`)
- [ ] Captures file and symlink fingerprints (unreadable link target → null); missing → a missing fingerprint; null ino/dev compatible; metadata changes detected; `pathExists`.
- [ ] `fileIdOf`: safe integers only.
- [ ] Identity sets: found through other spellings; case-insensitive comparison without ids; hard links; case-sensitive disks; each item read once.
- [ ] `describeCopyPasteError`: path-free text for known codes; ERR_FS_EISDIR; fallback to the error's message.
- [ ] Item ids, stamps (kind, entry count without Finder files, a renamed-items digest), and `stampWithoutId`.

### I. Write service coordination (`writeService.analysis`, `writeService.runtime`)
- [ ] Analysis job lifecycle and cancel; execution from an analysis id with conflicts resolved; unknown conflicts or ids rejected; a second analysis rejected; no finished analysis dropped on a refused start; analysis refused while a write runs; pruning, keeping the analyses asked for (not cancelled ones); cancelling an operation paused on a question; listener failures isolated.
- [ ] Standing answers only for the same kind; Keep Both not reused when the destination is gone; re-ask when the Replace target changed while the question was open or just before the swap; a new id for a repeated question; folders that took in an item (`%s`) are kept instead of deleted for good; an answer given during announcement accepted; an invalid answer refused while waiting continues; a runtime Keep Both name avoids later items; review choices kept inside a runtime merge.

### J. Recovery and journal (`copyPasteRecovery`, `copyPasteFolderSafety`, `copyPasteLocked`, `writeJournal.test`)
- [ ] Replace journaled before staging and cleared after the swap; a same-volume move journaled as moved before it leaves.
- [ ] Recovery: finish a move whose old item is in the Trash; deferred while another operation writes; runs inside `runWriteAlone`; put a moved item back when the old item was never removed; visible name when both places are taken; finish a complete copy; remove an unfinished copy (with or without the old item); nothing to do when finished; a failed entry reported while the rest continue; finish when the new item is locked; remove an unfinished locked copy; keep unreachable entries and drop gone ones.
- [ ] Entry kept untouched when the original's disk doesn't answer; a copy put in place when only the original's disk doesn't answer; an item without this app's hidden name left alone.
- [ ] Partial files: legacy hidden folder removed; nothing left once it's gone; deferred or unreachable; reason given; removed by hidden name; journaled before copying; not separately journaled inside a hidden folder.
- [ ] Journal: persists across reopen; replace by id; remove on disk; ENOSPC startup-disk message; generic message; opens empty on missing/bad JSON/non-list.
- [ ] `recoverWrites`: removes recovered entries and keeps others; hidden-item notice; timeouts deferred; retry finishes and reports; caches forgotten only if changed; waits for a busy slot; periodic retry until empty; never throws; partial-file cleanup, also locked; v0.4.3 legacy cases; batch-rename put-back, deferred when a folder doesn't answer; mixed entries read back; nothing to do.

### K. Coordinator (`writeOperations.test`, `.windows`, `.undoLog`, `.batchRename`)
- [ ] Rename with progress; create a folder only if the parent exists and the name is unused; Trash continues past failures; folder-size adjustments; Trash size forgotten after a Replace; delete-immediately partial; protected Trash refused; the busy lock held and released; cancel routed to the owner; a crashed window cancels its paste.
- [ ] Multi-window: broadcast; hand-off on close (and again); paste refused during rename prep; overrides and standing answers passed through; reload cancels the old paste but not the new; reload cancels a local write and frees the slot; slot freed when sending throws or the window is destroyed; immediate cancel if the window is already destroyed; listeners removed; trimmed analysis report; progress throttle (one per interval, newest arrives); conflict-answer rejection passed back; only the owner may answer.
- [ ] Real-disk rename: refuse a name taken after the check; case-only change on an insensitive disk; normalization-only change; refuse a different item differing only in case; refuse a hard link's name (also case-variant on a sensitive disk); case-only change on a sensitive disk; FAT32 empty file case change; plain-words errors; a finished rename never reported failed.
- [ ] Trash/delete: already gone = done; the Trash's refusal names the item; cancel stops; refuse the disk, system folders, a volume, the home folder; Trash protected in any case; another disk's Trash and per-user Trash; no delete through a link out of the Trash; refuse a disk mounted outside /Volumes; refuse moving home or system folders but allow copying; home subfolders protected; no renaming them; plain-words delete errors.
- [ ] Caches forgotten before the end is sent (local and paste).
- [ ] Quit: stop the delete and wait; count unreached Trash items; give up waiting; cancel a move and wait; copy named as a copy, nothing to wait for when idle.
- [ ] A paste that ended before start returned doesn't hold the slot; analyses are owner-only.
- [ ] Locked: rename names the lock; delete names a locked inner item.
- [ ] Empty Trash: refused while busy; holds the slot; seen by windows and quit; doesn't hold up quitting; windows notified after emptying or trying, not when refused.
- [ ] `runWriteAlone`: not while busy or during rename prep; holds the slot; frees it on failure; not when quitting.
- [ ] Questions: pre-1970 dates; an unsendable question auto-answered Skip.
- [ ] Trash rules: nothing pasted, moved or made in it; no re-trashing; delete only from a Trash or a just-failed no-Trash item; not another item put at the path meanwhile; id-less folders told apart by count; no delete through a link leaving the Trash.
- [ ] New Folder takes the next free name; a folder and an item inside it trashed as one.
- [ ] Windows: queued broadcast; copy-vs-move told at the end; others told only top-level items; hand-off includes clearsCutClipboard and unanswered questions only; getAdopted once, or with the end, or nothing; failure to tell one window doesn't stop others; active op reported; analysis cancelled when its window goes away (`%s`); a stuck analysis freed on close; listeners not kept; finished analyses of other windows kept; unexpected stops broadcast as failed; a paste ends even when diskHasTrash throws (marked can't undo); cache-forget errors don't block the end of a rename, paste or Undo; no-Trash delete permission is per window and cleared on reload; Undo prepare timeout refuses and ignores repeated presses.
- [ ] Undo log recording (see L).
- [ ] Batch rename on disk (see M).

### L. Undo (`undoPlan`, `undoExecution*`, `undoHistory`, `undo.fuzz`, `undo.realfs`, `copyPasteUndoLog.realfs`, `writeOperations.undoLog`)
- [ ] **Recording, copy:** each item made (not its inside); each file looked at once; a duplicate under its given name; nothing for skipped items; Replace = Trash location then new item; trashed paths reported; a partly failed folder recorded; only what came before a stop; merge → can't undo (also when it only replaced or added a link); a merge that found everything present leaves Undo unchanged; delete-for-good Replace → can't undo.
- [ ] **Recording, move:** from/to and parent; Replace = Trash then move; each moved item looked at twice and its folder once; a FIFO-like kind recorded; same-disk merge → can't undo (also when it only replaced, or removed an emptied folder); a merging move that found everything present leaves Undo unchanged; another disk → can't undo; no change when the item can't be read, stopped before writing, a Replace couldn't copy, or stopped just after making the folder; can't undo once a cross-disk Replace placed the new item.
- [ ] **Recording, simple operations:** rename with id and parent; nothing for a failed rename; new folder with stamp; no_trash new folder (also when unknown); batch with final names; one unit per trashed item with its Trash path; one look per item and per folder; nothing if nothing trashed; Delete Immediately can't undo; unchanged if nothing deleted, the item is gone, or a file couldn't be deleted at all; a partial folder delete → can't undo; Empty Trash can't undo even on partial or unknown failure; recorded before the next operation starts; slot freed even if history fails.
- [ ] **Paste log:** passed through with its action; no_trash for copies on Trash-less disks; diskHasTrash asked once per folder; non-undoable passed through; nothing for a paste that did nothing.
- [ ] **Plan:** reverse of each step kind; checkMove takes the very item or a safe-saved file but not a folder in its place; put-back only the very item; reconnected disk messages; kind only without ids; id-less put-back needs a matching stamp; disconnected disk; gone-from-Trash wording; a folder now a file refused; link-followed parent; a name freed or filled by earlier steps; an id-less item found gone by place in any case; checkTrash refuses a kind change without ids, and an unreadable item counts as changed; checkBatch swaps and refuses non-batch items; findQuestions covers every unit, looks past gone items, sets the replaced and putBack flags, stops at another item, asks when an earlier step fills a place, finds the old name free after the new item spelled otherwise moves away, asks about a made item without a stamp, asks about batch taken names (also held by a refused item), runs units concurrently in order; unreadable cases keep steps (Trash item, Trash folder listing, parent or target); a name taken by a case variant; kind changed means changed; a batch that can't be read is kept.
- [ ] **Round trips:** rename (also case-only); new folder; Trash put-back; batch with swaps and nested items; copies; moves; Replace (`%s`); no question for a new folder an item moved in and out of, or one with only `.DS_Store`; a chain of operations back to the start.
- [ ] **Outside changes:** a gone item skipped, reported and forgotten; name taken → ask, then number; a folder with a taken name numbered; a changed copy asks ("duplicate" wording); a folder with an added item trashed once agreed; never trash another item that took the copy's name; a safe-saved file still renamed back; no move into a gone or replaced folder; an item emptied from the Trash skipped; the replaced item put back even if the new one is gone; the replaced item left in the Trash while the new one can't move.
- [ ] **Running:** nothing at first; refused while the slot is busy; Can't Undo; a stale ticket refused; stop and resume; an unmovable item reported and left; never deletes a copy on a Trash-less disk.
- [ ] **Rarer:** a name taken in the instant → next number; all names taken → left; a copy the Trash refused is left; a batch numbers taken names; a batch whose items all moved does nothing; a batch stop resumes; a Replace's second step isn't redone if the first can't be (`%s`); later steps not trashed after an earlier failure.
- [ ] **Failures:** unreadable → kept until readable; a failed write stays on top; only failed items kept, the rest go to Redo; a Replace's steps after a failure kept; a batch item's failure kept; a swap back done in two tries; a waiting numbered item recorded both ways, including the paths of its contents; a Trash-less copy dropped with the reason; the Trash refusing without a reason on a Trash disk → kept; classification of each error code (`%s` for rename, Trash, batch); a stop at the last batch item stops nothing; a stop inside a Replace → the next Undo puts the old item back, and Redo brings the new one; another app's numbered leftover renamed back; Trash location unknown → can't undo (Trash and Replace), and Undo's trip counts as done with nothing to redo; unreadable whole batch or Trash step kept; very many items without stack overflow; progress counts; Redo after a partial Undo redoes only what was done; a batch item vanishing is skipped, not kept; an unexpected throw keeps the entry.
- [ ] **Links:** a folder opened through a link → rename back/redo, Trash put-back/redo, a cut item moved back out and in.
- [ ] **Locked:** a locked copy trashed locked and Redo restores it locked; trashed again on the next Undo; an item locked since put-back is not unlocked; a lock that can't be restored is reported (`%s`); a copy that can't be unlocked is kept; the Trash refusing → relock and report; a deny-delete ACL copy trashed with its rule; a read-only folder copy trashed read-only.
- [ ] **Names:** a Replace spelled differently (`%s`) puts the old item back without asking; a case-only rename back for an id-less FAT file; a hard link under the old name is another item; a folder rename with a skipped inner item; a batch case change doesn't see its own item as in the way; packages numbered before the extension (also when macOS can't say, and in batch undo).
- [ ] **Start:** refuse if an item changed while another question was open, or a name was taken; refuse and free the slot when a disk doesn't answer; an item changed after start is left for next time; same names in two folders told apart; per-window tickets; two windows → one starts, the other is refused.
- [ ] **History:** newest first; Undo↔Redo transfer; leftover on top, refused dropped; an all-failed operation forgotten; refuse finish for a non-top entry; a new operation clears Redo; no-change ops ignored; Can't Undo until the next undoable one; change counter and notifications; two-try batch entries kept separately; size cap 1M, per batch item; oldest evicted first, never the newest; an oversized single op kept; Undo results kept even over the cap; a Move label persists for a moving Replace's leftover; a plain label for a unit with nothing to go by.
- [ ] **Fuzz (real disk, seeded):** round trip to the start and Redo to the end; outside changes never lose or overwrite and always report; failed writes and stops; alternating Undo/Redo stays in step; failures imitating outside changes.
- [ ] **Real disks:** put back from a disk's own `.Trashes`; case-only rename back on case-insensitive APFS; Keep Both only for the exact name on a case-sensitive disk.

### M. Batch rename (`shared/batchRename.test`, `batchRenameExecution*`, `batchRenamePlanAndRun`, `batchRenameInspect`, `writeOperations.batchRename`)
- [ ] **Split:** last dot; no extension for a folder, dotfile, trailing dot, or no dot.
- [ ] **Replace:** accents found however written; every match, case-insensitive by default; no-match unchanged; plain text literal (dots, `$`, brackets); scope name/extension/both; regex groups; matchCase with regex; a broken pattern reported, nothing changed; replaced segments marked.
- [ ] **Replacement expansion:** groups, `$&`, `` $` ``, `$'`; unknown tokens literal; empty for unmatched or unknown groups; two-digit groups only when they exist.
- [ ] **Add:** before or after, for name or extension; spaces trimmed; empty text means no change; a folder's whole name.
- [ ] **Case:** lower, upper, title; already-in-case unchanged; title raises the first letter of each word only.
- [ ] **Format:** Finder numbering "File 1"; start/step/before; counter padding (fixed or auto); separators; keep names; dates in each format; date taken falls back to created and says so; custom patterns with literals and `[brackets]`; a pattern without tokens is an error; no date → unchanged; Apply To ignored.
- [ ] **Dates and numbers:** every format with every separator; descriptions; start and step; an invalid date reads as zeros; local clock.
- [ ] **Settings and presets:** sanitize defaults; numbers clamped; text truncated; presets deduped and capped.
- [ ] **Plan:** rename and unchanged counts; a name taken in the folder gets the next free number; in-batch repeats numbered in order with Format's separator; thousands wanting one name numbered efficiently; disk-style comparison (case and accents unless case-sensitive); swaps and case-only changes; Skip cascades along chains; a whole batch waiting on the next skipped at once; equals a fixed-point re-settle; Don't Rename holds; never an invalid name; cannotRename items skipped and keep their names; too long when numbered → shortened, or held if it can't be; warning for a leading dot; per-folder settling; an unknown folder holds only the items; broken settings hold nothing back and rename nothing.
- [ ] **Execution:** renames with progress and destinations; a swap via moving aside; a chain and a cycle; case-only via plain rename; a case-sensitive swap; a taken name numbered before the extension (at the end for a folder), skipped, or failed; a blocker restored to its old name or numbered or left hidden (reported); a blocker that couldn't move aside fails and the item wanting its name finds it taken; a waiting item put back on another failure; missing and locked items named; case-change failures reported; a case change without a listing or with an unreadable one; no folder read on a known-insensitive disk; the folder read when the disk is sensitive, unknown, or the accent encoding changes; a hidden name taken → fail without moving onto it; codeless errors; numbering gives up after 10k; a progress callback throwing is ignored.
- [ ] **Folders with items:** inner items first, with paths under the new folder name; a package's inner paths; the folder still renamed when an inner item fails; the folder left alone when stopped during inner items; swaps inside a renamed folder.
- [ ] **Stopping:** nothing before start; stop after the current item and put waiting items back; a stop at the last item is ignored; a level put back if stopped before all blockers moved aside, or when one couldn't move aside, or while moving aside.
- [ ] **Journal:** written before moves, once per level, released after; an item left hidden kept; its folder not renamed or moved aside; a level whose items can't be written down renames nothing.
- [ ] **Crash put-back:** old name, else new, else old numbered; unreachable kept.
- [ ] **Numbered names:** before the extension or at the end of a folder; shortened by graphemes; within the length limit at the last moment.
- [ ] **Fuzz:** never lose an item and always report its location (siblings, and nested folder renames); the location of an item whose folder was put back under a numbered name.
- [ ] **Plan ≡ run:** the same numbering with and without a Format separator; swaps and chains without numbers; multi-folder; case-only in place or numbered on a sensitive disk; accents typed differently count as taken; Skip; an item numbered back to its own name left alone; randomized agreement.
- [ ] **Inspect:** dates and folder names including hidden ones; date taken only when asked and well-formed; grouped by folder; cannot-rename reasons; bogus dates omitted; real disk dates and EXIF; locked items and unwritable folders.
- [ ] **On disk via coordinator:** reports; swaps and cycles keep contents; folder plus inner together; case and accent-only changes; quit mid-swap leaves nothing hidden; a name taken since the sheet checked handled per setting; locked items skipped with the reason; an unwritable folder fails; case-variant swap on a sensitive disk; a hard-link name numbered on a sensitive disk; swaps, chains and case on `${format}` disk images; prepare leaves out unchanged items, refuses duplicates and protected paths; reports the kind; an unexpected error fails every item; stop leaves the rest.

### N. Trash, disks, paths, effects (`trashItem`, `diskHasTrash`, `diskIds`, `Contracts/trash`, `paths`, `writeEffects`, `folderSizeAdjust`)
- [ ] `createTrashItem`: success; the Trash's own reason on the startup disk, never offering delete; locked; ENOTSUP → may-have-no-Trash; codeless on another disk → the Trash's reason; codeless on a no-Trash disk → marked; coded on a no-Trash disk → the Trash's reason; `%s` codes; a gone item.
- [ ] `diskHasTrash`: a network share has none (at its top and inside); others have one; prefix confusion avoided; mounts re-read every time; through links; case-insensitive; mounts outside /Volumes; nearest existing part; a fully unreadable path used as given; the startup disk listed; a link to a disk followed.
- [ ] `getDiskIds`: same disk same id; null when missing; another disk told apart, also through a link.
- [ ] `isInsideTrash` and `isTrashFolder`: home and other disks, case-insensitive, prefix look-alikes rejected, per-user Trash, contents deletable.
- [ ] `withoutNestedPaths`: drops descendants and repeats; "/" swallows everything.
- [ ] `pathsChangedByWrite`, `isAffectedByChange`, `createChangeMatcher`, `itemsForOtherWindows`: as titled in section 7 of the test list (outermost paths, Trash paths, trailing slashes, performance).
- [ ] `adjustForRemovals`: the folder-size cache (21 cases). Port only if the folder-size cache is ported.

---

## 8. Notes for the port

1. **Comparison keys differ by place.** Copy uses `destinationPathKey` (NFD, lowercased unless case-sensitive). Undo's `placeKey` always lowercases (NFD). Rename's self-check uses NFC + lowercase. Batch rename's plan uses `nameKey` (NFD, plus lowercase unless case-sensitive) and its execution `looseKey` (NFD + lowercase).
2. **`fileIdOf`.** JS loses precision above 2^53. In Swift, `UInt64` inodes are exact. FAT/exFAT empty files still share one bogus id near 2^64, so keep treating any inode ≥ 2^53 (or that specific sentinel) as unknown, to keep behavior identical.
3. **Questions are async.** Each one gets a fresh id, the answer future is registered before the question event is emitted, and answers are validated against the allowed list.
4. **Directory fingerprints.** Every "is the folder the same" check compares identity only (dev:ino/kind), never its mtime, because Finder writes `.DS_Store` just by showing a folder.
5. **`.DS_Store` and AppleDouble.** These are consistently ignored when counting, comparing, and treating a folder as empty. AppleDouble companions are filtered only on volumes that use AppleDouble **and** only when the file has the magic number.
6. **Stack depth.** The JS avoided spread over more than 125k items; Swift arrays are fine, but keep the item lists flat and lazy.
