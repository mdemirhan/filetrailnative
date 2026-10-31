// Port of apps/desktop/src/main/bootstrap/batchRenameExecution.test.ts
import FTFoundation
import Foundation
import Testing

@testable import FTOperations

private func request(
    _ pairs: [(String, String)], onConflict: BatchRenameOnConflict = .number, numberSeparator: String = " ",
    folders: [String] = []
) -> BatchRenameRequest {
    BatchRenameRequest(
        items: pairs.map { from, to in
            .init(sourcePath: "/trip/\(from)", destinationName: to, isFolder: folders.contains(from))
        },
        onConflict: onConflict, numberSeparator: numberSeparator)
}

/// Temporary names counted up, so tests can name them.
private func counter() -> () -> String {
    var next = 0
    return {
        defer { next += 1 }
        return ".tmp-\(next)"
    }
}

private func run(
    _ disk: MemoryDisk, _ renameRequest: BatchRenameRequest, signal: StopSignal = StopSignal(),
    onItemStart: BatchRenameExecution.ItemStart? = nil, journal: (any WriteJournal)? = nil
) -> BatchRenameRun {
    BatchRenameExecution.run(
        renameRequest, fileSystem: disk, signal: signal, onItemStart: onItemStart, temporaryName: counter(),
        journal: journal)
}

private func completed(_ from: String, _ to: String) -> WriteOperationItem {
    WriteOperationItem(sourcePath: from, destinationPath: to, status: .completed)
}

@Suite struct BatchRenameExecutionTests {
    // T-5a287b0b F-399 F-403 F-562
    @Test func renamesEachItemSaysAsEachStartsAndReportsWhereEachWent() {
        let disk = MemoryDisk(["/trip/a.jpg", "/trip/b.jpg"])
        var started: [(String, Int)] = []
        let result = run(
            disk, request([("a.jpg", "Lisbon 1.jpg"), ("b.jpg", "Lisbon 2.jpg")]),
            onItemStart: { source, _, done in started.append((source, done)) })
        #expect(disk.names() == ["Lisbon 1.jpg", "Lisbon 2.jpg"])
        #expect(started.map(\.0) == ["/trip/a.jpg", "/trip/b.jpg"])
        #expect(started.map(\.1) == [0, 1])
        #expect(
            result
                == BatchRenameRun(
                    items: [
                        completed("/trip/a.jpg", "/trip/Lisbon 1.jpg"), completed("/trip/b.jpg", "/trip/Lisbon 2.jpg"),
                    ], completedItemCount: 2, cancelled: false))
    }

    // T-e4b62d85 F-398 F-562
    @Test func swapsTwoNamesByMovingOneAsideFirst() throws {
        let disk = MemoryDisk(["/trip/a.txt", "/trip/b.txt"])
        let result = run(disk, request([("a.txt", "b.txt"), ("b.txt", "a.txt")]))
        #expect(result.completedItemCount == 2)
        #expect(disk.names() == ["a.txt", "b.txt"])
        // Both wanted each other's name: both waited under a temporary one.
        #expect(
            disk.calls.filter { $0.hasPrefix("renameExclusive") } == [
                "renameExclusive:/trip/a.txt->/trip/.tmp-0",
                "renameExclusive:/trip/b.txt->/trip/.tmp-1",
                "renameExclusive:/trip/.tmp-0->/trip/b.txt",
                "renameExclusive:/trip/.tmp-1->/trip/a.txt",
            ])
        // a's contents are now under b: the ino moved with the name.
        #expect(try disk.lstat("/trip/a.txt").ino == 11)
        #expect(try disk.lstat("/trip/b.txt").ino == 10)
    }

    // T-32934f6e F-398 F-562
    @Test func passesNamesAlongAChainAndAroundACycle() {
        let chain = MemoryDisk(["/trip/File 1", "/trip/File 2", "/trip/File 3"])
        _ = run(chain, request([("File 1", "File 2"), ("File 2", "File 3"), ("File 3", "File 4")]))
        #expect(chain.names() == ["File 2", "File 3", "File 4"])

        let cycle = MemoryDisk(["/trip/x", "/trip/y", "/trip/z"])
        let result = run(cycle, request([("x", "y"), ("y", "z"), ("z", "x")]))
        #expect(result.completedItemCount == 3)
        #expect(cycle.names() == ["x", "y", "z"])
        #expect(!cycle.names().contains { $0.hasPrefix(".tmp") })
    }

    // T-bd1f6314 F-399 F-562
    @Test func changesOnlyTheCaseOfANameWithAPlainRenameOnADiskThatIgnoresCase() {
        let disk = MemoryDisk(["/trip/notes.txt"])
        let result = run(disk, request([("notes.txt", "Notes.txt")]))
        #expect(result.items.first?.status == .completed)
        #expect(disk.names() == ["Notes.txt"])
        #expect(disk.calls.contains("rename:/trip/notes.txt->/trip/Notes.txt"))
    }

    // T-bc483a74 F-399 F-562
    @Test func tellsTwoItemsApartOnADiskThatMindsCaseAndSwapsThem() throws {
        let disk = MemoryDisk(["/trip/a", "/trip/A"], caseSensitive: true)
        let result = run(disk, request([("a", "A"), ("A", "a")]))
        #expect(result.completedItemCount == 2)
        #expect(disk.names() == ["A", "a"])
        #expect(try disk.lstat("/trip/A").ino == 10)
        // On a disk that minds case, "a" to "A" with another "A" there is a clash, not a case change.
        let clash = MemoryDisk(["/trip/a", "/trip/A"], caseSensitive: true)
        let numbered = run(clash, request([("a", "A")]))
        #expect(numbered.items.first?.destinationPath == "/trip/A 2")
    }

    // T-76dc4fba F-399 F-562
    @Test func aTakenNameGetsTheFirstFreeNumberBeforeTheExtensionOrAtTheEndOfAFoldersName() {
        let disk = MemoryDisk([
            "/trip/a.jpg", "/trip/Lisbon.jpg", "/trip/Lisbon 2.jpg", "/trip/folder", "/trip/Photos",
        ])
        let result = run(disk, request([("a.jpg", "Lisbon.jpg"), ("folder", "Photos")], folders: ["folder"]))
        #expect(result.items.map(\.destinationPath) == ["/trip/Lisbon 3.jpg", "/trip/Photos 2"])
        let dashed = MemoryDisk(["/trip/a.jpg", "/trip/Lisbon.jpg"])
        let withDash = run(dashed, request([("a.jpg", "Lisbon.jpg")], numberSeparator: "-"))
        #expect(withDash.items.first?.destinationPath == "/trip/Lisbon-2.jpg")
    }

    // T-6ba2cd08 F-399 F-562
    @Test func aTakenNameLeavesTheItemAsItIsWithSkip() {
        let disk = MemoryDisk(["/trip/a.jpg", "/trip/b.jpg", "/trip/Lisbon.jpg"])
        let result = run(disk, request([("a.jpg", "Lisbon.jpg"), ("b.jpg", "Lisbon 1.jpg")], onConflict: .skip))
        #expect(result.items.map(\.status) == [.skipped, .completed])
        // A skipped item is still where it was: no new path for the window to follow.
        #expect(result.items.first?.destinationPath == nil)
        #expect(result.items.first?.error == "An item named “Lisbon.jpg” already exists.")
        #expect(result.items.first?.skipReason == .runtimeConflictResolution)
        #expect(disk.names() == ["Lisbon 1.jpg", "Lisbon.jpg", "a.jpg"])
    }

    // T-c1870fe5 F-399 F-562
    @Test func aTakenNameFailsTheItemWithDontRename() {
        let disk = MemoryDisk(["/trip/a.jpg", "/trip/Lisbon.jpg"])
        let result = run(disk, request([("a.jpg", "Lisbon.jpg")], onConflict: .block))
        #expect(result.items.first?.status == .failed)
        #expect(result.items.first?.error == "An item named “Lisbon.jpg” already exists.")
        #expect(disk.names() == ["Lisbon.jpg", "a.jpg"])
    }

    // T-e3303b9c F-400 F-562
    @Test func putsAnItemMovedAsideBackUnderItsOldNameWhenItCantTakeItsNewOne() {
        // "b" moves aside for "c", finds "c" taken outside the batch, and goes back to "b".
        let disk = MemoryDisk(["/trip/a", "/trip/b", "/trip/c"])
        let result = run(disk, request([("b", "c"), ("a", "b")], onConflict: .skip))
        #expect(result.items.map(\.status) == [.skipped, .skipped])
        #expect(disk.names() == ["a", "b", "c"])
    }

    // T-746da8a7 F-400 F-562
    @Test func givesAnItemItsOldNameWithANumberWhenAnotherItemTookItMeanwhile() {
        // "b" moves aside for "a", which takes "b"; then "b" can't become "c" (taken), and its old name is "a"'s now.
        let disk = MemoryDisk(["/trip/a", "/trip/b", "/trip/c"])
        let result = run(disk, request([("a", "b"), ("b", "c")], onConflict: .skip))
        #expect(result.items.map(\.status) == [.completed, .failed])
        #expect(result.items[1].destinationPath == "/trip/b 2")
        #expect(
            result.items[1].error
                == "An item named “c” already exists. Another item has its old name now, so it is named “b 2”.")
        #expect(disk.names() == ["b", "b 2", "c"])
    }

    // T-7a01f4d1 F-400 F-562
    @Test func saysWhereAnItemIsWhenNotEvenANumberedOldNameCanBeGivenBack() {
        // Both move aside; "b" takes "a"; "a" can't take "b" (no permission), and can't go back under "a" ("b" has
        // it) or "a 2" (no permission either): it stays hidden, and says so.
        let disk = MemoryDisk(["/trip/a", "/trip/b"])
        disk.failures["renameExclusive:/trip/.tmp-1->/trip/b"] = errno("EACCES")
        disk.failures["renameExclusive:/trip/.tmp-1->/trip/a 2"] = errno("EACCES")
        let result = run(disk, request([("b", "a"), ("a", "b")]))
        #expect(result.items[0].status == .completed)
        #expect(result.items[1].status == .failed)
        #expect(result.items[1].destinationPath == "/trip/.tmp-1")
        #expect(
            result.items[1].error
                == "You don't have permission to access this item. Another item has its old name now, so it is named “.tmp-1” (hidden)."
        )
        #expect(disk.names() == [".tmp-1", "a"])
    }

    // T-6cf7b8eb F-400 F-562
    @Test func failsAnItemThatCouldntMoveAsideAndTheItemWantingItsNameFindsItTaken() {
        let disk = MemoryDisk(["/trip/a", "/trip/b"])
        disk.failures["renameExclusive:/trip/b->/trip/.tmp-0"] = errno("EACCES")
        let result = run(disk, request([("a", "b"), ("b", "c")]))
        #expect(result.items[1].status == .failed)
        #expect(result.items[1].error == "You don't have permission to access this item.")
        // "b" stayed, so "a" got the next free name.
        #expect(result.items[0] == completed("/trip/a", "/trip/b 2"))
        #expect(disk.names() == ["b", "b 2"])
    }

    // T-c258997a F-400 F-562
    @Test func putsAWaitingItemBackWhenItsRenameFailsForAnotherReason() {
        let disk = MemoryDisk(["/trip/a", "/trip/b"])
        disk.failures["renameExclusive:/trip/.tmp-0->/trip/c"] = errno("EIO")
        let result = run(disk, request([("b", "c"), ("a", "b")]))
        // "b" moved aside, failed to become "c", and is back as "b"; "a" then found "b" taken. Still where it was:
        // no new path.
        #expect(result.items[0].status == .failed)
        #expect(result.items[0].destinationPath == nil)
        #expect(result.items[1] == completed("/trip/a", "/trip/b 2"))
        #expect(disk.names() == ["b", "b 2"])
    }

    // T-a714c7dd F-403 F-562
    @Test func namesAMissingItemAndALockedOne() {
        let disk = MemoryDisk(["/trip/locked.txt"])
        disk.lockedPaths.insert("/trip/locked.txt")
        disk.failures["renameExclusive:/trip/locked.txt->/trip/new.txt"] = errno("EPERM")
        let result = run(disk, request([("gone.txt", "x.txt"), ("locked.txt", "new.txt")]))
        #expect(
            result.items.map(\.error) == [
                "“gone.txt” no longer exists.",
                "“locked.txt” is locked. Unlock it in Finder's Get Info and try again.",
            ])
        #expect(result.completedItemCount == 0)
    }

    // T-65a07296 F-399 F-562
    @Test func reportsAFailedChangeOfCaseAndChangesTheCaseOfANameNotThereYet() {
        let failing = MemoryDisk(["/trip/notes.txt"])
        failing.failures["rename:/trip/notes.txt->/trip/Notes.txt"] = errno("EIO")
        let result = run(failing, request([("notes.txt", "Notes.txt")]))
        #expect(result.items.first?.status == .failed)
        #expect(result.items.first?.destinationPath == nil)
        #expect(failing.names() == ["notes.txt"])
        // A disk that minds case finds no "A" for "a": an ordinary rename.
        let sensitive = MemoryDisk(["/trip/a"], caseSensitive: true)
        _ = run(sensitive, request([("a", "A")]))
        #expect(sensitive.names() == ["A"])
        #expect(sensitive.calls.contains("renameExclusive:/trip/a->/trip/A"))
    }

    // T-ff5b764d F-399 F-562
    @Test func decidesAChangeOfCaseWithoutAFolderListingOrWithOneThatCantBeRead() {
        let noListing = MemoryDisk(["/trip/notes.txt"])
        noListing.listing = .none
        _ = run(noListing, request([("notes.txt", "NOTES.txt")]))
        #expect(noListing.names() == ["NOTES.txt"])
        let unreadable = MemoryDisk(["/trip/notes.txt"])
        unreadable.listing = .failing(errno("EACCES"))
        _ = run(unreadable, request([("notes.txt", "Notes.txt")]))
        #expect(unreadable.names() == ["Notes.txt"])
    }

    // T-8862cf5d F-399 F-562
    @Test func changesTheCaseOfNamesWithoutReadingTheFolderOnADiskKnownToIgnoreCase() {
        let disk = MemoryDisk(["/trip/a.txt", "/trip/b.txt", "/home/c.txt"])
        disk.caseAnswer = .answer(false)
        let result = BatchRenameExecution.run(
            BatchRenameRequest(
                items: ["/trip/a.txt", "/trip/b.txt", "/home/c.txt"].map {
                    .init(sourcePath: $0, destinationName: NodePath.basename($0).uppercased(), isFolder: false)
                }), fileSystem: disk, signal: StopSignal())
        #expect(result.completedItemCount == 3)
        #expect(disk.names() == ["A.TXT", "B.TXT"])
        #expect(disk.names("/home") == ["C.TXT"])
        #expect(disk.readdirCalls.isEmpty)
        // Asked once for each folder.
        #expect(disk.caseCalls == ["/trip", "/home"])
    }

    // T-cc80b3a5 F-399 F-562
    @Test func readsTheFolderWhenTheDiskMindsCaseDoesntSayOrAnAccentsEncodingChanges() {
        for answer in [true, nil] as [Bool?] {
            let disk = MemoryDisk(["/trip/notes.txt"])
            disk.caseAnswer = .answer(answer)
            _ = run(disk, request([("notes.txt", "Notes.txt")]))
            #expect(disk.readdirCalls.contains("/trip"))
            #expect(disk.names() == ["Notes.txt"])
        }
        let failing = MemoryDisk(["/trip/notes.txt"])
        failing.caseAnswer = .failing(errno("EIO"))
        _ = run(failing, request([("notes.txt", "NOTES.txt")]))
        #expect(failing.readdirCalls.count == 1)
        #expect(failing.names() == ["NOTES.txt"])
        // "café" written with a separate accent: the same name to the disk, but not only its case.
        let accent = MemoryDisk(["/trip/caf\u{E9}"])
        accent.caseAnswer = .answer(false)
        let decomposed = "Cafe\u{301}"
        _ = run(accent, request([("caf\u{E9}", decomposed)]))
        #expect(accent.readdirCalls == ["/trip"])
        #expect(accent.names().map { Array($0.unicodeScalars) } == [Array(decomposed.unicodeScalars)])
    }

    // T-afcac389 F-398 F-562
    @Test func failsAnItemWhoseHiddenNameIsTakenWithoutMovingAnythingOntoIt() {
        let disk = MemoryDisk(["/trip/a", "/trip/b", "/trip/.tmp-0"])
        let result = run(disk, request([("a", "b"), ("b", "a")], onConflict: .skip))
        // "a" couldn't move aside, so it failed there; "b" did, found "a" still taken, and went back under its own
        // name.
        #expect(result.items.map(\.status) == [.failed, .skipped])
        #expect(result.items[0].error == "An item named “b” already exists.")
        #expect(result.items[1].destinationPath == nil)
        #expect(disk.names() == [".tmp-0", "a", "b"])
    }

    // T-a2470bf1 F-562
    @Test func describesAnErrorWithoutACodeAsAPlainFailure() {
        struct Strange: Error, CustomStringConvertible { var description: String { "strange" } }
        let disk = MemoryDisk(["/trip/a"])
        disk.failures["renameExclusive:/trip/a->/trip/b"] = Strange()
        let result = run(disk, request([("a", "b")]))
        #expect(result.items.first?.status == .failed)
        #expect(result.items.first?.error?.isEmpty == false)
    }

    // T-b56733f2 F-399 F-562
    @Test func givesUpNumberingAfterManyTries() {
        var files = ["/trip/a", "/trip/b"]
        for number in 2...10_001 {
            files.append("/trip/b \(number)")
        }
        let disk = MemoryDisk(files)
        let result = run(disk, request([("a", "b")]))
        #expect(result.items.first?.status == .failed)
    }

    // T-6a75658e F-562
    @Test func goesOnWhenSayingHowFarItGotFails() {
        struct WindowGone: Error {}
        let disk = MemoryDisk(["/trip/a", "/trip/b"])
        let result = run(disk, request([("a", "b"), ("b", "a")]), onItemStart: { _, _, _ in throw WindowGone() })
        #expect(result.completedItemCount == 2)
        #expect(disk.names() == ["a", "b"])
    }

    // MARK: A folder and items inside it

    // T-63880233 F-397 F-563
    @Test func renamesTheItemsInsideFirstAndSaysWhereTheyAreUnderTheFoldersNewName() {
        let disk = MemoryDisk(["/trip/sub", "/trip/sub/x.jpg", "/trip/sub/deeper/z.jpg"])
        var started: [String] = []
        let result = run(
            disk, request([("sub", "Day 1"), ("sub/x.jpg", "y.jpg"), ("sub/deeper/z.jpg", "w.jpg")], folders: ["sub"]),
            onItemStart: { source, _, _ in started.append(source) })
        #expect(started == ["/trip/sub/deeper/z.jpg", "/trip/sub/x.jpg", "/trip/sub"])
        #expect(disk.names() == ["Day 1"])
        #expect(disk.names("/trip/Day 1") == ["y.jpg"])
        #expect(disk.names("/trip/Day 1/deeper") == ["w.jpg"])
        // Results stay in the order asked for.
        #expect(result.items.map(\.sourcePath) == ["/trip/sub", "/trip/sub/x.jpg", "/trip/sub/deeper/z.jpg"])
        #expect(
            result.items.map(\.destinationPath) == ["/trip/Day 1", "/trip/Day 1/y.jpg", "/trip/Day 1/deeper/w.jpg"])
        #expect(result.completedItemCount == 3)
    }

    // T-8c696bd9 F-397 F-563
    @Test func saysWhereTheItemsInsideARenamedPackageAreThoughItIsntNumberedAsAFolder() {
        let disk = MemoryDisk(["/trip/Tool.app", "/trip/Tool.app/x.jpg", "/trip/y.jpg"])
        let result = run(disk, request([("Tool.app", "Kit.app"), ("Tool.app/x.jpg", "z.jpg"), ("y.jpg", "w.jpg")]))
        #expect(result.items.map(\.destinationPath) == ["/trip/Kit.app", "/trip/Kit.app/z.jpg", "/trip/w.jpg"])
        #expect(disk.names("/trip/Kit.app") == ["z.jpg"])
    }

    // T-5780085a F-397 F-563
    @Test func stillRenamesTheFolderWhenAnItemInsideItFailsAndSaysWhereThatItemIs() {
        let disk = MemoryDisk(["/trip/sub", "/trip/sub/x.jpg"])
        disk.failures["renameExclusive:/trip/sub/x.jpg->/trip/sub/y.jpg"] = errno("EACCES")
        let result = run(disk, request([("sub", "Day 1"), ("sub/x.jpg", "y.jpg")], folders: ["sub"]))
        #expect(result.items.map(\.status) == [.completed, .failed])
        // Not renamed, but in the folder's new name.
        #expect(result.items.map(\.destinationPath) == ["/trip/Day 1", "/trip/Day 1/x.jpg"])
        #expect(disk.names("/trip/Day 1") == ["x.jpg"])
    }

    // T-5ecda2e8 F-401 F-563
    @Test func leavesTheFolderAloneWhenStoppedWhileTheItemInsideIsRenamed() {
        let disk = MemoryDisk(["/trip/sub", "/trip/sub/x.jpg"])
        let signal = StopSignal()
        let result = run(
            disk, request([("sub", "Day 1"), ("sub/x.jpg", "y.jpg")], folders: ["sub"]), signal: signal,
            onItemStart: { _, _, _ in signal.stop() })
        #expect(result.cancelled)
        #expect(result.items.map(\.status) == [.cancelled, .completed])
        #expect(result.items.map(\.destinationPath) == [nil, "/trip/sub/y.jpg"])
        #expect(disk.names() == ["sub"])
    }

    // T-e0b91db8 F-397 F-563
    @Test func swapsNamesInsideAFolderThatIsRenamedToo() {
        let disk = MemoryDisk(["/trip/sub", "/trip/sub/a", "/trip/sub/b"])
        let result = run(disk, request([("sub", "Day 1"), ("sub/a", "b"), ("sub/b", "a")], folders: ["sub"]))
        #expect(result.completedItemCount == 3)
        #expect(disk.names("/trip/Day 1") == ["a", "b"])
        #expect(result.items.map(\.destinationPath) == ["/trip/Day 1", "/trip/Day 1/b", "/trip/Day 1/a"])
    }

    // MARK: Stopping

    // T-2ada096a F-401 F-564
    @Test func renamesNothingWhenStoppedBeforeItStarts() {
        let disk = MemoryDisk(["/trip/a", "/trip/b"])
        let signal = StopSignal()
        signal.stop()
        let result = run(disk, request([("a", "b"), ("b", "a")]), signal: signal)
        #expect(result.cancelled)
        #expect(result.items.map(\.status) == [.cancelled, .cancelled])
        #expect(disk.names() == ["a", "b"])
    }

    // T-81c1b0f1 F-401 F-564
    @Test func stopsAfterTheItemUnderWayAndPutsTheWaitingOnesBack() {
        let disk = MemoryDisk(["/trip/a", "/trip/b", "/trip/c"])
        let signal = StopSignal()
        let result = run(
            disk, request([("a", "b"), ("b", "x"), ("c", "y")]), signal: signal,
            onItemStart: { _, _, done in if done == 0 { signal.stop() } })
        // "b" was moved aside for "a"; the stop came as "a" started, so "a" still went, and "b", whose name "a" took,
        // finishes its swap. "c" never starts.
        #expect(result.items.map(\.status) == [.completed, .completed, .cancelled])
        #expect(disk.names() == ["b", "c", "x"])
        #expect(result.cancelled)
        #expect(result.completedItemCount == 2)
    }

    // T-9183ae51 F-401 F-564
    @Test func isntStoppedByAStopThatComesAsTheLastItemFinishes() {
        let disk = MemoryDisk(["/trip/a", "/trip/b"])
        let signal = StopSignal()
        disk.renameExclusiveOverride = { from, to, original in
            try original(from, to)
            if to == "/trip/y" { signal.stop() }
        }
        let result = run(disk, request([("a", "x"), ("b", "y")]), signal: signal)
        #expect(!result.cancelled)
        #expect(result.completedItemCount == 2)
        #expect(disk.names() == ["x", "y"])
    }

    // A deeper folder's item was renamed already; at this depth the stop comes after "a1" moved aside but before
    // "b1" did. "a1" can't finish its swap: "b1" still has the name.
    // T-12cd3ad4 F-401 F-564
    @Test func putsADepthBackAsItWasWhenStoppedBeforeAllItsItemsMovedAside() {
        let disk = MemoryDisk(["/trip/A/x", "/trip/a1", "/trip/b1"])
        let signal = StopSignal()
        disk.renameExclusiveOverride = { from, to, original in
            try original(from, to)
            if from == "/trip/a1" { signal.stop() }
        }
        let result = run(disk, request([("A/x", "y"), ("a1", "b1"), ("b1", "a1")]), signal: signal)
        #expect(disk.names("/trip/A") == ["y"])
        #expect(disk.names() == ["a1", "b1"])
        #expect(result.items.map(\.status) == [.completed, .cancelled, .cancelled])
    }

    // "b" couldn't be moved aside for "a": a stop after "z" was renamed doesn't let "a" finish into a name "b" still
    // has.
    // T-f9c6975e F-401 F-564
    @Test func putsADepthBackWhenOneOfItsItemsCouldntBeMovedAside() {
        let disk = MemoryDisk(["/trip/z", "/trip/a", "/trip/b"])
        let signal = StopSignal()
        disk.renameExclusiveOverride = { from, to, original in
            if from == "/trip/b" && to.hasPrefix("/trip/.tmp-") {
                throw errno("EACCES")
            }
            try original(from, to)
            if to == "/trip/zz" { signal.stop() }
        }
        let result = run(disk, request([("z", "zz"), ("a", "b"), ("b", "a")]), signal: signal)
        #expect(disk.names() == ["a", "b", "zz"])
        #expect(result.cancelled)
    }

    // T-2b39d19d F-401 F-564
    @Test func putsBackWhatWasMovedAsideWhenStoppedWhileMovingItemsAside() {
        let disk = MemoryDisk(["/trip/a", "/trip/b"])
        let signal = StopSignal()
        disk.renameExclusiveOverride = { from, to, original in
            try original(from, to)
            signal.stop()
        }
        let result = run(disk, request([("a", "b"), ("b", "a")]), signal: signal)
        #expect(result.cancelled)
        #expect(result.completedItemCount == 0)
        #expect(disk.names() == ["a", "b"])
    }
}

@Suite struct BatchRenameJournalTests {
    // T-80f7ca03 F-398 F-565
    @Test func writesThemDownBeforeAnyMovesOnceForEachFolderDepthAndLetsGoAfter() {
        let disk = MemoryDisk(["/trip/a", "/trip/b", "/trip/c"])
        let journal = RenameJournal()
        var namesWhenWritten: [[String]] = []
        journal.onAdd = { _ in namesWhenWritten.append(disk.names()) }
        _ = run(disk, request([("a", "b"), ("b", "a"), ("c", "d")]), journal: journal)
        // Written down before the first item moves aside.
        #expect(namesWhenWritten == [["a", "b", "c"]])
        #expect(journal.added.count == 1)
        #expect(journal.added.first?.id.count == 16)
        #expect(
            journal.added.first?.items == [
                .init(temporaryPath: "/trip/.tmp-0", originalPath: "/trip/a", newPath: "/trip/b"),
                .init(temporaryPath: "/trip/.tmp-1", originalPath: "/trip/b", newPath: "/trip/a"),
            ])
        #expect(journal.live.isEmpty)
        #expect(disk.names() == ["a", "b", "d"])
    }

    // An item that could go back nowhere stays under its hidden name: it stays written down.
    // T-a35dc807 F-402 F-565
    @Test func keepsWrittenDownAnItemLeftUnderItsHiddenName() {
        let disk = MemoryDisk(["/trip/a", "/trip/b"])
        disk.failures["renameExclusive:/trip/.tmp-0->/trip/b"] = errno("EACCES")
        disk.failures["renameExclusive:/trip/.tmp-0->/trip/a"] = errno("EACCES")
        let journal = RenameJournal()
        _ = run(disk, request([("a", "b"), ("b", "a")]), journal: journal)
        #expect(
            journal.liveEntries.map(\.items) == [
                [.init(temporaryPath: "/trip/.tmp-0", originalPath: "/trip/a", newPath: "/trip/b")]
            ])
    }

    // "a" is stuck under its hidden name in "P": "P" isn't renamed, so the next start finds it where it is written
    // down.
    // T-79459252 F-402 F-565
    @Test func doesntRenameTheFolderOfAnItemLeftHidden() {
        let disk = MemoryDisk(["/trip/P", "/trip/P/a", "/trip/P/b"])
        disk.failures["renameExclusive:/trip/P/.tmp-0->/trip/P/b"] = errno("EACCES")
        disk.failures["renameExclusive:/trip/P/.tmp-0->/trip/P/a"] = errno("EACCES")
        let journal = RenameJournal()
        let result = run(disk, request([("P/a", "b"), ("P/b", "a"), ("P", "Q")], folders: ["P"]), journal: journal)
        #expect(disk.names("/trip") == ["P"])
        #expect(result.items[2].error == "“P” wasn't renamed because an item in it is still under a hidden name.")
        #expect(
            journal.liveEntries.map(\.items) == [
                [.init(temporaryPath: "/trip/P/.tmp-0", originalPath: "/trip/P/a", newPath: "/trip/P/b")]
            ])
    }

    // "P" and "Q" swap names, but "P" holds an item still hidden: "P" is never moved aside, so it keeps its name and
    // the item stays where it is written down.
    // T-0ae41dcf F-402 F-565
    @Test func doesntMoveAsideAFolderHoldingAnItemLeftHiddenForASwap() {
        let disk = MemoryDisk(["/trip/P", "/trip/Q", "/trip/P/a", "/trip/P/b"])
        disk.failures["renameExclusive:/trip/P/.tmp-0->/trip/P/b"] = errno("EACCES")
        disk.failures["renameExclusive:/trip/P/.tmp-0->/trip/P/a"] = errno("EACCES")
        let journal = RenameJournal()
        _ = run(
            disk, request([("P/a", "b"), ("P/b", "a"), ("Q", "P"), ("P", "Q")], folders: ["P", "Q"]), journal: journal)
        #expect(disk.names("/trip").contains("P"))
        #expect(disk.names("/trip/P").contains(".tmp-0"))
        #expect(
            journal.liveEntries.flatMap(\.items) == [
                .init(temporaryPath: "/trip/P/.tmp-0", originalPath: "/trip/P/a", newPath: "/trip/P/b")
            ])
    }

    // T-ae81ce58 F-398 F-565
    @Test func renamesNothingOfADepthWhoseItemsCantBeWrittenDown() {
        let disk = MemoryDisk(["/trip/a", "/trip/b"])
        let journal = RenameJournal()
        journal.addFailure = errno("ENOSPC")
        let result = run(disk, request([("a", "b"), ("b", "a")]), journal: journal)
        #expect(disk.names() == ["a", "b"])
        #expect(result.items.map(\.status) == [.failed, .failed])
        #expect(result.items.first?.error?.hasPrefix("It wasn't renamed. ") == true)
    }
}

@Suite struct BatchRenameCrashPutBackTests {
    private func hidden(_ name: String) -> String {
        "/trip/.filetrail-rename-\(String(String(repeating: name, count: 12).prefix(12)))"
    }

    // T-c19e3c8e F-356 F-566
    @Test func putsEachItemUnderItsOldNameElseItsNewOneElseItsOldOneNumbered() {
        let disk = MemoryDisk([
            hidden("a"), hidden("b"), hidden("c"), "/trip/x.txt", "/trip/y.txt", "/trip/z.txt", "/trip/w.txt",
        ])
        disk.folderPaths = ["/trip"]
        let recovery = BatchRenameExecution.recover(
            BatchRenameJournalEntry(
                id: "1",
                items: [
                    // Free: back under its old name.
                    .init(temporaryPath: hidden("a"), originalPath: "/trip/p.txt", newPath: "/trip/x.txt"),
                    // Old name taken: its new one.
                    .init(temporaryPath: hidden("b"), originalPath: "/trip/x.txt", newPath: "/trip/q.txt"),
                    // Both taken: its old name numbered.
                    .init(temporaryPath: hidden("c"), originalPath: "/trip/y.txt", newPath: "/trip/z.txt"),
                    // Took its name before the crash.
                    .init(temporaryPath: hidden("d"), originalPath: "/trip/v.txt", newPath: "/trip/w.txt"),
                    // Not a name this app gives: left alone.
                    .init(temporaryPath: "/trip/x.txt", originalPath: "/trip/r.txt", newPath: "/trip/s.txt"),
                ]), disk)
        #expect(
            recovery
                == BatchRenameRecovery(
                    restored: [
                        .init(originalPath: "/trip/p.txt", path: "/trip/p.txt"),
                        .init(originalPath: "/trip/x.txt", path: "/trip/q.txt"),
                        .init(originalPath: "/trip/y.txt", path: "/trip/y 2.txt"),
                    ], remaining: []))
        #expect(disk.names() == ["p.txt", "q.txt", "w.txt", "x.txt", "y 2.txt", "y.txt", "z.txt"])
    }

    // T-30e67e05 F-356 F-566
    @Test func keepsWrittenDownWhatCantBeReachedOrMoved() {
        let disk = MemoryDisk([hidden("a")])
        disk.folderPaths = ["/trip"]
        disk.failures["renameExclusive:\(hidden("a"))->/trip/p.txt"] = errno("EACCES")
        let away = BatchRenameJournalEntry.Item(
            temporaryPath: "/gone/.filetrail-rename-bbbbbbbbbbbb", originalPath: "/gone/q", newPath: "/gone/r")
        let stuck = BatchRenameJournalEntry.Item(
            temporaryPath: hidden("a"), originalPath: "/trip/p.txt", newPath: "/trip/o.txt")
        let recovery = BatchRenameExecution.recover(BatchRenameJournalEntry(id: "1", items: [stuck, away]), disk)
        #expect(recovery == BatchRenameRecovery(restored: [], remaining: [stuck, away]))
    }
}

@Suite struct BatchRenameNumberedNameTests {
    private func numbered(_ name: String, _ isFolder: Bool, _ separator: String, _ number: Int) -> String {
        BatchRenameExecution.numberedName(name, isFolder: isFolder, separator: separator, number: number)
    }

    // T-03932ac1 F-567
    @Test func putsTheNumberBeforeTheExtensionAndAtTheEndOfAFoldersName() {
        #expect(numbered("Lisbon.jpg", false, " ", 2) == "Lisbon 2.jpg")
        #expect(numbered("archive.tar.gz", false, "_", 3) == "archive.tar_3.gz")
        #expect(numbered("photos.2026", true, " ", 2) == "photos.2026 2")
        #expect(numbered(".env", false, "-", 2) == ".env-2")
    }

    // T-72d6d60c F-567
    @Test func shortensANameTheNumberWouldMakeTooLongNeverCuttingALetterFromItsAccent() {
        let long = String(repeating: "a", count: 251) + ".jpg"
        #expect(numbered(long, false, " ", 2) == String(repeating: "a", count: 249) + " 2.jpg")
        // "é" written as "e" and an accent is three bytes; it goes whole or not at all.
        let accented = String(repeating: "a", count: 248) + "e\u{301}.jpg"
        #expect(
            Array(numbered(accented, false, " ", 2).unicodeScalars)
                == Array((String(repeating: "a", count: 248) + " 2.jpg").unicodeScalars))
        // Spaces left at the cut go too.
        #expect(
            numbered(String(repeating: "a", count: 246) + "  b.jpg", false, " ", 12)
                == String(repeating: "a", count: 246) + " 12.jpg")
    }

    // T-2bf174d3 F-399 F-567
    @Test func numbersANameTakenAtTheLastMomentWithinTheLengthANameCanHave() {
        let long = String(repeating: "a", count: 251) + ".jpg"
        let disk = MemoryDisk(["/trip/x.jpg"])
        // Taken after the sheet checked, so the main process numbers it.
        disk.add("/trip/\(long)")
        let result = run(disk, request([("x.jpg", long)]))
        #expect(
            result.items.first == completed("/trip/x.jpg", "/trip/" + String(repeating: "a", count: 249) + " 2.jpg"))
    }
}
