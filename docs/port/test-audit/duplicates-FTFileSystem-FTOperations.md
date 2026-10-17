# Near-duplicate test audit: FTFileSystemTests and FTOperationsTests

Read-only audit. No test was run, no file outside this report was changed. Nothing is proposed for removal that the original has as a test of its own: where the original has the tests separately the group is marked so, and it stays unless the user decides otherwise.

Paths below are relative to `Tests/FTFileSystemTests/` (FS) or `Tests/FTOperationsTests/` (OP). A `file:line` is the line of the `@Test` attribute. T- ids are the ones in the comment above the test; the original's file and describe come from `docs/port/parity/tests.tsv`. Cost figures in section 4 are judged from the fixtures, not measured.

## 1. Summary

| | FTFileSystemTests | FTOperationsTests |
|---|---|---|
| Files with tests | 47 | 63 |
| `@Test` declarations reviewed | 461 | 575 (28 parameterized with `arguments:`, each counted once) |
| Without a T- id (port additions) | 115 | 48 |
| Groups found | 12 (G26 to G37) | 25 (G1 to G25) |

- Groups found: 37. Of these, 20 are file-operation groups with a countable overlap (G1 to G20), 5 are informational, 12 are in FTFileSystem.
- Tests that could go without going below the original's coverage: 12. Eleven are safe (section 3); one (S4, `PartialFileTests.swift:159`) is the Swift-only second half of one original file-operation test, so it is listed for the user's decision and not proposed.
- Tests that could go only if the user decides to collapse groups the original keeps separately: 40 (39 in FTOperations, 1 in FTFileSystem). All but one are file operations, so none is proposed. Undo and recovery twins (G21, G22) are listed but not counted.
- Speed candidates: 46 tests in 8 clusters (section 4). 42 tests mount a disk image (47 mounts, 6 of them behind `FILETRAIL_LARGE_FILE_TESTS`); 15 of those need only a second device number, which `NativePaste.asOnAnotherDisk` already gives other tests.
- Not flagged on purpose: golden and differential suites (`ExecGoldenTests`, `FixtureGoldenTests`, `ListingSortGoldenTests`, `FolderSizeGoldenTests`, `FdSearchArgs` and `SearchResults` reference checks, the four `ScenarioMatrixTests` loops), `FolderSizeAdjustTests` (every case takes its own branch), and the mirror cases in `FolderSizeJobsTests`.
- Two ids look duplicated but are not: T-706c8576 is split between `CopyPasteExecutionEdgeTests` and `ExecutionReplaceTests` (the halves are different scenarios), and T-42fbbeb8 is split into two tests with different assertions.

Bookkeeping if anything is ever removed: `docs/port/parity/tests.tsv` lists the Swift tests per T- id in its `swiftTest` column, so that cell has to change with it.

## 2. Groups

"Original has them separately" is read from the T- ids: distinct ids mean distinct original tests (file and describe given). Where the original has one test and the port has several, the group says so.

### FTOperationsTests: file operations

All G1 to G20: original has them separately: keep unless the user decides otherwise.

**G1. Same-disk cut of one file: renamed, nothing copied (6 tests; go 4)**
- `Execution/CopyPasteExecutionRenameTests.swift:31` usesRenameForSameDevCutFile (T-a2db2911, same-filesystem rename)
- `Execution/CopyPasteExecutionRenameTests.swift:219` renamePreservesInode (T-49ec9582, same describe)
- `Execution/CopyPasteExecutionIntegrationTests.swift:14` renameAndInlineCutRenameMovesTheFile... (T-61d7f137, cross-phase integration)
- `Execution/CopyPasteExecutionIntegrationTests.swift:70` renameAndCopyFileRenamePrioritized... (T-73f268a2, same)
- `Execution/CopyPasteExecutionMetadataTests.swift:181` copyFileAndCutInlineSourceDeletionStillWorks (T-13e91ab9, native copyFile and utimes)
- `Execution/CopyPasteExecutionMetadataTests.swift:194` copyFileAndRenameRenameTakesPriority... (T-8258e572, same)
- Shared: mock disk, one file, `mode: .cut`, same device, then "source gone, target present, copy not used". The :181 test never installs a copy hook, so it is :31 without the copy flag. :14 and :31 have identical assertions.
- Keep: :31 and :219 (the inode, mode and date check is the only extra observation). Others could go.

**G2. Real-disk cut of one file inside one temp folder (5 tests; go 2)**
- `Execution/CopyPasteExecutionRealFSTests.swift:36` (T-a0287703), `:119` (T-c26523a5, inode), `:139` (T-cbbc9f49, mtime), `:194` (T-ceffaec5, inode and no copy); `WriteService/WriteServicePasteTests.swift:155` (T-37ddd66b, same cut through the service)
- Shared: same fixture and call, only the property checked differs. :194 asserts what :119 does plus a no-copy flag; :36 asserts content and "source gone", which :119 also asserts.
- Keep: :119, :139 and the service-level :155 (it exercises the service wiring). Could go: :36, :194.

**G3. Other-disk cut of one file: copy, then delete the original (5 tests; go 3)**
- `Execution/CopyPasteExecutionIntegrationTests.swift:30` (T-8fe86ace), `:50` (T-70fbe786); `Execution/CopyPasteExecutionRenameTests.swift:82` (T-cc2feb3b, device differs), `:134` (T-ff15a058, EXDEV), `:259` (T-61a311d1, EXDEV)
- Shared: :30, :134 and :259 are the same fixture (renames out of /source throw EXDEV) with the same two assertions; :50 and :82 are the same fixture (device 1 to device 2). :134 adds a copy flag; :259 is :134 without it.
- Keep: :134 and :82. Could go: :30, :259, :50.

**G4. Cut: source file changed after its copy (2 tests; go 1)**
- `Execution/CopyPasteExecutionCutTests.swift:106` preservesSourceFileWhenSourceMutatedAfterCopy (T-e684da1c), `:312` mutatedSourceFileReportsAsFailedNotCompleted (T-4391a680)
- Shared: identical fixture and copy hook (`size = 99` after the copy). :312 asserts a superset (source and target exist, plus status and error text); :106 adds only `size == 99`.
- Keep: :312 (add the size line to it). Original: both in "per-file cut flow".

**G5. Cut: a skipped child keeps the source folder (2 tests; go 1)**
- `Execution/CopyPasteExecutionCutTests.swift:157` (T-b5739b37), `:241` (T-41ba71f5)
- Shared: source folder with one new and one conflicting file, target holds the conflicting one; assert the new one moved, the conflicting one and the folder stay.
- Keep: :241.

**G6. Cut: source folder changed while its items were copied, so it is kept (2 tests; go 1)**
- `Execution/CopyPasteExecutionCutTests.swift:174` (T-4072637e), `Execution/CopyPasteExecutionEdgeTests.swift:155` (T-125afc8b)
- Shared: `/source` on device 2, copy hook sets the folder's mode to 0o700, assert the folder stays and the file is at the target. Only the names differ.
- Keep: :174.

**G7. Hidden files and folders, copy vs cut (2 tests; go 1)**
- `Execution/CopyPasteExecutionTests.swift:48` (T-e0613e7b), `Execution/CopyPasteExecutionEdgeTests.swift:114` (T-637bb845)
- Shared: same tree, same policy, same four existence checks. On the mock's single disk the cut renames the whole folder, so the hidden names never reach the copy code the cut test is named for.
- Keep: :48.

**G8. Cut removes the emptied source folder (3 tests; go 1)**
- `Execution/CopyPasteExecutionCutTests.swift:141` (T-2d3a3dc0), `Execution/CopyPasteExecutionEdgeTests.swift:134` (T-7f71a8fd), `:88` (T-eb95d949, first half)
- Shared: one folder with a file, cut, assert the folder is gone and the file arrived. :134 adds a no-op mtime bump; the second half of :88 (a file system without chmod) is unique and stays.
- Keep: :141 and :88. Could go: :134.

**G9. A date or mode that can't be set is ignored (4 tests; go 2)**
- `Execution/CopyPasteExecutionMetadataTests.swift:138` utimesENOTSUPSilentlyIgnored (T-b12350e8), `:150` utimesEOPNOTSUPPSilentlyIgnored (T-0cd81aa5), `:165` doesntFailAFolderWhoseDateCantBeSet (T-a81e8d81), `:128` utimesNotCalledWhenAbsent (T-408edc5c)
- Shared: copy a folder (or a link) with `utimesImpl` throwing. :138 and :150 assert only that the target exists; :165 asserts completed, no error and the children copied. If the code swallows every utimes error (:165 says so), :138 and :150 differ from it only by the error code and node kind. :128 has a different set-up (no utimes at all) but the same weak assertion.
- Keep: :165 and :128. Could go: :138, :150.

**G10. A large file is written down in the journal while it is copied (4 tests; go 2)**
- Entry written first: `Journal/LargeFileJournalTests.swift:34` (T-afcfd54a, mock) and `Execution/RuntimeSafetyWholeFolderTests.swift:358` (T-38c3693a, real disk, sparse file)
- Entry let go on failure: `Execution/PartialFileTests.swift:106` (T-9e7a471a, mock, copy and cut, ENOSPC and EIO) and `Execution/RuntimeSafetyWholeFolderTests.swift:383` (T-49a4c4c7, real disk)
- Shared: same property, mock against real disk. Original: `copyPasteRecovery.test.ts`, `copyPastePartialFile.test.ts` and `copyPasteRuntimeSafety.realfs.test.ts` hold them separately.
- Keep: the mock tests (more exact). Could go: :358, :383.

**G11. A locked file's copy stays locked (2 tests; go 1)**
- `Execution/NativePasteTests.swift:50` (T-91071836, `copyPasteNative.realfs.test.ts`), `Execution/RuntimeSafetyWholeFolderTests.swift:619` (T-a1c9680d, `copyPasteRuntimeSafety.realfs.test.ts`)
- Shared: lock a file, copy it on the real disk, assert `UF_IMMUTABLE` on the copy. Same assertion, nothing else.
- Keep: :50.

**G12. A package or app with an item skipped or failed is left out whole (3 tests; go 1)**
- `Execution/RuntimeSafetyWholeFolderTests.swift:173` (T-23bded0b), `:234` (T-92c1b1a5), `:214` (T-cb7aad68)
- Shared: :173 and :234 both change a file after the review and answer skip, then assert nothing of the package is at the destination; :234 only puts the app inside a folder. :214 reaches the same result by a copy error instead of a skip.
- Keep: :173 and :214. Could go: :234.

**G13. Replace over a folder holding another pasted item: review vs run (2 tests; go 1)**
- `Execution/RuntimeSafetyTests.swift:60` (T-4b7e1bb5), `:75` (T-a1bb1edb)
- Shared: byte-identical `runPaste` call on the same tree; one asserts the review's blocked reason, the other the result. They could be one test with both assertions.
- Keep: :75 with the blocked-reason line added.

**G14. "Replace blocked" reason text (5 tests; go 1)**
- `Execution/RuntimeSafetyWholeFolderTests.swift:551` (T-840f82e5), `Policy/BlockedReplaceReviewTests.swift:25` (T-a0bdac5b), `Execution/RuntimeSafetyWholeFolderTests.swift:564` (T-53ea433c), `Policy/BlockedReplaceReviewTests.swift:44` (T-6d3f7e31), `Execution/RuntimeSafetyTests.swift:60` (T-4b7e1bb5)
- Shared: assert `replaceBlockedReason`. :551 and :25 use the same two items (`/x/a.txt` and `/d/a.txt` into `/d`) and the same text; :25 also checks the resolved action. The other three are different cases (nested merged folder, firmlink spelling, folder holding the item).
- Keep: all but :551.

**G15. No Trash: ask, then skip keeps the old item or overwrite deletes it (6 tests; go 1)**
- `Replace/EdgeCasesTests.swift:292` (T-6b0956b8), `Replace/ConflictSafetyTests.swift:219` (T-b8ddfea8, parameterized skip and overwrite), `:411` (T-dd08d729, no answer), `:511` (T-a95de86e, folder, ino kept), `Replace/ExecutionReplaceTests.swift:258` (T-8cf7f825) and `:280` (T-03dcc5bc) (rename path)
- Shared: :292 and :219 give the same two answers through the same "no Trash" error and check the old item stayed or was replaced. The rest add a different move path or answer.
- Keep: :219. Could go: :292.

**G16. The four policy matrices vs the single-policy tests (4 matrix + 6 single; go 6)**
- Matrix (not flagged): `Replace/ScenarioMatrixTests.swift:108`, `:113`, `:118`, `:123` (T-a67327a8, T-8483d2b5, T-06fe2b2e, T-e1436157)
- Covered by the matrix with a full tree snapshot: `Replace/ExecutionReplaceTests.swift:31` (T-dc9ef314 overwrite file), `:80` (T-ac6200ce merge), `:98` (T-c924e277 replace folder, destination-only deleted), `:142` (T-aa23acf2 mismatch overwrite); `Execution/CopyPasteExecutionTests.swift:67` (T-1f1fa985 keep both, files), `:82` (T-dc4def7e keep both, folders)
- The matrix runs every file, directory and mismatch policy in copy and cut and compares the whole tree; each single test is one cell of it. All keep their own ids in the original (`copyPasteExecution.test.ts`).
- Keep: the matrix; the six are the ones to decide on.

**G17. destinationTotalNodeCount counts (5 tests; go 2)**
- `Analysis/CopyPasteAnalysisTests.swift:296` (T-001a2232 recursive), `:312` (T-ef2ab173 dotfiles), `:338` (T-28c543bb symlinks), `:411` (T-88d14058 deeply nested), `:426` (T-96ce005a mixed)
- Shared: one conflicting folder, `analyze`, assert one count. :411 is :296 deeper; :426 is :312 and :338 together (file, folder, link). Dotfiles and symlinks are real edges and stay.
- Keep: :296, :312, :338. Could go: :411, :426. Same describe in the original ("destinationTotalNodeCount").

**G18. WriteService analysis vs the analysis function (8 tests; go 4)**
- `WriteService/WriteServiceAnalysisTests.swift:289` (T-4503dd53) vs `Analysis/CopyPasteAnalysisTests.swift:66` (T-fe65bc63): same-folder copy gets `file copy 2.txt`
- `...WriteServiceAnalysisTests.swift:306` (T-62330910) vs `...CopyPasteAnalysisTests.swift:79` (T-88b2ff73): same-folder cut is `.samePath`
- `...WriteServiceAnalysisTests.swift:334` (T-26a0c664) vs `...CopyPasteAnalysisTests.swift:127` (T-7c7cd228): folder into its child is `.parentIntoChild`
- `...WriteServiceAnalysisTests.swift:319` (T-dbb2545f) vs `...CopyPasteAnalysisTests.swift:88` (T-aa3a458d): file conflict at the destination
- Shared: same inputs and expected values, one through the service's job, one through the function. `WriteServiceAnalysisTests.swift:74` (T-55f4c6a8) already checks the job wiring. Original: `writeService.test.ts` against `copyPasteAnalysis.test.ts`.
- Keep: the function-level ones. Could go: the four service-level ones.

**G19. WriteService real-disk copy shapes and .asar (4 tests; go 2)**
- `WriteService/WriteServicePasteTests.swift:251` (T-1dd3b541 nested tree), `:269` (T-8227d576 execute bit), `:305` (T-3e4b85d5 .asar), `WriteService/WriteServiceAnalysisTests.swift:351` (T-9c9fbb8d .asar analysis)
- Shared: copy a folder with a couple of files through the service and compare. The two .asar tests guard Electron's fs, which treats an archive as a folder (the test comment says so); the Swift file system has no such mode, so they are plain-file cases of :251. Siblings `:321`/`:336` (duplicate a file / a folder in the same folder, T-12a18238, T-e7e30fd5) differ only by item kind and are not counted.
- Keep: :251, :269. Could go: :305, `WriteServiceAnalysisTests.swift:351`.

**G20. A symlink is copied as a link (3 tests; go 2)**
- `Execution/CopyPasteExecutionTests.swift:98` (T-ff86e124), `WriteService/WriteServicePasteTests.swift:140` (T-4ca2bce9), `Execution/CopyPasteExecutionRealFSTests.swift:178` (T-2ba84c2f)
- Shared: copy a link, assert the copy is a link. :98 also checks the target text; :140 reads the link back on the real disk; :178 (named for its mtime) asserts only the type.
- Keep: :98 (and :140 as the real-disk one). Could go: :178.

**G21. Undo twins (10 tests; not counted; Undo keeps exactly the original's bar)**
- Merge cannot be undone, copy vs move: `Execution/UndoRecordingTests.swift:205` (T-cbb7658c) / `:326` (T-ffceccbe); with a replace: `Replace/UndoReplaceTests.swift:88` (T-a1ed3e3b) / `:153` (T-ca0ca81f)
- Merge finds everything already there: `Execution/UndoRecordingTests.swift:235` (T-dc09a208) / `:354` (T-1786aaec)
- Move to another disk cannot be undone: `Execution/UndoRecordingTests.swift:368` (T-b03f7dc5) / `Replace/UndoReplaceTests.swift:192` (T-4492a990)
- Item cannot be read / copy fails leaves Undo as it was: `Execution/UndoRecordingTests.swift:387` (T-8e3b55e9) / `Replace/UndoReplaceTests.swift:168` (T-17121de6)
- Each pair differs by one input (copy or move, replace or not). Original: `copyPasteUndoLog.realfs.test.ts` holds each separately. Left as they are.

**G22. Recovery of a large file's part: journal level vs function level (5 tests; not counted)**
- `Recovery/WriteRecoveryTests.swift:456` (T-b34cde9f) vs `Recovery/CopyPasteRecoveryTests.swift:103` (T-22bd6a05) and `:115` (T-8399d35f): the hidden folder a build after v0.4.3 used is removed, a record of a gone one clears
- `Recovery/WriteRecoveryTests.swift:345` (T-a6a8250b) vs `Recovery/CopyPasteRecoveryTests.swift:161` (T-1ca9e8c1): the part by its hidden name is removed
- The WriteRecovery tests read a journal file and run `recoverWrites`; the others call `recoverPartialFiles` directly. Original: `writeJournal.test.ts` against `copyPasteRecovery.test.ts`. Left as they are.

**G23. The item changed kind between the review and the paste (8 tests; not counted)**
- `Execution/RuntimeSafetyTests.swift:210`, `:227`, `:247`, `:264`, `:282` (T-e4a3d0a4, T-5ef4dac6, T-3de7ef98, T-aca6c73a, T-7ecd40ee); `Execution/CopyPasteMoveCleanupTests.swift:135`, `:161`, `:179` (T-81e70f11, T-191f0b93, T-b7549a25)
- Same shape (change the source after the review, answer overwrite, assert what is there now is pasted); each is a different kind transition, copy or move. Distinct edge cases: not counted.

**G24. One original test ported twice into two files (2 tests; one original test)**
- `Execution/PartialFileTests.swift:159` staysWrittenDownWhenAFailedCopyCantClearItAway and `Recovery/PartialFileRecoveryTests.swift:45` ...AndGoesAtTheNextStart, both T-93ae7a3b (`copyPastePartialFile.test.ts`, one test, parameterized copy and cut), both `arguments: [copy, cut]`
- The Recovery version builds the same file system, the same failing remove, the same failing copy, and asserts everything the Execution version does (failed status, no file at the name, source intact, one journal entry, a part left) and then runs the recovery. The Execution one is fully covered. This is the only group where the original has one test; it is listed as S4 in section 3 and is a file operation, so it is for the user to decide.

**G25. Errno names in the native wrappers (6 tests; not counted)**
- `Native/NativeCopyTests.swift:31` (T-6a49d862 ENOENT), `:49` (T-90a9d326 ENOTDIR), `:85` (T-eee4b3f2); `Native/NativeFlagsTests.swift:45` (T-9d501eab); `Native/NativeRenameTests.swift:129` (no id); `Native/NativeTrashTests.swift:59` (T-897ba460)
- Each calls a different wrapper and checks `code` (and `syscall`). The wrappers share one errno table, but each also sets its own syscall name, so none is a plain repeat. Not counted.

### FTFileSystemTests

**G26. Dangling symlinks (3 tests; go 1)**
- `Listing/ExplorerServiceTests.swift:497` returnsUnavailableMetadataForDanglingSymlinks... (T-3eb178ad), `:426` returnsUnavailableItemPropertiesForDanglingSymlinks (T-e76b1aa9), `:240` keepsDanglingSymlinksInSortedSnapshots... (T-a3b4b5e6)
- Shared: :497 and :426 use the same `stat` throws / `lstat` is a link fixture (size 7, same mtime) and expect the same values (kind label "Item", the same two dates, `.unavailable`, mode 0o644), through `metadata` and through `itemProperties`. :240 is a different call (sorted snapshots).
- Original: all three in `explorerService.test.ts`, separately. Keep: :497 (it also checks the batch goes on). Could go: :426.

**G27. Explorer mock tests vs real-folder twins (informational)**
- Mock `Listing/ExplorerServiceTests.swift:226` (T-6fad73c0), `:290`/`:306`/`:329` (T-2ca64a85, T-ac631da9, T-ec627d21), `:150`/`:187` (T-b81f5543, T-db410023), `:481`/`:411` (T-cb2d45b7, T-6d606cea) against real-folder `:553` (T-0bd98463), `:602` (T-d408f522), `:569` (T-0b96632f), `:588` (T-a8ad2b97)
- The real-folder tests are the original's `explorerService.fixtures.test.ts`; three of those ids and the suggestion ids are also listed on `FixtureGoldenTests` (`Listing/FixtureGoldenTests.swift:38`, `:99`), which is skipped where the fixture trees are not installed. Left as they are: the hand-written ones carry the ids when the goldens are skipped. Link-to-folder size (`:163` T-57e20151 and `:481`) shares one Alias/Folder fixture and the value 16; the calls differ (sorted snapshot, metadata), not counted.

**G28. Icon cache key vs icon store, same original test (2 + 2 tests)**
- T-308244dc: `Icons/IconCacheKeyTests.swift:23` filesWithoutAnExtensionShareOneIconOfTwoKinds and `Icons/FileIconStoreTests.swift:112` executablesWithoutAnExtensionShareAnIconAndSoDoTheOtherFiles. Original `fileIcons.test.tsx` has one test; the store test shows the same through observable fetches (six files, three icons). The key test is a safe removal (S10).
- T-41333069: `Icons/IconCacheKeyTests.swift:35` and `Icons/FileIconStoreTests.swift:187`. The key test also covers bundles and other items, which the store test does not. Both stay.

**G29. Icon store: ask once, reuse (3 tests; go 1)**
- `Icons/FileIconStoreTests.swift:82` asksForAnIconOnceAndReusesIt (T-046b5caf), `:98` overlappingRequestsForTheSameIconShareOneFetch (no id), `:203` anApplicationHasItsOwnIcon (no id)
- :203 is :82 with an app request (fetch twice, source asked once); the "app:" key it implies is asserted in `Icons/IconCacheKeyTests.swift:71`. :98 adds concurrency and stays. :203 is a safe removal (S8).

**G30. Thumbnail service: nothing for a gone file (3 tests; go 1)**
- `Icons/FileThumbnailServiceTests.swift:74` (T-22414abc T-be9407bf), `:81` (T-7d2e2494 T-be9407bf), `:141` theRealServiceReportsNothingForAGoneFile (T-be9407bf)
- `systemHandlers.apps.test.ts` has one test (T-be9407bf) for "no picture for a file Quick Look can't draw, or that is gone". :81 asserts the same triple (version nil, not unchanged, no picture) on a fake; :141 only runs it with the real service on a missing path; `:89` already asserts `fileVersion(missing) == nil` and `:130` the renderer on a missing file. :141 is a safe removal (S5).

**G31. Thumbnail load queue (2 tests; go 1)**
- `Icons/FileThumbnailServiceTests.swift:191` startsFourAtATimeAndStartsTheNextWhenOneEnds (no id) and `Icons/ThumbnailStoreTests.swift:202` (T-ab9b358d)
- :202 uses the same queue with six requests, asserts four start, the fifth starts when one ends and a cancelled one is dropped. :191 is the first half of that. Safe removal (S6). `:208` (cancelling a started job) is not part of it.

**G32. Application path and terminal tests (informational; 1 safe removal)**
- `System/ApplicationPathsTests.swift:10`, `:15`, `:21`, `:27` (T-3ebc19b8, T-7475884c, T-91c74364, T-647a4e22): four calls of `terminalApplicationName` with one input each; `:33`, `:39`, `:46`, `:52` (T-2155acfe, T-4b86c108, T-3c8a7e03, T-cdb1d0ce): four lists of `isValidBundlePath` inputs, one rule each
- `System/ApplicationPathsTests.swift:58` (T-155af596) and `System/SystemActionsTests.swift:271` refusesATerminalThatIsNotAnAppBundle (no id) both call `openInTerminal` with an invalid app path and assert not ok; `SystemActionsTests.swift:190` (T-cd79ef68, T-58a29428) loops four invalid paths through `openPaths`. :271 is a safe removal (S9). The eight above are separate original tests with one rule each: keep unless the user decides to parameterize them.

**G33. Search runtime: error and unknown-job tests (informational; 1 safe removal)**
- `Search/FdSearchRuntimeTests.swift:191` (T-68fe0d57), `:204` (T-b3e43aa8), `:234` (T-3af83ea8), `:246` (T-c942ad03), `:257` (no id): start a job, feed stderr, an error event, a signal or an exit code, assert the job's `error`. One source of error each: separate.
- `:185` aPollOfAnUnknownJobThrows (no id) asserts the `UnknownSearchJob` throw that `:265` (T-9db0e2f7, after close) and `:291` (after 64 jobs) already assert. Safe removal (S7). `:180` (cancel of an unknown job) stays.

**G34. Real-fd tests vs the mocked runtime (informational; none counted)**
- `Search/FdSearchProcessTests.swift:127` (bad regex), `:152` (stream of 50 files), `:188` (cancel ends fd), `:175` (T-1481cd4f, close ends fd); mock twins `FdSearchRuntimeTests.swift:204`, `:300`, `:164`/`:265`
- They run the real fd and so test its real messages and process handling; the mock twins test the runtime's wiring. Not duplicates. See section 4 for the cost of :175 and :188.

**G35. Eject: image-backed vs mock (informational; 1 safe removal)**
- `Volumes/VolumeEjectorTests.swift:147` aVolumeAlreadyEjectedCountsAsEjected (no id, mounts an APFS image) against `:131` (T-49c761e5, `EjectOutcome.ejectVolume` on a path with nothing mounted gives `.ejected`) and `Volumes/EjectOutcomeTests.swift:38` (T-a48b7c51). Only the first press through the default eject wiring is unique to :147. Safe removal (S12), low value.
- `Volumes/VolumeListingTests.swift:81` (registry finds the physical disk of a mounted image, no id) repeats the first lines of `Volumes/VolumeEjectorTests.swift:78` (T-cfcc0c26, which resolves `wholeDevice` through the same registry): two APFS mounts for one lookup. Not counted; see section 4.

**G36. Placeholders (3 tests)**
- `SmokeTests.swift:5` (FS) and OP `SmokeTests.swift:5`: empty `@Test` bodies. `AboutInfo/AboutInfoTests.swift:101` hasNoSeparateNotices: `#expect(true)`, five T- ids that `tests.tsv` already marks N/A. Safe removals (S1 to S3).

**G37. FolderWatchStream: stop after start vs stop before start (2 tests; speed only)**
- `Watch/FolderWatchStreamTests.swift:111` stopsWatchingWhenAsked and `:139` stoppedBeforeTheStreamIsStartedLeavesNoStream (neither has an id)
- Both stop, write a file, wait 800 ms and assert no change. They differ in when stop is called, so not duplicates; each costs about 1.1 s of fixed sleeping (section 4).

## 3. Safe removals

Removing these does not go below the original's coverage: they have no T- id and are covered by a named test, or they cite a T- id the original has once and another Swift test covers it in full, or they assert nothing. After any removal, update the `swiftTest` cell in `docs/port/parity/tests.tsv` for the ids named.

| # | Test | Why it is covered | Covered by |
|---|---|---|---|
| S1 | `SmokeTests.swift:5` ftFileSystemModuleLoads (FS) | empty body | any other test |
| S2 | `SmokeTests.swift:5` ftOperationsModuleLoads (OP) | empty body | any other test |
| S3 | `AboutInfo/AboutInfoTests.swift:101` hasNoSeparateNotices | `#expect(true)`; the five ids are N/A in `tests.tsv` (keep the N/A comment lines) | n/a |
| S5 | `Icons/FileThumbnailServiceTests.swift:141` theRealServiceReportsNothingForAGoneFile (T-be9407bf) | same triple as :81, and the missing-path version is asserted in :89 and :130 | `:81`, `:89`, `:130` |
| S6 | `Icons/FileThumbnailServiceTests.swift:191` startsFourAtATime... (no id) | first half of T-ab9b358d | `Icons/ThumbnailStoreTests.swift:202` |
| S7 | `Search/FdSearchRuntimeTests.swift:185` aPollOfAnUnknownJobThrows (no id) | both other tests assert the same thrown `UnknownSearchJob` | `:265`, `:291` |
| S8 | `Icons/FileIconStoreTests.swift:203` anApplicationHasItsOwnIcon (no id) | fetch twice, asked once, as :82; the app key is asserted elsewhere | `Icons/FileIconStoreTests.swift:82`, `Icons/IconCacheKeyTests.swift:71` |
| S9 | `System/SystemActionsTests.swift:271` refusesATerminalThatIsNotAnAppBundle (no id) | invalid app path through `openInTerminal`, as :58; the rule in :52 | `System/ApplicationPathsTests.swift:52`, `:58`, `:67` |
| S10 | `Icons/IconCacheKeyTests.swift:23` filesWithoutAnExtensionShareOneIconOfTwoKinds (T-308244dc) | the original has one test; the store test shows the same through fetches | `Icons/FileIconStoreTests.swift:112` |
| S11 | `Native/ReviewFolderMetadataTests.swift:9` aMoveWhoseFallbackThrowsStillSaysTheMetadataWasNotCopied (no id) | `onNotCopied` is called before the chmod that throws; the first case of the other test asserts that order | `Native/NativeCopyTests.swift:99` |
| S12 | `Volumes/VolumeEjectorTests.swift:147` aVolumeAlreadyEjectedCountsAsEjected (no id; one APFS mount) | the second press and the "gone" mapping are asserted on mocks and with nothing mounted; only the default-wiring first press is unique (low value) | `Volumes/VolumeEjectorTests.swift:131`, `Volumes/EjectOutcomeTests.swift:38` |

Not in the list, for the user to decide (a file operation the original has once):

| # | Test | Covered by |
|---|---|---|
| S4 | `Execution/PartialFileTests.swift:159` staysWrittenDownWhenAFailedCopyCantClearItAway (T-93ae7a3b, both copy and cut) | `Recovery/PartialFileRecoveryTests.swift:45`, which asserts the same and then the recovery (G24) |

## 4. Speed

### The 10 slowest-looking tests (judged from fixtures)

"Gated" means it runs only with `FILETRAIL_LARGE_FILE_TESTS=1` (`LargeFileTests.enabled`).

| # | Test | What makes it slow | Cheaper equivalent |
|---|---|---|---|
| 1 | `Execution/LockedPasteTests.swift:110` stopsALargeCopyAtOnce... (T-97d6fd58, gated) | 150 MB file written to the host disk, an APFS image mounted, up to three timed attempts with a 0.5 ms polling thread | The stop-part-way behavior is also asserted on a mock by `Execution/PartialFileTests.swift:89`; for the real disk, one attempt with a smaller file if the copy stays slow enough to stop |
| 2 | `Native/NativeCopyTests.swift:209` failsWithENOSPC... (T-26424164, gated) | 80 MB source plus `fillDisk` writing about 256 MB into the image (1 MB files, then 64 KB) | The disk is full before the copy, so the source can be 1 to 2 MB; use a 32 MB image kind for fill tests (the original used 20 MB; `tools/fixtures/disk-images.sh` makes 256 MB) |
| 3 | `Native/NativeCopyTests.swift:173` stopsPartWay... (T-19343d44, gated) | 150 MB file and an image | Needs a copy slow enough to stop: no safe shrink known |
| 4 | `Execution/PasteThroughputTests.swift:21` and `Copy/CopyThroughputTests.swift:15` (gated, no id) | each writes a 150 MB file and times several copies against a bare copyfile on an image | Both measure the same 5 % bound at two layers; share one file and one mount in one test |
| 5 | `Native/NativeCopyTests.swift:232` failsWithTheWritesErrno...ResourceFork (T-0c2e0a1d, not gated) | APFS image, `fillDisk` to full (about 256 MB), then a fork larger than the free space | 32 MB image kind (the comment in the test describes the original's 20 MB disk) |
| 6 | `Native/NativeCopyTests.swift:259` ...SmallResourceFork (T-1c84056e, not gated) | FAT32 image, `fillDisk` again | Smallest FAT32 image that mounts, or share the full FAT image with the next test that needs one |
| 7 | `Execution/LargeTreeExecutionTests.swift:135` analyzesAndCopiesEveryItem (T-aa0802fe) | 150,000 mock items analyzed, resolved and pasted | The review half repeats `Analysis/LargeTreeAnalysisTests.swift:91`; build the 150,000-item tree once and reuse it (the 125,000 bound belongs to the original's JavaScript argument limit) |
| 8 | `Analysis/LargeTreeAnalysisTests.swift:91` reviewsAFolderOfMoreThan125000Items... (no id) | the same 150,000-item tree, with a wait of up to 120 s | as above |
| 9 | `FolderSize/FolderSizeJobsTests.swift:568` keepsUpWithAWalk... (T-2cdd29eb) | 200,000 sizes in 20 takes, bound of 6 s; the neighbors `:293` (110,000), `:263` (30,000 plus 3,000 changes) and `FolderSize/FolderSizeCacheTests.swift:122` (400,000 stores, bound 5 s) do the same kind of loop | Only `:293` needs more than 100,000 (the old limit); the three others test complexity and can use a fifth of the size with a proportional bound |
| 10 | `Watch/FolderWatchStreamTests.swift` (7 tests, fixed sleeps) | 300 ms start wait in six tests, then negative waits of 1,200, 800 and 800 ms, with real FSEvents; about 5 s of fixed sleeping together | FSEvents latency is 0.05 s (`FSEventsFolderWatcher.latencySeconds`); the negative waits can be about 250 ms, and `:111` and `:139` can share one folder |

### Other clusters (46 tests in all, counting the above)

- **Disk images (42 tests, 47 mounts, 6 mounts gated).** Every test clones a 256 MB image, attaches, detaches, and waits on a lock that allows one volume of a kind at a time, so the 26 APFS mounts of OP (20 of them not gated) run one after another. 15 of them need only a second device number and could use `NativePaste.asOnAnotherDisk(source)` (already used in `Execution/CopyPasteExecutionRealFSTests.swift:64`, `Execution/RuntimeSafetyTests.swift:31` and four more places): `Execution/LockedPasteTests.swift:40`, `:63`, `:87`; `Replace/LockedReplaceTests.swift:89`, `:115`; `Execution/UndoRecordingTests.swift:368`, `:387`, `:407`, `:433`; `Replace/UndoReplaceTests.swift:168`, `:192`; `Execution/CopyPasteVolumesTests.swift:19`, `:36`, `:54`, `:80`. (Whether each behaves the same with a fake device needs a check; `UndoReplaceTests.swift:192` uses the volume's own Trash.) The rest need a real volume: case-sensitive APFS (`CopyPasteVolumesTests.swift:100`, `:121`, `NativeRenameTests.swift:96`), FAT and exFAT, trash on a volume, and the VolumeEjector and registry tests. A shared APFS volume per suite, with a folder per test, would remove most of the remaining attach and detach cycles.
- **FAT and exFAT run twice (5 tests).** `Native/NativeRenameTests.swift:62`, `:135`, `Execution/CopyPasteVolumesTests.swift:169`, `:183`, `Replace/WriteServiceReplaceTests.swift:265` use `arguments: [.fat32, .exfat]`, so each mounts two images; one kind per test would save 5 mounts, or both kinds could share one mount per suite.
- **Fill-disk tests (4):** `NativeCopyTests.swift:209`, `:232`, `:259` and `Execution/CopyPasteVolumesTests.swift:141` (T-0e57438e, gated, 8 MB source plus `fillDisk`). One 32 MB image kind for all four.
- **Real-folder size.** `Listing/NativeFileSystemTests.swift:55` readsAFolderTooBigForOneBuffer creates 6,000 files so the listing overruns its 256 KB bulk buffer; a smaller buffer passed in by the test would need far fewer. `FolderSize/NativeFolderSizeTests.swift:230` walks `/usr/share` and `:238` walks `/System/Volumes` (real system trees; no smaller parent contains a firmlink).
- **Real fd on `/`.** `Search/FdSearchProcessTests.swift:175` and `:188` search the whole disk for a name that never matches and poll `ps` until fd shows (up to 5 s) and ends (up to 2 s). A large folder such as `/usr` would keep fd alive long enough.
- **Benches, off by default** (`FILETRAIL_BENCH`): `Listing/ListingBenchTests.swift:52` (100,000 items, 7 to 15 runs), `FolderSize/FolderSizeBenchTests.swift:20` (200,000 files, 12 runs), `Search/SearchBenchTests.swift:28`. Report only.
