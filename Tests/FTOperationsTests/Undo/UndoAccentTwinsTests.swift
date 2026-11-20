// An Undo of two items whose paths differ only in how an accent is stored, both changed since
import FTFoundation
import Foundation
import Testing

@testable import FTOperations

/// "café" with its "é" as one scalar, and as an "e" with the accent after it: two items on a disk that keeps both.
/// A stand-in answers for the disk: a Mac's own holds only one.
struct UndoAccentTwinsTests {
    private let composed = "/disk/caf\u{E9}"
    private let decomposed = "/disk/cafe\u{301}"

    private func bytes(_ paths: [String]) -> Set<[UInt8]> { Set(paths.map { Array($0.utf8) }) }

    /// A disk where both are files, and nothing tells them from what the operation made: each is asked about.
    private func disk() -> TestLocalFileSystem {
        let fileSystem = TestLocalFileSystem.stub()
        fileSystem.lstatImpl = { _ in Stats.file() }
        return fileSystem
    }

    private var units: [UndoUnit] {
        [
            UndoUnit(steps: [
                .created(path: composed, id: nil, stamp: nil), .created(path: decomposed, id: nil, stamp: nil),
            ])
        ]
    }

    // Both were agreed to: both go to the Trash.
    @Test func bothAgreedToGoToTheTrash() {
        let fileSystem = disk()
        let agreed: Set<DiskPath> = [DiskPath(composed), DiskPath(decomposed)]
        let run = UndoExecution.runUndo(
            units, UndoRunOptions(direction: .undo, fileSystem: fileSystem, changedAgreed: agreed))
        #expect(run.items.map(\.status) == [.completed, .completed])
        #expect(bytes(fileSystem.calls.trash) == bytes([composed, decomposed]))
    }

    // Only one was agreed to: the other is left, and said to be.
    @Test func theOneNotAgreedToIsLeft() {
        let fileSystem = disk()
        let run = UndoExecution.runUndo(
            units, UndoRunOptions(direction: .undo, fileSystem: fileSystem, changedAgreed: [DiskPath(decomposed)]))
        #expect(!bytes(fileSystem.calls.trash).contains(Array(composed.utf8)))
        let left = run.items.filter { $0.status == .failed }
        #expect(bytes(left.compactMap(\.sourcePath)) == bytes([composed]))
    }
}
