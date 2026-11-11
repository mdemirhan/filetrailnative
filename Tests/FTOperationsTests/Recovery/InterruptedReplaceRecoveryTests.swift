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

    @Test func removesAnUnfinishedCopyEvenWhenTheOldItemIsGone() throws {
        try withPlaces { root in
            let interrupted = entry(root, staged: false)
            try Disk.write(interrupted.stagingPath, "partial")

            let outcomes = recoverInterruptedReplaces([interrupted], NativeWriteFileSystem())

            #expect(outcomes.map(\.outcome) == [.removedCopy])
            #expect(!Disk.exists(interrupted.finalPath))
        }
    }

    @Test func hasNothingToDoWhenTheReplaceHadFinished() throws {
        try withPlaces { root in
            try Disk.write(root + "/dst/report.txt", "done")

            let outcomes = recoverInterruptedReplaces(
                [entry(root, moved: true, staged: true)], NativeWriteFileSystem())

            #expect(outcomes.map(\.outcome) == [.nothingLeft])
        }
    }

    @Test func reportsAnEntryItCouldntRecoverAndGoesOnWithTheRest() throws {
        try withPlaces { root in
            let stuck = entry(root, id: "stuck", moved: true, staged: true)
            try Disk.write(stuck.stagingPath, "moved")
            let fine = entry(
                root, id: "fine", stagingPath: root + "/dst/.other.txt.filetrail-00001234",
                finalPath: root + "/dst/other.txt")
            let fileSystem = TestFileSystem()
            fileSystem.renameExclusiveImpl = { _, _ in
                throw NativeError(message: "EACCES: permission denied", code: .errno(EACCES))
            }

            let outcomes = recoverInterruptedReplaces([stuck, fine], fileSystem)

            #expect(
                outcomes.map(\.outcome) == [
                    .failed(error: "You don't have permission to access this item."), .nothingLeft,
                ])
        }
    }
}
