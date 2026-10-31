// Port of apps/desktop/src/main/bootstrap/undoPlan.test.ts
import FTFoundation
import Foundation
import Testing
import os

@testable import FTOperations

/// `disk`: a disk of paths, each with a kind and an id (ino on dev 1; nil for none, as on FAT). A link leads to the
/// path it names. Listing a folder gives its items' whole paths, as the original's stand-in does.
final class PlanDisk: IdentityFileSystem, @unchecked Sendable {
    enum Item {
        case file(ino: UInt64?, size: Int64 = 0)
        case dir(ino: UInt64?)
        case link(to: String)
    }

    let items: [String: Item]
    /// `troubled`: each look is answered by `fails` first, which names the error it throws, if any. Counted per kind
    /// of look and path, from 1.
    var fails: ((_ look: String, _ path: String, _ count: Int) -> String?)?
    /// Each lstat, before it answers (the test may hold it).
    var onLstat: ((String) -> Void)?
    private let counts = OSAllocatedUnfairLock(initialState: [String: Int]())

    init(_ items: [String: Item]) {
        self.items = items
    }

    private func check(_ look: String, _ path: String) throws {
        guard let fails else { return }
        let count = counts.withLock { counts -> Int in
            counts["\(look) \(path)", default: 0] += 1
            return counts["\(look) \(path)"] ?? 0
        }
        if let code = fails(look, path, count) {
            throw OperationError(code, code: code)
        }
    }

    private func stats(_ path: String) throws -> WriteServiceStats {
        switch items[path] {
        case nil:
            throw OperationError("ENOENT", code: "ENOENT")
        case .link:
            return WriteServiceStats(type: .symlink, ino: 999, dev: 1)
        case .file(let ino, let size):
            return WriteServiceStats(type: .file, size: size, mtimeMs: 1000, ino: ino, dev: 1)
        case .dir(let ino):
            return WriteServiceStats(type: .directory, mtimeMs: 1000, ino: ino, dev: 1)
        }
    }

    func lstat(_ path: String) throws -> WriteServiceStats {
        try check("lstat", path)
        onLstat?(path)
        return try stats(path)
    }

    func stat(_ path: String) throws -> WriteServiceStats {
        try check("stat", path)
        if case .link(let to) = items[path] {
            return try stats(to)
        }
        return try stats(path)
    }

    func readdir(_ path: String) throws -> [String] {
        try check("readdir", path)
        let prefix = path + "/"
        return items.keys.filter { $0.hasPrefix(prefix) && !$0.dropFirst(prefix.count).contains("/") }.sorted()
    }

    func realpath(_ path: String) throws -> String { path }
    func readlink(_ path: String) throws -> String { throw OperationError("EINVAL", code: "EINVAL") }
}

struct UndoPlanTests {
    static func id(_ ino: UInt64) -> ItemId { ItemId(dev: 1, ino: ino) }
    private func id(_ ino: UInt64) -> ItemId { Self.id(ino) }

    private let docs: [String: PlanDisk.Item] = ["/Docs": .dir(ino: 1)]

    private func disk(_ parts: [String: PlanDisk.Item]...) -> PlanDisk {
        PlanDisk(parts.reduce(into: [:]) { $0.merge($1) { _, new in new } })
    }

    private func moveBack(
        from: String = "/Docs/b.txt", to: String = "/Docs/a.txt", id: ItemId? = UndoPlanTests.id(10),
        itemKind: ItemKind? = .file, parentId: ItemId? = UndoPlanTests.id(1), putBack: Bool = false,
        stamp: ItemStamp? = nil
    ) -> PlannedMove {
        PlannedMove(
            from: from, to: to, id: id, itemKind: itemKind, parentId: parentId, putBack: putBack, stamp: stamp)
    }

    private func fileStamp(size: Int64? = 0) -> ItemStamp {
        ItemStamp(kind: .file, size: size, mtimeMs: 1000, entryCount: nil)
    }

    private func isOK(_ check: MoveCheck) -> Bool {
        if case .ok = check { return true }
        return false
    }

    private func nameTaken(_ check: MoveCheck) -> Bool? {
        if case .ok(let nameTaken, _, _, _, _) = check { return nameTaken }
        return nil
    }

    private func refusal(_ check: MoveCheck) -> Refusal? {
        if case .refused(let refusal) = check { return refusal }
        return nil
    }

    // T-cd8b61bf F-378 F-549
    @Test func reversesEachKindOfStep() {
        let moved = UndoStep.Moved(from: "/a", to: "/b", id: id(5), itemKind: .file, parentId: id(1))
        #expect(
            PlannedStep(reversing: .moved(moved))
                == .move(
                    PlannedMove(
                        from: "/b", to: "/a", id: id(5), itemKind: .file, parentId: id(1), putBack: false)))
        var fromTrash = moved
        fromTrash.fromTrash = true
        #expect(
            PlannedStep(reversing: .moved(fromTrash))
                == .trash(PlannedTrash(path: "/b", id: id(5), stamp: nil, putBack: true, unlock: false)))
        fromTrash.locked = true
        #expect(
            PlannedStep(reversing: .moved(fromTrash))
                == .trash(PlannedTrash(path: "/b", id: id(5), stamp: nil, putBack: true, unlock: true)))
        #expect(
            PlannedStep(reversing: .trashed(from: "/a", trashPath: "/T/a", id: id(5), parentId: id(1), stamp: nil))
                == .move(
                    PlannedMove(from: "/T/a", to: "/a", id: id(5), itemKind: nil, parentId: id(1), putBack: true)))
        #expect(
            PlannedStep(
                reversing: .batchRenamed(items: [BatchRenamedItem(from: "/a", to: "/b", id: id(5), itemKind: .file)]))
                == .batch(items: [BatchRenamedItem(from: "/b", to: "/a", id: id(5), itemKind: .file)]))
        #expect(
            PlannedStep(reversing: .created(path: "/c", id: id(5), stamp: nil))
                == .trash(PlannedTrash(path: "/c", id: id(5), stamp: nil, putBack: false, unlock: true)))
    }

    // T-1d13eb1d F-380 F-549
    @Test func takesTheVeryItemOrAFileSavedUnderANewIdButNotAFolderInItsPlace() {
        #expect(nameTaken(UndoPlan.checkMove(disk(docs, ["/Docs/b.txt": .file(ino: 10)]), moveBack())) == false)
        #expect(isOK(UndoPlan.checkMove(disk(docs, ["/Docs/b.txt": .file(ino: 99)]), moveBack())))
        #expect(
            UndoPlan.checkMove(disk(docs, ["/Docs/b.txt": .dir(ino: 99)]), moveBack())
                == .refused(Refusal(reason: "The “b.txt” in “Docs” is another item now.", missing: false)))
    }

    // T-5380c332 F-380 F-549
    @Test func putsBackFromTheTrashOnlyTheVeryItem() {
        let step = moveBack(from: "/T/b.txt", itemKind: nil, putBack: true)
        let trash: [String: PlanDisk.Item] = ["/T": .dir(ino: 2)]
        #expect(refusal(UndoPlan.checkMove(disk(docs, trash, ["/T/b.txt": .file(ino: 99)]), step))?.missing == false)
        #expect(isOK(UndoPlan.checkMove(disk(docs, trash, ["/T/b.txt": .file(ino: 10)]), step)))
    }

    // T-10550edd F-381 F-549
    @Test func saysTheDiskWasDisconnectedWhenTheSameIdsComeBackOnAnotherDevice() {
        // Recorded on device 2; the disk was ejected and is device 1 now.
        func ejected(_ ino: UInt64) -> ItemId { ItemId(dev: 2, ino: ino) }
        let files = disk(docs, ["/Docs/b.txt": .file(ino: 10)])
        #expect(
            UndoPlan.checkMove(files, moveBack(id: ejected(10), parentId: ejected(1)))
                == .refused(
                    Refusal(
                        reason: "Its folder “Docs” is on a disk that was disconnected since, so it is left as it is.",
                        missing: false)))
        let trash: [String: PlanDisk.Item] = ["/T": .dir(ino: 2)]
        #expect(
            UndoPlan.checkMove(
                disk(docs, trash, ["/T/b.txt": .file(ino: 10)]),
                moveBack(from: "/T/b.txt", id: ejected(10), parentId: ejected(1), putBack: true))
                == .refused(
                    Refusal(
                        reason: "“a.txt” is on a disk that was disconnected since, so it is left as it is.",
                        missing: false)))
        // Another item on another disk is just another item.
        #expect(
            refusal(
                UndoPlan.checkMove(
                    disk(docs, trash, ["/T/b.txt": .file(ino: 11)]),
                    moveBack(from: "/T/b.txt", id: ejected(10), putBack: true)))?.reason
                == "The “a.txt” in the Trash is another item now.")
    }

    // T-182b55dd F-380 F-549
    @Test func goesByTheKindAloneOnADiskWithoutUsableIds() {
        let fat = disk(docs, ["/Docs/b.txt": .file(ino: nil)])
        #expect(isOK(UndoPlan.checkMove(fat, moveBack())))
        #expect(!isOK(UndoPlan.checkMove(fat, moveBack(itemKind: .directory))))
        #expect(isOK(UndoPlan.checkMove(fat, moveBack(itemKind: nil, putBack: true))))
    }

    // T-271a4e3f F-380 F-549
    @Test func putsBackFromTheTrashAnItemWithoutAnIdOnlyWhenItLooksAsItDid() {
        guard
            case .move(let step) = PlannedStep(
                reversing: .trashed(
                    from: "/Docs/a.txt", trashPath: "/T/a.txt", id: nil, parentId: nil, stamp: fileStamp(size: 5)))
        else {
            Issue.record("A trashed step is undone by a move.")
            return
        }
        let trash: [String: PlanDisk.Item] = ["/T": .dir(ino: nil)]
        #expect(
            refusal(UndoPlan.checkMove(disk(docs, trash, ["/T/a.txt": .file(ino: nil)]), step))?.reason
                == "The “a.txt” in the Trash is another item now.")
        #expect(isOK(UndoPlan.checkMove(disk(docs, trash, ["/T/a.txt": .file(ino: nil, size: 5)]), step)))
        #expect(!isOK(UndoPlan.checkMove(disk(docs, trash, ["/T/a.txt": .dir(ino: nil)]), step)))
    }

    // T-cd2676fe F-381 F-549
    @Test func saysSoWhenTheItemsDiskIsntConnected() {
        #expect(
            UndoPlan.checkMove(disk(), moveBack(from: "/Volumes/Backup/b.txt"))
                == .refused(Refusal(reason: "“b.txt” is on “Backup”, which isn't connected.", missing: true)))
    }

    // T-89cb3677 F-381 F-549
    @Test func namesAnItemGoneFromTheTrashAsItWasBeforeAndTellsADisconnectedDiskApart() {
        // Put back from a disk's own Trash folder (".Trashes/501"), under the name it had there.
        let step = moveBack(from: "/Volumes/Stick/.Trashes/501/1-a.txt", to: "/Volumes/Stick/a.txt", putBack: true)
        let stick: [String: PlanDisk.Item] = [
            "/Volumes/Stick": .dir(ino: 1), "/Volumes/Stick/.Trashes/501": .dir(ino: 2),
        ]
        #expect(
            UndoPlan.checkMove(disk(stick), step)
                == .refused(Refusal(reason: "“a.txt” isn't in the Trash any more.", missing: true)))
        #expect(
            UndoPlan.checkMove(disk(), step)
                == .refused(Refusal(reason: "“a.txt” is on “Stick”, which isn't connected.", missing: true)))
        #expect(
            UndoPlan.checkMove(disk(stick, ["/Volumes/Stick/.Trashes/501/1-a.txt": .file(ino: 99)]), step)
                == .refused(Refusal(reason: "The “a.txt” in the Trash is another item now.", missing: false)))
    }

    // T-49e9777a F-381 F-549
    @Test func refusesAFolderThatIsNowAFileAndGoesByTheFoldersNameWithoutItsId() {
        let item: [String: PlanDisk.Item] = ["/Docs/b.txt": .file(ino: 10)]
        #expect(
            refusal(UndoPlan.checkMove(disk(["/Docs": .file(ino: 1)], item), moveBack()))?.reason
                == "Its folder “Docs” no longer exists.")
        #expect(isOK(UndoPlan.checkMove(disk(["/Docs": .dir(ino: nil)], item), moveBack())))
    }

    // T-4c33b607 F-549 F-555
    @Test func followsALinkToTheFolderTheItemGoesBackTo() {
        let fileSystem = disk([
            "/Data/Docs": .dir(ino: 1), "/Docs": .link(to: "/Data/Docs"), "/Docs/b.txt": .file(ino: 10),
        ])
        #expect(isOK(UndoPlan.checkMove(fileSystem, moveBack())))
        #expect(
            refusal(UndoPlan.checkMove(fileSystem, moveBack(parentId: id(5))))?.reason
                == "Its folder “Docs” was replaced by another folder.")
    }

    // T-83f0aadc F-382 F-549
    @Test func findsTheNameFreeWhenAStepBeforeItEmptiesIt() {
        let fileSystem = disk(docs, ["/Docs/b.txt": .file(ino: 10), "/Docs/a.txt": .file(ino: 11)])
        #expect(nameTaken(UndoPlan.checkMove(fileSystem, moveBack())) == true)
        var changes = UnitChanges()
        changes.movedAwayIds.insert(id(11))
        #expect(nameTaken(UndoPlan.checkMove(fileSystem, moveBack(), changes)) == false)
    }

    // T-31bcd956 F-382 F-549
    @Test func findsANameTakenWhenAStepBeforeItFillsIt() {
        let fileSystem = disk(docs, ["/Docs/b.txt": .file(ino: 10)])
        var changes = UnitChanges()
        changes.filledPlaces.insert(NameKeys.Exact("/docs/a.txt"))
        #expect(nameTaken(UndoPlan.checkMove(fileSystem, moveBack(), changes)) == true)
    }

    // T-c964d2b0 F-382 F-549
    @Test func findsAnItemWithoutAnIdGoneByItsPlaceWhateverItsCase() {
        let fileSystem = disk(docs, ["/Docs/b.txt": .file(ino: 10), "/Docs/a.txt": .file(ino: nil)])
        var changes = UnitChanges()
        changes.movedAwayPaths.insert(NameKeys.Exact("/docs/a.txt"))
        #expect(nameTaken(UndoPlan.checkMove(fileSystem, moveBack(), changes)) == false)
    }

    // T-885a9dc8 F-383 F-549
    @Test func doesntTakeAnItemWhoseKindChangedOnADiskWithoutIds() {
        let fileSystem = disk(["/Docs": .dir(ino: nil), "/Docs/a": .dir(ino: nil)])
        let check = UndoPlan.checkTrash(
            fileSystem, PlannedTrash(path: "/Docs/a", id: id(10), stamp: fileStamp(), putBack: false, unlock: true))
        guard case .refused = check else {
            Issue.record("expected a refusal, got \(check)")
            return
        }
    }

    // T-2730d4c5 F-383 F-549
    @Test func findsAnItemChangedWhenItCantBeLookedAtAgain() {
        let fileSystem = disk(["/a": .file(ino: 10)])
        fileSystem.fails = { look, _, count in look == "lstat" && count > 1 ? "EIO" : nil }
        #expect(
            UndoPlan.checkTrash(
                fileSystem, PlannedTrash(path: "/a", id: id(10), stamp: fileStamp(), putBack: false, unlock: true))
                == .ok(changed: true, id: id(10)))
    }

    // T-13a024a3 F-549
    @Test func letsItemsOfTheBatchSwapNamesAndRefusesOneThatIsntTheItemRenamed() {
        let fileSystem = disk([
            "/D": .dir(ino: 1), "/D/a": .file(ino: 10), "/D/b": .file(ino: 11), "/D/c": .dir(ino: 99),
            "/D/taken": .file(ino: 12),
        ])
        let checks = UndoPlan.checkBatch(
            fileSystem,
            [
                BatchRenamedItem(from: "/D/a", to: "/D/b", id: id(10), itemKind: .file),
                BatchRenamedItem(from: "/D/b", to: "/D/a", id: id(11), itemKind: .file),
                BatchRenamedItem(from: "/D/c", to: "/D/x", id: id(13), itemKind: .file),
                BatchRenamedItem(from: "/D/gone", to: "/D/y", id: id(14), itemKind: .file),
            ])
        #expect(
            checks.map(\.refusal?.reason) == [
                nil, nil, "The “c” in “D” is another item now.", "“gone” is no longer in “D”.",
            ])
        #expect(checks.map(\.nameTaken) == [false, false, false, false])
    }

    private func created(_ path: String, _ size: Int64) -> UndoStep {
        .created(path: path, id: id(UInt64(path.count)), stamp: fileStamp(size: size))
    }

    private func trashed(_ from: String, _ trashPath: String, _ ino: UInt64) -> UndoStep {
        .trashed(from: from, trashPath: trashPath, id: id(ino), parentId: id(1), stamp: nil)
    }

    // T-c7705fb0 F-385 F-549
    @Test func asksAboutEveryUnitAndLooksPastAnItemThatIsGone() {
        let fileSystem = disk([
            "/D": .dir(ino: 1), "/D/abc": .file(ino: 6, size: 5), "/D/T": .dir(ino: 2), "/D/T/x": .file(ino: 20),
            "/D/x": .file(ino: 21),
        ])
        let units = [
            // A Replace whose new item is gone already: the old one would go back, but its name is taken by another
            // item.
            UndoUnit(steps: [trashed("/D/x", "/D/T/x", 20), created("/D/gone", 0)]),
            // A copy that changed since it was made (5 bytes now, 0 then).
            UndoUnit(steps: [created("/D/abc", 0)]),
        ]
        #expect(
            UndoPlan.findQuestions(fileSystem, units)
                == UndoQuestions(
                    nameTaken: [TakenName(name: "x", path: "/D/x")],
                    changed: [ChangedItem(name: "abc", path: "/D/abc", putBack: false, replaced: false)]))
    }

    // T-1ca6ffdf F-385 F-549
    @Test func saysWhichChangedItemsReplacedAnOldOneAndWhichWerePutBack() {
        let fileSystem = disk([
            "/D": .dir(ino: 1), "/D/T": .dir(ino: 2), "/D/T/old": .file(ino: 20), "/D/new": .file(ino: 4, size: 9),
            "/D/back": .file(ino: 30, size: 9),
        ])
        let units = [
            UndoUnit(steps: [
                trashed("/D/new", "/D/T/old", 20), .created(path: "/D/new", id: id(4), stamp: fileStamp()),
            ]),
            UndoUnit(steps: [
                .moved(
                    UndoStep.Moved(
                        from: "/D/T/back", to: "/D/back", id: id(30), itemKind: .file, parentId: id(2),
                        fromTrash: true, stamp: fileStamp()))
            ]),
        ]
        #expect(
            UndoPlan.findQuestions(fileSystem, units)
                == UndoQuestions(
                    nameTaken: [],
                    changed: [
                        ChangedItem(name: "back", path: "/D/back", putBack: true, replaced: false),
                        ChangedItem(name: "new", path: "/D/new", putBack: false, replaced: true),
                    ]))
    }

    // T-ff8f115c F-385 F-549
    @Test func stopsAtAnItemThatIsAnotherItemNow() {
        let fileSystem = disk([
            "/D": .dir(ino: 1), "/D/T": .dir(ino: 2), "/D/T/x": .file(ino: 20), "/D/x": .dir(ino: 30),
        ])
        #expect(
            UndoPlan.findQuestions(fileSystem, [UndoUnit(steps: [trashed("/D/x", "/D/T/x", 20), created("/D/x", 0)])])
                == UndoQuestions())
    }

    // T-066e2902 F-382 F-549
    @Test func asksWhenAStepBeforePutsAnotherItemWhereAnItemGoesBack() {
        let fileSystem = disk([
            "/D": .dir(ino: 1), "/D/T": .dir(ino: 2), "/D/T/1": .file(ino: 20), "/D/T/2": .file(ino: 21),
        ])
        // Two items that were both at "/D/x", one after the other: the second goes back there first, so the first
        // finds its name taken.
        #expect(
            UndoPlan.findQuestions(
                fileSystem, [UndoUnit(steps: [trashed("/D/x", "/D/T/1", 20), trashed("/D/X", "/D/T/2", 21)])])
                == UndoQuestions(nameTaken: [TakenName(name: "x", path: "/D/x")]))
    }

    // T-d455864e F-382 F-549 F-557
    @Test func findsTheOldItemsNameFreeOnceTheNewItemSpelledOtherwiseMovesAway() {
        let fileSystem = disk([
            "/D": .dir(ino: 1), "/D/T": .dir(ino: 2), "/D/T/x": .file(ino: 20),
            // "X" over "x" on a disk that takes them for one name: the new item is found by both.
            "/D/X": .file(ino: 4), "/D/x": .file(ino: 4),
        ])
        #expect(
            UndoPlan.findQuestions(
                fileSystem,
                [UndoUnit(steps: [trashed("/D/x", "/D/T/x", 20), .created(path: "/D/X", id: id(4), stamp: nil)])])
                == UndoQuestions())
    }

    // T-5de52fd2 F-383 F-549
    @Test func asksAboutAMadeItemItKeptNothingOf() {
        // The copy couldn't be read once made (EIO), so neither its id nor its looks were kept: what is at its place
        // now may be another item, and isn't taken to the Trash unasked.
        let fileSystem = disk(["/D": .dir(ino: 1), "/D/x": .file(ino: 40)])
        #expect(
            UndoPlan.findQuestions(fileSystem, [UndoUnit(steps: [.created(path: "/D/x", id: nil, stamp: nil)])])
                == UndoQuestions(changed: [ChangedItem(name: "x", path: "/D/x", putBack: false, replaced: false)]))
    }

    // T-becb3d03 F-549
    @Test func asksAboutATakenNameInABatch() {
        let fileSystem = disk(["/D": .dir(ino: 1), "/D/b": .file(ino: 10), "/D/a": .file(ino: 11)])
        #expect(
            UndoPlan.findQuestions(
                fileSystem,
                [
                    UndoUnit(steps: [
                        .batchRenamed(items: [BatchRenamedItem(from: "/D/a", to: "/D/b", id: id(10), itemKind: .file)])
                    ])
                ]) == UndoQuestions(nameTaken: [TakenName(name: "a", path: "/D/a")]))
    }

    // T-8c262482 F-549
    @Test func asksAboutANameARefusedItemOfABatchStillHolds() {
        // "a.txt" and "b.txt" swapped names, then the item now at "a.txt" was replaced by a folder: that one stays,
        // holding "a.txt", so the other can't go back there unasked.
        let fileSystem = disk(["/D": .dir(ino: 1), "/D/b.txt": .file(ino: 10), "/D/a.txt": .dir(ino: 99)])
        #expect(
            UndoPlan.findQuestions(
                fileSystem,
                [
                    UndoUnit(steps: [
                        .batchRenamed(items: [
                            BatchRenamedItem(from: "/D/a.txt", to: "/D/b.txt", id: id(10), itemKind: .file),
                            BatchRenamedItem(from: "/D/b.txt", to: "/D/a.txt", id: id(11), itemKind: .file),
                        ])
                    ])
                ]) == UndoQuestions(nameTaken: [TakenName(name: "a.txt", path: "/D/a.txt")]))
    }

    // T-2d1c0ea4 F-385 F-549
    @Test func looksAtSeveralUnitsAtOnceAndAnswersInTheirOrder() {
        var items: [String: PlanDisk.Item] = ["/D": .dir(ino: 1)]
        var units: [UndoUnit] = []
        for index in 0..<40 {
            // Every item came back from the Trash and changed since; every third one's old name is taken too.
            items["/D/T/\(index)"] = .file(ino: UInt64(100 + index))
            if index % 3 == 0 {
                items["/D/\(index)"] = .file(ino: UInt64(500 + index))
            }
            units.append(UndoUnit(steps: [trashed("/D/\(index)", "/D/T/\(index)", UInt64(100 + index))]))
        }
        let fileSystem = PlanDisk(items)
        let reading = OSAllocatedUnfairLock(initialState: (now: 0, most: 0))
        fileSystem.onLstat = { path in
            reading.withLock { state in
                state.now += 1
                state.most = max(state.most, state.now)
            }
            // Later units answer sooner, so an order kept by luck would show.
            let index = Int(NodePath.basename(path)) ?? 40
            usleep(UInt32(max(0, 40 - index)) * 200)
            reading.withLock { $0.now -= 1 }
        }
        let questions = UndoPlan.findQuestions(fileSystem, units)
        #expect(questions.nameTaken.map(\.name) == (0..<40).filter { $0 % 3 == 0 }.reversed().map(String.init))
        let most = reading.withLock { $0.most }
        #expect(most > 1)
        #expect(most <= 16)
    }

    // MARK: A disk that can't be read

    private var inTrashItems: [String: PlanDisk.Item] {
        ["/Docs": .dir(ino: 1), "/T": .dir(ino: nil), "/T/a.txt": .file(ino: nil, size: 5)]
    }

    private var putBackFile: PlannedMove {
        moveBack(
            from: "/T/a.txt", to: "/Docs/a.txt", id: nil, parentId: nil, putBack: true, stamp: fileStamp(size: 5))
    }

    private func cantCheck(_ name: String) -> MoveCheck {
        .refused(Refusal(reason: "“\(name)” couldn't be checked: A disk error occurred.", missing: false, retry: true))
    }

    // T-65ceb4ef F-379 F-554
    @Test func keepsAStepWhoseItemInTheTrashCantBeLookedAtAgain() {
        // Found, then not read for how it looks (gone or not): kept, to be looked at next time.
        for second in ["EIO", "ENOENT"] {
            let unread = disk(inTrashItems)
            unread.fails = { look, path, count in look == "lstat" && path == "/T/a.txt" && count == 2 ? second : nil }
            #expect(
                UndoPlan.checkMove(unread, putBackFile)
                    == .refused(Refusal(reason: "“a.txt” couldn't be checked.", missing: false, retry: true)))
        }
    }

    // T-1bc9f657 F-380 F-554
    @Test func keepsAStepWhoseFolderInTheTrashCantBeListed() {
        let unlisted = disk(["/Docs": .dir(ino: 1), "/T": .dir(ino: nil), "/T/F": .dir(ino: nil)])
        unlisted.fails = { look, _, _ in look == "readdir" ? "EACCES" : nil }
        var step = putBackFile
        step.from = "/T/F"
        step.to = "/Docs/F"
        step.itemKind = .directory
        step.stamp = ItemStamp(kind: .directory, size: nil, mtimeMs: 1000, entryCount: 0)
        #expect(
            UndoPlan.checkMove(unlisted, step)
                == .refused(Refusal(reason: "“F” couldn't be checked.", missing: false, retry: true)))
    }

    // T-22475f27 F-379 F-554
    @Test func keepsAStepWhoseFolderOrThePlaceItGoesBackToCantBeLookedAt() {
        let folder = disk(docs, ["/Docs/b.txt": .file(ino: 10)])
        folder.fails = { look, path, _ in look == "stat" && path == "/Docs" ? "EIO" : nil }
        #expect(UndoPlan.checkMove(folder, moveBack()) == cantCheck("Docs"))
        let place = disk(docs, ["/Docs/b.txt": .file(ino: 10)])
        place.fails = { look, path, _ in look == "lstat" && path == "/Docs/a.txt" ? "EIO" : nil }
        #expect(UndoPlan.checkMove(place, moveBack()) == cantCheck("a.txt"))
    }

    // T-0d59aa22 F-382 F-557
    @Test func findsANameTakenByAnotherItemThatDiffersFromItOnlyInCase() {
        let fileSystem = disk(docs, ["/Docs/b.txt": .file(ino: 10), "/Docs/B.txt": .file(ino: 11)])
        guard
            case .ok(let nameTaken, let renamesItself, _, _, _) = UndoPlan.checkMove(
                fileSystem, moveBack(to: "/Docs/B.txt"))
        else {
            Issue.record("expected the move to be possible")
            return
        }
        #expect(nameTaken)
        #expect(!renamesItself)
    }

    // T-708f3d3a F-379 F-554
    @Test func keepsAStepToMoveToTheTrashAnItemItCantLookAt() {
        let fileSystem = disk(["/a": .file(ino: 10)])
        fileSystem.fails = { _, _, _ in "EIO" }
        #expect(
            UndoPlan.checkTrash(
                fileSystem, PlannedTrash(path: "/a", id: id(10), stamp: nil, putBack: false, unlock: true))
                == .refused(
                    Refusal(reason: "“a” couldn't be checked: A disk error occurred.", missing: false, retry: true)))
    }

    // T-be5280e5 F-383 F-549
    @Test func findsAnItemChangedWhenTheVeryItemIsNowAnotherKind() {
        #expect(
            UndoPlan.checkTrash(
                disk(["/a": .dir(ino: 10)]),
                PlannedTrash(path: "/a", id: id(10), stamp: fileStamp(), putBack: false, unlock: true))
                == .ok(changed: true, id: id(10)))
    }

    // T-a291d40b F-554
    @Test func keepsTheItemsOfABatchItCantLookAtOrWhoseNamesItCant() {
        let fileSystem = disk([
            "/D": .dir(ino: 1), "/D/a": .file(ino: 10), "/D/b": .file(ino: 11), "/D/c": .file(ino: 12),
            "/D/fat": .file(ino: nil),
        ])
        fileSystem.fails = { look, path, _ in look == "lstat" && (path == "/D/a" || path == "/D/y") ? "EIO" : nil }
        let checks = UndoPlan.checkBatch(
            fileSystem,
            [
                BatchRenamedItem(from: "/D/a", to: "/D/x", id: id(10), itemKind: .file),
                BatchRenamedItem(from: "/D/b", to: "/D/y", id: id(11), itemKind: .file),
                BatchRenamedItem(from: "/D/c", to: "/D/fat", id: id(12), itemKind: .file),
            ])
        #expect(
            checks.map(\.refusal?.reason) == [
                "“a” couldn't be checked: A disk error occurred.", "“y” couldn't be checked: A disk error occurred.",
                // An item without an id in the way is never taken for one of the batch.
                nil,
            ])
        #expect(checks.map(\.nameTaken) == [false, false, true])
    }
}
