// Port of packages/core/src/fs/copyPasteMoveCleanup.test.ts
import FTFoundation
import FTTestSupport
import Foundation
import Testing
import os

@testable import FTOperations

/// A move to another disk removes an original only once its copy is checked.
struct CopyPasteMoveCleanupTests {
    private static let skip = CopyPastePolicy(file: .skip, directory: .skip, mismatch: .skip)
    private static let copyNotWhole =
        "It changed while it was being moved, or its copy didn't come out whole, so the original was kept."

    /// A folder on another disk (dev 2): moving it copies it, then removes the originals.
    private func folderOnAnotherDisk() -> MockWriteServiceFileSystem {
        MockWriteServiceFileSystem([
            ("/source", .directory(dev: 2)), ("/source/dir", .directory(dev: 2)),
            ("/source/dir/a.txt", .file(size: 5, dev: 2)), ("/source/dir/b.txt", .file(size: 6, dev: 2)),
            ("/source/dir/link", .symlink("a.txt", dev: 2)), ("/target", .directory()),
        ])
    }

    private func analyze(_ fileSystem: MockWriteServiceFileSystem, _ sources: [String]) throws
        -> CopyPasteAnalysisReport
    {
        try buildCopyPasteAnalysisReport(
            analysisId: "analysis-1",
            request: CopyPasteAnalysisRequest(mode: .cut, sourcePaths: sources, destinationDirectoryPath: "/target"),
            fileSystem: fileSystem,
            thresholds: CopyPasteThresholds(largeBatchItemThreshold: 100, largeBatchByteThreshold: 1000))
    }

    private func move(
        _ fileSystem: MockWriteServiceFileSystem, _ report: CopyPasteAnalysisReport,
        recorder: PasteRecorder = PasteRecorder(), answer: CopyPasteChoice? = nil
    ) async throws -> CopyPasteOperationResult {
        let resolvedNodes = try resolveAnalysisWithPolicy(report: report, policy: Self.skip, fileSystem: fileSystem)
        let events = await execute(
            fileSystem, (report, resolvedNodes), operationId: "op-1", policy: Self.skip, recorder: recorder,
            requestResolution: { _ in .immediate(answer) })
        return try #require(events.last?.result, "The move didn't finish.")
    }

    /// Runs `change` on the hidden copy just before it takes its name.
    private func beforeTheCopyTakesItsName(
        _ fileSystem: MockWriteServiceFileSystem, _ change: @escaping (String) -> Void
    ) {
        fileSystem.renameImpl = { from, to in
            if to == "/target/dir" {
                change(from)
            }
            try fileSystem.renameDirectly(from, to)
        }
    }

    private func has(
        _ result: CopyPasteOperationResult, _ sourcePath: String, _ status: CopyPasteItemResult.Status,
        error: String? = nil
    ) -> Bool {
        result.items.contains {
            $0.sourcePath == sourcePath && $0.status == status && (error == nil || $0.error == error)
        }
    }

    // T-486dca97 F-468
    @Test func keepsTheOriginalOfACopyDeletedBeforeTheOriginalsGo() async throws {
        let fileSystem = folderOnAnotherDisk()
        let report = try analyze(fileSystem, ["/source/dir"])
        beforeTheCopyTakesItsName(fileSystem) { hidden in fileSystem.deleteNode("\(hidden)/a.txt") }

        let result = try await move(fileSystem, report)

        #expect(fileSystem.exists("/source/dir/a.txt"))
        #expect(!fileSystem.exists("/source/dir/b.txt"))
        #expect(has(result, "/source/dir/a.txt", .failed, error: Self.copyNotWhole))
        #expect(has(result, "/source/dir/b.txt", .completed))
    }

    // T-59bb011e F-468
    @Test func keepsTheOriginalOfACopyCutShortOrOfALinkChanged() async throws {
        let fileSystem = folderOnAnotherDisk()
        let report = try analyze(fileSystem, ["/source/dir"])
        beforeTheCopyTakesItsName(fileSystem) { hidden in
            fileSystem.readNode("\(hidden)/a.txt")?.size = 2
            fileSystem.readNode("\(hidden)/link")?.target = "elsewhere"
        }

        let result = try await move(fileSystem, report)

        for name in ["a.txt", "link"] {
            #expect(fileSystem.exists("/source/dir/\(name)"))
            #expect(has(result, "/source/dir/\(name)", .failed, error: Self.copyNotWhole))
        }
        #expect(result.status == .partial)
    }

    // T-522a608d F-468
    @Test func keepsTheOriginalOfASingleFileWhoseCopyCameOutShort() async throws {
        let fileSystem = folderOnAnotherDisk()
        let report = try analyze(fileSystem, ["/source/dir/a.txt"])
        fileSystem.copyFileImpl = { _, destination, _, _ in fileSystem.addFile(destination, .file(size: 1)) }

        let result = try await move(fileSystem, report)

        #expect(fileSystem.exists("/source/dir/a.txt"))
        #expect(result.items.map(\.status) == [.failed])
        #expect(result.items.map(\.error) == [Self.copyNotWhole])
    }

    // T-08be9fda F-469
    @Test func removesAnOriginalThatChangedAfterTheReviewOnceThePersonGoesOnWithIt() async throws {
        let fileSystem = folderOnAnotherDisk()
        let report = try analyze(fileSystem, ["/source/dir"])
        // Saved again after the review: larger and newer.
        if let original = fileSystem.readNode("/source/dir/a.txt") {
            original.size = 50
            original.mtimeMs += 1
        }
        let recorder = PasteRecorder()

        let result = try await move(fileSystem, report, recorder: recorder, answer: .overwrite)

        #expect(
            recorder.conflicts.map { "\($0.reason.rawValue) \($0.sourcePath)" } == [
                "source_changed /source/dir/a.txt"
            ])
        #expect(result.status == .completed)
        #expect(fileSystem.readNode("/target/dir/a.txt")?.size == 50)
        #expect(!fileSystem.exists("/source/dir"))
    }

    // T-81e70f11 F-331 F-469
    @Test func removesTheOriginalsAFolderSavedAnewHoldsOnceThePersonGoesOnWithIt() async throws {
        let fileSystem = folderOnAnotherDisk()
        fileSystem.addDirectory("/source/dir/sub", .directory(dev: 2))
        fileSystem.addFile("/source/dir/sub/c.txt", .file(size: 1, dev: 2))
        let report = try analyze(fileSystem, ["/source/dir"])
        // Saved anew after the review: another folder, with c.txt changed and an item added.
        fileSystem.deleteNode("/source/dir/sub/c.txt")
        fileSystem.deleteNode("/source/dir/sub")
        fileSystem.addDirectory("/source/dir/sub", .directory(dev: 2))
        fileSystem.addFile("/source/dir/sub/c.txt", .file(size: 3, dev: 2))
        fileSystem.addFile("/source/dir/sub/added.txt", .file(size: 4, dev: 2))
        let recorder = PasteRecorder()

        let result = try await move(fileSystem, report, recorder: recorder, answer: .overwrite)

        #expect(
            recorder.conflicts.map { "\($0.reason.rawValue) \($0.sourcePath)" } == [
                "source_changed /source/dir/sub"
            ])
        #expect(result.status == .completed)
        #expect(fileSystem.readNode("/target/dir/sub/c.txt")?.size == 3)
        #expect(fileSystem.readNode("/target/dir/sub/added.txt")?.size == 4)
        #expect(!fileSystem.exists("/source/dir"))
    }

    // T-191f0b93 F-331 F-469
    @Test func removesAFolderSavedAnewAsAFileOnceThePersonGoesOnWithIt() async throws {
        let fileSystem = folderOnAnotherDisk()
        fileSystem.addDirectory("/source/dir/sub", .directory(dev: 2))
        fileSystem.addFile("/source/dir/sub/c.txt", .file(size: 1, dev: 2))
        let report = try analyze(fileSystem, ["/source/dir"])
        fileSystem.deleteNode("/source/dir/sub/c.txt")
        fileSystem.deleteNode("/source/dir/sub")
        fileSystem.addFile("/source/dir/sub", .file(size: 7, dev: 2))

        let result = try await move(fileSystem, report, answer: .overwrite)

        #expect(result.status == .completed)
        #expect(result.items.contains { $0.sourcePath == "/source/dir/sub" && $0.sourceKind == .file })
        #expect(fileSystem.readNode("/target/dir/sub")?.size == 7)
        #expect(!fileSystem.exists("/source/dir"))
    }

    // T-b7549a25 F-331 F-469
    @Test func removesAFileSavedAnewAsAFolderOnceThePersonGoesOnWithIt() async throws {
        let fileSystem = folderOnAnotherDisk()
        let report = try analyze(fileSystem, ["/source/dir"])
        fileSystem.deleteNode("/source/dir/a.txt")
        fileSystem.addDirectory("/source/dir/a.txt", .directory(dev: 2))
        fileSystem.addFile("/source/dir/a.txt/inside.txt", .file(size: 2, dev: 2))

        let result = try await move(fileSystem, report, answer: .overwrite)

        #expect(result.status == .completed)
        #expect(has(result, "/source/dir/a.txt/inside.txt", .completed))
        #expect(!result.items.contains { $0.sourcePath == "/source/dir/a.txt" && $0.sourceKind == .file })
        #expect(fileSystem.readNode("/target/dir/a.txt/inside.txt")?.size == 2)
        #expect(!fileSystem.exists("/source/dir"))
    }

    // T-29b6a0dc F-469
    @Test func saysSoWhenAFileSavedAnewAsAFolderKeepsItsOriginalFolder() async throws {
        let fileSystem = folderOnAnotherDisk()
        let report = try analyze(fileSystem, ["/source/dir"])
        fileSystem.deleteNode("/source/dir/a.txt")
        fileSystem.addDirectory("/source/dir/a.txt", .directory(dev: 2))
        fileSystem.addFile("/source/dir/a.txt/inside.txt", .file(size: 2, dev: 2))
        fileSystem.copyMetadataImpl = { source, _ in
            if source == "/source/dir/a.txt" {
                throw codedError("ENOTSUP")
            }
        }

        let result = try await move(fileSystem, report, answer: .overwrite)

        #expect(fileSystem.exists("/target/dir/a.txt/inside.txt"))
        #expect(!fileSystem.exists("/source/dir/a.txt/inside.txt"))
        #expect(fileSystem.exists("/source/dir/a.txt"))
        #expect(result.status != .completed)
        #expect(
            result.items.contains {
                $0.sourcePath == "/source/dir/a.txt" && $0.sourceKind == .directory && $0.status == .failed
                    && $0.error
                        == "Its items were moved, but the folder's own information (such as its tags) couldn't all be copied, so the original \u{201C}a.txt\u{201D} was kept."
            })
    }

    // T-45b926ae F-469
    @Test func namesAFolderSavedAnewAsAFileByWhatItIsWhenItsCopyFails() async throws {
        let fileSystem = folderOnAnotherDisk()
        fileSystem.addDirectory("/source/dir/sub", .directory(dev: 2))
        fileSystem.addFile("/source/dir/sub/c.txt", .file(size: 1, dev: 2))
        let report = try analyze(fileSystem, ["/source/dir/sub"])
        fileSystem.deleteNode("/source/dir/sub/c.txt")
        fileSystem.deleteNode("/source/dir/sub")
        fileSystem.addFile("/source/dir/sub", .file(size: 7, dev: 2))
        fileSystem.copyFileImpl = { _, _, _, _ in throw codedError("EIO", "EIO: i/o error") }

        let result = try await move(fileSystem, report, answer: .overwrite)

        #expect(result.items.map(\.sourcePath) == ["/source/dir/sub"])
        #expect(result.items.map(\.sourceKind) == [.file])
        #expect(result.items.map(\.status) == [.failed])
        #expect(fileSystem.readNode("/source/dir/sub")?.size == 7)
    }

    // T-fc3aa466 F-271 F-468
    @Test func keepsAnOriginalFolderWhoseOwnMetadataItsCopyCouldntTake() async throws {
        let fileSystem = folderOnAnotherDisk()
        fileSystem.addDirectory("/source/dir/sub", .directory(dev: 2))
        fileSystem.addFile("/source/dir/sub/c.txt", .file(size: 1, dev: 2))
        let report = try analyze(fileSystem, ["/source/dir"])
        // A disk that refuses some of it (an ACL, a flag): the copy gets the mode and dates.
        fileSystem.copyMetadataImpl = { source, _ in
            if source == "/source/dir/sub" {
                throw codedError("ENOTSUP")
            }
        }

        let result = try await move(fileSystem, report)

        // Everything in it moved; the folder keeps what its copy couldn't take.
        #expect(fileSystem.exists("/target/dir/sub/c.txt"))
        #expect(!fileSystem.exists("/source/dir/sub/c.txt"))
        #expect(fileSystem.exists("/source/dir/sub"))
        #expect(
            has(
                result, "/source/dir/sub", .failed,
                error:
                    "Its items were moved, but the folder's own information (such as its tags) couldn't all be copied, so the original \u{201C}sub\u{201D} was kept."
            ))
    }
}
