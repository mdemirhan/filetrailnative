// What the original's engine does that its own tests leave unproven: the limit on questions about one item, and a
// merge into a folder at the top of the disk (packages/core/src/fs/copyPasteExecution.ts)
import FTFoundation
import FTTestSupport
import Foundation
import Testing
import os

@testable import FTOperations

struct QuestionLimitTests {
    // A file saved again each time it is asked about is asked about five times, then left.
    // F-329
    @Test func leavesAnItemThatKeepsChangingAfterFiveQuestions() async throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source", .directory()), ("/source/a.txt", .file(size: 1)), ("/target", .directory()),
        ])
        let operation = try createResolvedOperation(fileSystem, sources: ["/source/a.txt"], into: "/target")
        fileSystem.mutateNode("/source/a.txt") { $0.size = 2 }
        let recorder = PasteRecorder()

        let events = await execute(
            fileSystem, operation, recorder: recorder,
            requestResolution: { _ in
                // Saved again while the question is open.
                fileSystem.mutateNode("/source/a.txt") { $0.size += 1 }
                return .immediate(.overwrite)
            })

        #expect(recorder.conflicts.count == maxRuntimeAttempts)
        #expect(recorder.conflicts.allSatisfy { $0.reason == .sourceChanged })
        // Each question has an id of its own.
        #expect(Set(recorder.conflicts.map(\.conflictId)).count == maxRuntimeAttempts)
        let item = events.last?.result?.items.first
        #expect(item?.status == .failed)
        #expect(item?.error == "\u{201C}a.txt\u{201D} kept changing, so it was left.")
        #expect(!fileSystem.exists("/target/a.txt"))
    }

    // A folder pasted into the disk's top folder is merged with the one of its name there.
    // F-459
    @Test func mergesIntoAFolderAtTheTopOfTheDisk() async throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source/F/new.txt", .file(size: 3)), ("/F/old.txt", .file(size: 4)),
        ])
        let operation = try createResolvedOperation(fileSystem, sources: ["/source/F"], into: "/")

        let events = await execute(fileSystem, operation)

        #expect(operation.report.nodes.first?.destinationPath == "/F")
        #expect(operation.resolvedNodes.first?.children.map(\.destinationPath) == ["/F/new.txt"])
        #expect(events.last?.status == .completed)
        #expect(try fileSystem.readdir("/F") == ["new.txt", "old.txt"])
    }
}
