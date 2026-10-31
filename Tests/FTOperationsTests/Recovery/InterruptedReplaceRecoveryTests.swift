// Port of the recovery cases of packages/core/src/fs/copyPasteFolderSafety.realfs.test.ts ("recovering interrupted
// Replaces")
import Darwin
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTOperations

struct RecoveringInterruptedReplacesTests {
    private func withPlaces(_ body: (String) throws -> Void) throws {
        try withTemporaryDirectory { root in
            defer {
                Disk.chmod(root.path + "/dst/.module.filetrail-00001234/inner", 0o755)
            }
            try Disk.makeDirectories(root.path + "/src")
            try Disk.makeDirectories(root.path + "/dst")
            try body(root.path)
        }
    }

    private func entry(
        _ root: String, id: String = "entry-1", stagingPath: String? = nil, finalPath: String? = nil,
        moved: Bool = false, staged: Bool = false
    ) -> ReplaceJournalEntry {
        ReplaceJournalEntry(
            id: id, stagingPath: stagingPath ?? root + "/dst/.report.txt.filetrail-00001234",
            finalPath: finalPath ?? root + "/dst/report.txt", sourcePath: root + "/src/report.txt", moved: moved,
            staged: staged)
    }

    // T-302e20ea F-355 F-524
    @Test func finishesAMoveWhoseOldItemAlreadyWentToTheTrash() throws {
        try withPlaces { root in
            let interrupted = entry(root, moved: true, staged: true)
            try Disk.write(interrupted.stagingPath, "moved")

            let outcomes = recoverInterruptedReplaces([interrupted], NativeWriteFileSystem())

            #expect(outcomes.map(\.outcome) == [.finished(path: interrupted.finalPath)])
            #expect(Disk.read(interrupted.finalPath) == "moved")
            #expect(!Disk.exists(interrupted.stagingPath))
        }
    }

    // T-37290acb F-524
    @Test func touchesNothingWhileAnotherOperationWritesAndSaysTheEntryIsPutOff() throws {
        try withPlaces { root in
            let interrupted = entry(root, moved: true, staged: true)
            try Disk.write(interrupted.stagingPath, "moved")

            let outcomes = recoverInterruptedReplaces(
                [interrupted], NativeWriteFileSystem(), RecoveryOptions(runWriteAlone: { _ in false }))

            #expect(outcomes == [ReplaceRecovery(entry: interrupted, outcome: .deferred)])
            #expect(Disk.read(interrupted.stagingPath) == "moved")
            #expect(!Disk.exists(interrupted.finalPath))
        }
    }

    // T-86936628 F-524
    @Test func makesItsChangesInsideRunWriteAloneWhenItIsGiven() throws {
        try withPlaces { root in
            let interrupted = entry(root, moved: true, staged: true)
            try Disk.write(interrupted.stagingPath, "moved")
            let inside = Locked(false)
            let stagingGoneInside = Locked(false)

            let outcomes = recoverInterruptedReplaces(
                [interrupted], NativeWriteFileSystem(),
                RecoveryOptions(runWriteAlone: { write in
                    inside.mutate { $0 = true }
                    write()
                    let gone = !Disk.exists(interrupted.stagingPath)
                    stagingGoneInside.mutate { $0 = gone }
                    inside.mutate { $0 = false }
                    return true
                }))

            #expect(outcomes.map(\.outcome) == [.finished(path: interrupted.finalPath)])
            #expect(stagingGoneInside.value)
            #expect(!inside.value)
            #expect(Disk.read(interrupted.finalPath) == "moved")
        }
    }

    // T-9b428919 F-355 F-524
    @Test func putsAMovedItemBackWhenTheOldItemWasNeverRemoved() throws {
        try withPlaces { root in
            let interrupted = entry(root, moved: true, staged: true)
            try Disk.write(interrupted.stagingPath, "moved")
            try Disk.write(interrupted.finalPath, "old")

            let outcomes = recoverInterruptedReplaces([interrupted], NativeWriteFileSystem())

            #expect(outcomes.map(\.outcome) == [.restored(path: interrupted.sourcePath)])
            #expect(Disk.read(interrupted.sourcePath) == "moved")
            #expect(Disk.read(interrupted.finalPath) == "old")
        }
    }

    // T-4110113e F-355 F-524
    @Test func givesAMovedItemAVisibleNameWhenBothOfItsPlacesAreTaken() throws {
        try withPlaces { root in
            let interrupted = entry(root, moved: true, staged: true)
            try Disk.write(interrupted.stagingPath, "moved")
            try Disk.write(interrupted.finalPath, "old")
            try Disk.write(interrupted.sourcePath, "someone else's")

            let outcomes = recoverInterruptedReplaces([interrupted], NativeWriteFileSystem())

            #expect(outcomes.map(\.outcome) == [.keptVisible(path: root + "/dst/report copy.txt")])
            #expect(Disk.read(root + "/dst/report copy.txt") == "moved")
        }
    }

    // T-9d4d733c F-355 F-524
    @Test func finishesACompleteCopyWhoseOldItemAlreadyWentToTheTrash() throws {
        try withPlaces { root in
            let interrupted = entry(root, staged: true)
            try Disk.write(interrupted.stagingPath, "copy")
            try Disk.write(interrupted.sourcePath, "copy")

            let outcomes = recoverInterruptedReplaces([interrupted], NativeWriteFileSystem())

            #expect(outcomes.map(\.outcome) == [.finished(path: interrupted.finalPath)])
            #expect(Disk.read(interrupted.finalPath) == "copy")
        }
    }

    // T-10d0620f F-355 F-524 F-346
    @Test func removesAnUnfinishedCopyAndLeavesTheOldItemAlone() throws {
        try withPlaces { root in
            let interrupted = entry(
                root, stagingPath: root + "/dst/.module.filetrail-00001234", finalPath: root + "/dst/module")
            try Disk.makeDirectories(interrupted.stagingPath + "/inner")
            Disk.chmod(interrupted.stagingPath + "/inner", 0o555)
            try Disk.makeDirectories(interrupted.finalPath)

            let outcomes = recoverInterruptedReplaces([interrupted], NativeWriteFileSystem())

            #expect(outcomes.map(\.outcome) == [.removedCopy])
            #expect(Disk.list(root + "/dst") == ["module"])
        }
    }

    // T-be6c64e9 F-355 F-524
    @Test func removesAnUnfinishedCopyEvenWhenTheOldItemIsGone() throws {
        try withPlaces { root in
            let interrupted = entry(root, staged: false)
            try Disk.write(interrupted.stagingPath, "partial")

            let outcomes = recoverInterruptedReplaces([interrupted], NativeWriteFileSystem())

            #expect(outcomes.map(\.outcome) == [.removedCopy])
            #expect(!Disk.exists(interrupted.finalPath))
        }
    }

    // T-19055326 F-524
    @Test func hasNothingToDoWhenTheReplaceHadFinished() throws {
        try withPlaces { root in
            try Disk.write(root + "/dst/report.txt", "done")

            let outcomes = recoverInterruptedReplaces(
                [entry(root, moved: true, staged: true)], NativeWriteFileSystem())

            #expect(outcomes.map(\.outcome) == [.nothingLeft])
        }
    }

    // T-c87860f8 F-524
    @Test func reportsAnEntryItCouldntRecoverAndGoesOnWithTheRest() throws {
        try withPlaces { root in
            let stuck = entry(root, id: "stuck", moved: true, staged: true)
            try Disk.write(stuck.stagingPath, "moved")
            let fine = entry(
                root, id: "fine", stagingPath: root + "/dst/.other.txt.filetrail-00001234",
                finalPath: root + "/dst/other.txt")
            let fileSystem = TestFileSystem()
            fileSystem.renameExclusiveImpl = { _, _ in
                throw NativeError(message: "EACCES: permission denied", code: "EACCES")
            }

            let outcomes = recoverInterruptedReplaces([stuck, fine], fileSystem)

            #expect(
                outcomes.map(\.outcome) == [
                    .failed(error: "You don't have permission to access this item."), .nothingLeft,
                ])
        }
    }
}
