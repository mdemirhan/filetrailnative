// Port of the analysis-job cases of packages/core/src/fs/writeService.analysis.test.ts and writeService.test.ts
import FTFoundation
import Foundation
import Testing
import os

@testable import FTOperations

/// Ids "analysis-1", "analysis-2", … from a counter of the test's own, as the original's tests inject them.
private func countingIds() -> @Sendable () -> String {
    let index = OSAllocatedUnfairLock(initialState: 0)
    return {
        index.withLock { value in
            value += 1
            return "analysis-\(value)"
        }
    }
}

/// Holds whoever waits on it until opened: a read that takes its time, or a paste that hasn't finished.
private final class Gate: Sendable {
    private let semaphore = DispatchSemaphore(value: 0)

    func wait() {
        semaphore.wait()
        semaphore.signal()
    }

    func open() {
        semaphore.signal()
    }
}

private func request(_ sources: [String], into destination: String, mode: CopyPasteMode = .copy)
    -> CopyPasteAnalysisRequest
{
    CopyPasteAnalysisRequest(mode: mode, sourcePaths: sources, destinationDirectoryPath: destination)
}

private func status(_ service: WriteService, _ analysisId: String) -> CopyPasteAnalysisJobStatus? {
    try? service.getCopyPasteAnalysisUpdate(analysisId).status
}

private func message(_ body: () throws -> Void) -> String? {
    do {
        try body()
        return nil
    } catch {
        return errorMessage(error)
    }
}

struct WriteServiceAnalysisTests {
    private static func fileToCopy() -> MockAnalysisFileSystem {
        MockAnalysisFileSystem([
            ("/source", .directory()), ("/source/file.txt", .file(size: 5)), ("/target", .directory()),
        ])
    }

    /// A folder whose reads take 20 ms each.
    private static func slowFolder() -> MockAnalysisFileSystem {
        let fileSystem = MockAnalysisFileSystem([
            ("/source", .directory()), ("/source/folder", .directory()), ("/source/folder/file.txt", .file(size: 5)),
            ("/target", .directory()),
        ])
        fileSystem.readdirImpl = { path in
            Thread.sleep(forTimeInterval: 0.02)
            return path == "/source/folder" ? ["file.txt"] : ["folder"]
        }
        return fileSystem
    }

    // T-55f4c6a8 F-241
    @Test func runsAndReportsACopyPasteAnalysisJobToCompletion() async throws {
        let service = WriteService(.init(fileSystem: Self.fileToCopy(), createAnalysisId: { "analysis-1" }))

        let handle = try service.startCopyPasteAnalysis(request(["/source/file.txt"], into: "/target"))
        #expect(handle == CopyPasteAnalysisStartHandle(analysisId: "analysis-1", status: .queued))

        #expect(await waitFor { status(service, "analysis-1") == .complete })
        let update = try service.getCopyPasteAnalysisUpdate("analysis-1")
        #expect(update.done)
        #expect(update.report?.destinationDirectoryPath == "/target")
    }

    // T-ea7e3449 F-241
    @Test func cancelsInFlightAnalysisJobs() async throws {
        let service = WriteService(.init(fileSystem: Self.slowFolder(), createAnalysisId: { "analysis-1" }))

        _ = try service.startCopyPasteAnalysis(request(["/source/folder"], into: "/target"))
        #expect(service.cancelCopyPasteAnalysis("analysis-1"))

        #expect(
            await waitFor {
                let update = try service.getCopyPasteAnalysisUpdate("analysis-1")
                return update.status == .cancelled && update.done
            })
    }

    // T-a477e632 F-241
    @Test func reportsAnalysisErrorsAndRejectsExecutionForUnknownAnalysisIds() async throws {
        let fileSystem = MockAnalysisFileSystem([
            ("/source", .directory()), ("/source/file.txt", .file(size: 1)), ("/target", .directory()),
            ("/target/file.txt", .file(size: 1)),
        ])
        // No name for "Keep Both" can be checked, so none can be offered.
        let base = fileSystem.base
        fileSystem.lstatImpl = { path in
            if path.hasPrefix("/target/file copy") {
                throw codedError("EACCES", "EACCES: permission denied")
            }
            return try base.stat(path)
        }
        let service = WriteService(.init(fileSystem: fileSystem, createAnalysisId: { "analysis-1" }))

        _ = try service.startCopyPasteAnalysis(request(["/source/file.txt"], into: "/target"))

        #expect(await waitFor { status(service, "analysis-1") == .error })
        let update = try service.getCopyPasteAnalysisUpdate("analysis-1")
        #expect(update.done)
        #expect(update.error == "Couldn't find a free name for \u{201C}file.txt\u{201D}.")
        #expect(
            message {
                _ = try service.startCopyPaste(
                    CopyPasteExecutionRequest(analysisId: "missing-analysis", policy: .defaultCopyPaste))
            } == "Unknown copy/paste analysis job: missing-analysis")
    }

    // T-9358c957 F-241
    @Test func rejectsStartingASecondAnalysisWhileAnotherAnalysisIsStillRunning() throws {
        let service = WriteService(.init(fileSystem: Self.slowFolder(), createAnalysisId: countingIds()))

        _ = try service.startCopyPasteAnalysis(request(["/source/folder"], into: "/target"))

        #expect(
            message { _ = try service.startCopyPasteAnalysis(request(["/source/folder"], into: "/target")) }
                == WriteServiceMessages.analysisBusy)
        service.cancelCopyPasteAnalysis("analysis-1")
    }

    // The window whose start was refused still has its review open.
    // T-62ca8fa5 F-241 F-252
    @Test func dropsNoFinishedAnalysisWhenANewOneIsRefused() async throws {
        let fileSystem = MockAnalysisFileSystem([
            ("/source", .directory()), ("/source/folder", .directory()), ("/source/folder/file.txt", .file(size: 5)),
            ("/target", .directory()),
        ])
        let service = WriteService(.init(fileSystem: fileSystem, createAnalysisId: countingIds()))
        let analysis = request(["/source/folder"], into: "/target")
        _ = try service.startCopyPasteAnalysis(analysis)
        #expect(await waitFor { status(service, "analysis-1") == .complete })
        // Another window's analysis takes its time.
        let gate = Gate()
        fileSystem.readdirImpl = { _ in
            gate.wait()
            return []
        }
        _ = try service.startCopyPasteAnalysis(analysis, keep: ["analysis-1"])

        #expect(
            message { _ = try service.startCopyPasteAnalysis(analysis, keep: ["analysis-2"]) }
                == WriteServiceMessages.analysisBusy)
        #expect(status(service, "analysis-1") == .complete)
        service.cancelCopyPasteAnalysis("analysis-2")
        gate.open()
    }

    // T-751ce3bd F-241
    @Test func rejectsStartingAnalysisWhileAWriteOperationIsActive() async throws {
        let pasting = Gate()
        let service = WriteService(
            .init(
                fileSystem: Self.fileToCopy(), createOperationId: { "copy-op-1" }, createAnalysisId: { "analysis-1" },
                executeCopyPaste: { _ in pasting.wait() }))
        _ = try service.startCopyPasteAnalysis(request(["/source/file.txt"], into: "/target"))
        #expect(await waitFor { status(service, "analysis-1") == .complete })
        _ = try service.startCopyPaste(CopyPasteExecutionRequest(analysisId: "analysis-1", policy: .defaultCopyPaste))

        #expect(
            message { _ = try service.startCopyPasteAnalysis(request(["/source/file.txt"], into: "/target")) }
                == WriteServiceMessages.writeOperationBusy)
        pasting.open()
    }

    // T-e8b5e138 F-241 F-252
    @Test func prunesTerminalAnalysisJobsWhenANewAnalysisStarts() async throws {
        let service = WriteService(.init(fileSystem: Self.fileToCopy(), createAnalysisId: countingIds()))
        _ = try service.startCopyPasteAnalysis(request(["/source/file.txt"], into: "/target"))
        #expect(await waitFor { status(service, "analysis-1") == .complete })

        _ = try service.startCopyPasteAnalysis(request(["/source/file.txt"], into: "/target"))

        #expect(
            message { _ = try service.getCopyPasteAnalysisUpdate("analysis-1") }
                == "Unknown copy/paste analysis job: analysis-1")
    }

    // Another window's review is still open, and can still be pasted from.
    // T-2eb88377 F-241 F-252
    @Test func keepsTheFinishedAnalysesItIsAskedToKeepButNotCancelledOnes() async throws {
        let service = WriteService(.init(fileSystem: Self.fileToCopy(), createAnalysisId: countingIds()))
        let analysis = request(["/source/file.txt"], into: "/target")
        func finished(_ analysisId: String) async -> Bool {
            await waitFor { try service.getCopyPasteAnalysisUpdate(analysisId).done }
        }

        _ = try service.startCopyPasteAnalysis(analysis)
        #expect(await finished("analysis-1"))
        _ = try service.startCopyPasteAnalysis(analysis, keep: ["analysis-1"])
        #expect(await finished("analysis-2"))
        service.cancelCopyPasteAnalysis("analysis-2")
        _ = try service.startCopyPasteAnalysis(analysis, keep: ["analysis-1", "analysis-2"])
        #expect(await finished("analysis-3"))

        #expect(status(service, "analysis-1") == .complete)
        #expect(
            message { _ = try service.getCopyPasteAnalysisUpdate("analysis-2") }
                == "Unknown copy/paste analysis job: analysis-2")

        // Pasting from one keeps the others it is asked to keep, too.
        _ = try service.startCopyPaste(
            CopyPasteExecutionRequest(analysisId: "analysis-3", policy: .defaultCopyPaste), keep: ["analysis-1"])
        #expect(status(service, "analysis-1") == .complete)
    }
}

/// Port of createMockFileSystem (packages/core/src/fs/writeService.test.ts): items by path, with no ids or dates.
private struct PathSetFileSystem: ReadOnlyWriteFileSystem {
    var existingPaths: Set<String>
    var directoryPaths: Set<String> = []
    var fileSizes: [String: Int64] = [:]
    var realPathMap: [String: String] = [:]

    private func stats(_ path: String) throws -> WriteServiceStats {
        guard existingPaths.contains(path) else {
            throw codedError("ENOENT", "ENOENT: \(path)")
        }
        let directory = directoryPaths.contains(path)
        return WriteServiceStats(
            type: directory ? .directory : .file, size: fileSizes[path] ?? 0, mode: directory ? 0o755 : 0o644)
    }

    func lstat(_ path: String) throws -> WriteServiceStats { try stats(path) }
    func stat(_ path: String) throws -> WriteServiceStats { try stats(path) }
    func realpath(_ path: String) throws -> String { realPathMap[path] ?? path }

    func readdir(_ path: String) throws -> [String] {
        var children = Set<String>()
        for existing in existingPaths {
            let segments = existing.split(separator: "/").map(String.init)
            for index in 1..<max(segments.count, 1) where "/" + segments[0..<index].joined(separator: "/") == path {
                children.insert(segments[index])
            }
        }
        return children.sorted()
    }

    func readlink(_ path: String) throws -> String {
        throw codedError("EINVAL", "EINVAL: \(path)")
    }
}

struct WriteServiceReviewTests {
    /// The finished analysis of a paste.
    private func analyze(_ service: WriteService, _ analysis: CopyPasteAnalysisRequest) async throws
        -> CopyPasteAnalysisReport
    {
        let analysisId = try service.startCopyPasteAnalysis(analysis).analysisId
        #expect(await waitFor { try service.getCopyPasteAnalysisUpdate(analysisId).done })
        let update = try service.getCopyPasteAnalysisUpdate(analysisId)
        return try #require(update.report, Comment(rawValue: "The analysis failed: \(update.error ?? "")"))
    }

    // T-8ccc2f06 F-241
    @Test func staysUsableAfterBeingAskedToStartAnUnknownAnalysis() throws {
        let service = WriteService(.init(fileSystem: NativeWriteFileSystem()))
        #expect(
            message {
                _ = try service.startCopyPaste(
                    CopyPasteExecutionRequest(
                        analysisId: "missing-analysis",
                        policy: CopyPastePolicy(file: .skip, directory: .merge, mismatch: .skip)))
            } == "Unknown copy/paste analysis job: missing-analysis")
        // The failed start must not leave the write slot claimed.
        #expect(message { _ = try service.startCopyPasteAnalysis(request(["/tmp/a"], into: "/tmp")) } == nil)
    }

    // T-4503dd53 F-256 F-419
    @Test func plansSameDirectoryCopyPasteAsDuplicateNamingInsteadOfAConflict() async throws {
        let service = WriteService(
            .init(
                fileSystem: PathSetFileSystem(
                    existingPaths: ["/workspace", "/workspace/file.txt", "/workspace/file copy.txt"],
                    directoryPaths: ["/workspace"],
                    fileSizes: ["/workspace/file.txt": 42, "/workspace/file copy.txt": 42])))

        let report = try await analyze(service, request(["/workspace/file.txt"], into: "/workspace"))

        #expect(report.nodes.map(\.sourcePath) == ["/workspace/file.txt"])
        #expect(report.nodes.map(\.destinationPath) == ["/workspace/file copy 2.txt"])
        #expect(report.nodes.first?.conflictClass == nil)
        #expect(report.issues.isEmpty)
    }

    // T-62330910 F-288 F-419
    @Test func keepsSameDirectoryCutPasteBlockedAsASelfTarget() async throws {
        let service = WriteService(
            .init(
                fileSystem: PathSetFileSystem(
                    existingPaths: ["/workspace", "/workspace/file.txt"], directoryPaths: ["/workspace"],
                    fileSizes: ["/workspace/file.txt": 42])))

        let report = try await analyze(service, request(["/workspace/file.txt"], into: "/workspace", mode: .cut))

        #expect(report.issues.map(\.code) == [.samePath])
    }

    // T-dbb2545f F-420 F-314
    @Test func findsAFileAlreadyAtTheDestinationAsAConflict() async throws {
        let service = WriteService(
            .init(
                fileSystem: PathSetFileSystem(
                    existingPaths: ["/target", "/source/file.txt", "/target/file.txt"], directoryPaths: ["/target"],
                    fileSizes: ["/source/file.txt": 42, "/target/file.txt": 42])))

        let report = try await analyze(service, request(["/source/file.txt"], into: "/target"))

        #expect(report.nodes.map(\.sourcePath) == ["/source/file.txt"])
        #expect(report.nodes.map(\.destinationPath) == ["/target/file.txt"])
        #expect(report.nodes.first?.conflictClass == .fileConflict)
    }

    // T-26a0c664 F-421
    @Test func rejectsCopyingADirectoryIntoItsOwnChild() async throws {
        let service = WriteService(
            .init(
                fileSystem: PathSetFileSystem(
                    existingPaths: ["/workspace/folder", "/workspace/folder/child"],
                    directoryPaths: ["/workspace/folder", "/workspace/folder/child"],
                    realPathMap: [
                        "/workspace/folder": "/workspace/folder", "/workspace/folder/child": "/workspace/folder/child",
                    ])))

        let report = try await analyze(service, request(["/workspace/folder"], into: "/workspace/folder/child"))

        #expect(report.issues.map(\.code) == [.parentIntoChild])
    }

    // Ensures the analysis sees .asar as a regular file rather than reading into it as a folder.
    // T-9c9fbb8d F-435
    @Test func analyzesAsarFilesAsFilesNotDirectoryTraversals() async throws {
        let service = WriteService(
            .init(
                fileSystem: PathSetFileSystem(
                    existingPaths: ["/target", "/source", "/source/app.asar"], directoryPaths: ["/target", "/source"],
                    fileSizes: ["/source/app.asar": 4096])))

        let report = try await analyze(service, request(["/source"], into: "/target"))

        #expect(report.issues.isEmpty)
        // The folder /target/source and the file /target/source/app.asar.
        #expect(report.summary.totalNodeCount == 2)
    }
}
