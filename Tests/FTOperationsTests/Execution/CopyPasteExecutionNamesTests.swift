// Port of "names the destination can't tell apart" and "a folder renamed whole"
// (packages/core/src/fs/copyPasteExecution.test.ts)
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTOperations

struct CopyPasteExecutionNamesTests {
    // T-3f7a78a7 F-330
    @Test func findsAnExistingItemWhateverTheLetterCaseAsAPFSDoes() throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source/README.txt", .file(size: 2)), ("/target/readme.txt", .file(size: 1)),
        ])

        let (report, _) = try createResolvedOperation(fileSystem, sources: ["/source/README.txt"], into: "/target")

        #expect(report.nodes.first?.conflictClass == .fileConflict)
        #expect(report.nodes.first?.destinationPath == "/target/README.txt")
    }

    // The review stops such a paste; this is the guard behind it. A folder from a disk that tells "A.txt" from
    // "a.txt" lands on one that doesn't: the second item must never replace the first, which this same paste
    // just wrote.
    // T-c44a664c F-330
    @Test func neverLetsALaterItemReplaceOneThisPasteJustWroteUnderTheSameName() async throws {
        let fileSystem = MockWriteServiceFileSystem()
        fileSystem.caseSensitive = true
        // On another disk, so the folder is copied item by item.
        fileSystem.addDirectory("/source", .directory(dev: 2))
        fileSystem.addFile("/source/F/A.txt", .file(size: 5))
        fileSystem.addFile("/source/F/a.txt", .file(size: 6))
        fileSystem.addDirectory("/target")
        fileSystem.enableTrash()
        var operation = try createResolvedOperation(
            fileSystem, mode: .cut, sources: ["/source/F"], into: "/target", policy: NativePaste.replaceAll)
        // The destination turns out not to tell case apart after all.
        fileSystem.caseSensitive = false
        operation.report.destinationCaseSensitive = false
        let recorder = PasteRecorder()

        let events = await execute(
            fileSystem, operation, operationId: "op-case", policy: NativePaste.replaceAll, recorder: recorder,
            requestResolution: { _ in .immediate(.overwrite) })

        let result = try #require(events.last?.result)
        #expect(recorder.conflicts.isEmpty)
        let item = result.items.first { $0.sourcePath == "/source/F/a.txt" }
        #expect(item?.status == .failed)
        #expect(
            item?.error
                == "\u{201C}a.txt\u{201D} wasn't pasted because another item of this paste has the same name on this disk, which doesn't tell upper and lower case apart."
        )
        #expect(fileSystem.trashed == [])
        // The move is given up whole: both originals stay where they were.
        #expect(!fileSystem.exists("/target/F"))
        #expect(fileSystem.readNode("/source/F/A.txt")?.size == 5)
        #expect(fileSystem.readNode("/source/F/a.txt")?.size == 6)
    }

    // Some disks take other names for one item too ("Strasse.txt" for "Straße.txt"): the item there is known by
    // its id as the one this paste just wrote, and isn't replaced.
    // T-b4944502 F-330
    @Test func neverLetsALaterItemReplaceOneThisPasteWroteUnderANameTheDiskTakesAsItsOwn() async throws {
        let fileSystem = MockWriteServiceFileSystem()
        fileSystem.addFile("/one/Straße.txt", .file(size: 5))
        fileSystem.addFile("/two/Strasse.txt", .file(size: 6))
        fileSystem.addDirectory("/target")
        fileSystem.enableTrash()
        // A volume that takes "ß" for "ss" as well as ignoring case.
        fileSystem.foldImpl = { NameKeys.placeKey($0).replacingOccurrences(of: "ß", with: "ss") }
        let operation = try createResolvedOperation(
            fileSystem, sources: ["/one/Straße.txt", "/two/Strasse.txt"], into: "/target",
            policy: NativePaste.replaceAll)
        let recorder = PasteRecorder()

        let events = await execute(
            fileSystem, operation, operationId: "op-fold", policy: NativePaste.replaceAll, recorder: recorder,
            requestResolution: { _ in .immediate(.overwrite) })

        let result = try #require(events.last?.result)
        #expect(recorder.conflicts.isEmpty)
        let item = result.items.first { $0.sourcePath == "/two/Strasse.txt" }
        #expect(item?.status == .failed)
        #expect(
            item?.error
                == "\u{201C}Strasse.txt\u{201D} wasn't pasted because another item of this paste has the same name on this disk, which doesn't tell upper and lower case apart."
        )
        #expect(fileSystem.readNode("/target/Straße.txt")?.size == 5)
        #expect(fileSystem.trashed == [])
    }
}

// A folder moved on its own disk to a free name is renamed whole, what is in it unread: it is never copied or
// merged, and is left where it was when a rename no longer does it.
struct FolderRenamedWholeTests {
    private static let retry =
        "\u{201C}Project\u{201D} wasn't moved because its destination changed after the move began. Try moving it again."

    private func projectFolder() -> MockWriteServiceFileSystem {
        MockWriteServiceFileSystem([
            ("/source", .directory()), ("/source/Project", .directory()), ("/source/Project/a.txt", .file(size: 5)),
            ("/source/Project/lib/b.txt", .file(size: 7)), ("/target", .directory()),
        ])
    }

    private func moveFolder(_ fileSystem: MockWriteServiceFileSystem, beforeExecute: () -> Void = {}) async throws
        -> (result: CopyPasteOperationResult?, asked: [CopyPasteRuntimeConflict])
    {
        let operation = try createResolvedOperation(
            fileSystem, mode: .cut, sources: ["/source/Project"], into: "/target")
        #expect(operation.report.nodes.first?.renameOnly == true)
        beforeExecute()
        let recorder = PasteRecorder()
        let events = await execute(
            fileSystem, operation, operationId: "rename-only", recorder: recorder,
            requestResolution: { _ in .immediate(.merge) })
        return (events.last?.result, recorder.conflicts)
    }

    // T-d1d35c0c F-282
    @Test func isLeftUntouchedWhenTheRenameFindsAnotherDisk() async throws {
        let fileSystem = projectFolder()
        fileSystem.renameImpl = { from, _ in throw codedError("EXDEV", "EXDEV: \(from)") }

        let (result, _) = try await moveFolder(fileSystem)

        #expect(result?.items.map(\.sourcePath) == ["/source/Project"])
        #expect(result?.items.map(\.status) == [.failed])
        #expect(result?.items.map(\.error) == [Self.retry])
        #expect(fileSystem.readNode("/source/Project/a.txt")?.size == 5)
        #expect(fileSystem.readNode("/source/Project/lib/b.txt")?.size == 7)
        #expect(try fileSystem.readdir("/target") == [])
    }

    // T-9f403bf1 F-282
    @Test func isLeftUntouchedWithoutAQuestionWhenItsNameWasTakenMeanwhile() async throws {
        let fileSystem = projectFolder()

        let (result, asked) = try await moveFolder(fileSystem) {
            fileSystem.addFile("/target/Project/other.txt", .file(size: 1))
        }

        #expect(asked.isEmpty)
        #expect(result?.items.map(\.status) == [.failed])
        #expect(result?.items.map(\.error) == [Self.retry])
        #expect(try fileSystem.readdir("/target/Project") == ["other.txt"])
        #expect(fileSystem.readNode("/source/Project/lib/b.txt")?.size == 7)
    }
}
