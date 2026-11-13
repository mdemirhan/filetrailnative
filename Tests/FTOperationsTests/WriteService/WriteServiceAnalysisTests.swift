import FTFoundation
import Foundation
import Testing

@testable import FTOperations

/// Holds whoever waits on it until opened: a read that takes its time.
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

struct WriteServiceAnalysisTests {
    private static func fileToCopy() -> MockAnalysisFileSystem {
        MockAnalysisFileSystem([
            ("/source", .directory()), ("/source/file.txt", .file(size: 5)), ("/target", .directory()),
        ])
    }

    /// A folder whose reads wait until `held` is opened, after saying through `reading` that one has begun.
    private static func slowFolder(reading: Gate, held: Gate) -> MockAnalysisFileSystem {
        let fileSystem = MockAnalysisFileSystem([
            ("/source", .directory()), ("/source/folder", .directory()), ("/source/folder/file.txt", .file(size: 5)),
            ("/target", .directory()),
        ])
        fileSystem.readdirImpl = { path in
            reading.open()
            held.wait()
            return path == "/source/folder" ? ["file.txt"] : ["folder"]
        }
        return fileSystem
    }

    @Test func reviewsAPasteAndAnswersWithItsReport() async throws {
        let service = WriteService(.init(fileSystem: Self.fileToCopy(), createAnalysisId: { "analysis-1" }))

        let report = try await service.analyze(request(["/source/file.txt"], into: "/target"), signal: StopSignal())

        #expect(report.analysisId == "analysis-1")
        #expect(report.destinationDirectoryPath == "/target")
        #expect(report.nodes.map(\.sourcePath) == ["/source/file.txt"])
    }

    // Stopped while a read holds it, the review ends at once: the read is still held.
    @Test func endsAReviewAtOnceWhenItIsStopped() async throws {
        let reading = Gate()
        let held = Gate()
        defer { held.open() }
        let service = WriteService(.init(fileSystem: Self.slowFolder(reading: reading, held: held)))
        let signal = StopSignal()

        let review = Task { try await service.analyze(request(["/source/folder"], into: "/target"), signal: signal) }
        reading.wait()
        signal.stop()

        await #expect(throws: StopError.self) { try await review.value }
    }

    @Test func endsAReviewStoppedBeforeItBeganWithoutReading() async throws {
        let fileSystem = Self.fileToCopy()
        let service = WriteService(.init(fileSystem: fileSystem))
        let signal = StopSignal()
        signal.stop()

        await #expect(throws: StopError.self) {
            try await service.analyze(request(["/source/file.txt"], into: "/target"), signal: signal)
        }
        #expect(fileSystem.lstatCount == 0)
    }

    @Test func saysWhyAReviewFailed() async throws {
        let fileSystem = MockAnalysisFileSystem([
            ("/source", .directory()), ("/source/file.txt", .file(size: 1)), ("/target", .directory()),
            ("/target/file.txt", .file(size: 1)),
        ])
        // No name for "Keep Both" can be checked, so none can be offered.
        let base = fileSystem.base
        fileSystem.lstatImpl = { path in
            if path.hasPrefix("/target/file copy") {
                throw codedError(.errno(EACCES), "EACCES: permission denied")
            }
            return try base.stat(path)
        }
        let service = WriteService(.init(fileSystem: fileSystem))

        let failure = await #expect(throws: (any Error).self) {
            try await service.analyze(request(["/source/file.txt"], into: "/target"), signal: StopSignal())
        }

        #expect(failure.map(errorMessage) == "Couldn't find a free name for \u{201C}file.txt\u{201D}.")
    }

    // Each review's report has an id of its own, which its paste's events carry.
    @Test func givesEachReportAnIdOfItsOwn() async throws {
        let service = WriteService(.init(fileSystem: Self.fileToCopy()))
        let analysis = request(["/source/file.txt"], into: "/target")

        let first = try await service.analyze(analysis, signal: StopSignal())
        let second = try await service.analyze(analysis, signal: StopSignal())

        #expect([first.analysisId, second.analysisId] == ["analysis-1", "analysis-2"])
    }
}

/// Items by path, with no ids or dates.
private struct PathSetFileSystem: ReadOnlyWriteFileSystem {
    var existingPaths: Set<String>
    var directoryPaths: Set<String> = []
    var fileSizes: [String: Int64] = [:]
    var realPathMap: [String: String] = [:]

    private func stats(_ path: String) throws -> WriteServiceStats {
        guard existingPaths.contains(path) else {
            throw codedError(.errno(ENOENT), "ENOENT: \(path)")
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
        throw codedError(.errno(EINVAL), "EINVAL: \(path)")
    }
}

struct WriteServiceReviewTests {
    /// The finished review of a paste.
    private func analyze(_ service: WriteService, _ analysis: CopyPasteAnalysisRequest) async throws
        -> CopyPasteAnalysisReport
    {
        try await service.analyze(analysis, signal: StopSignal())
    }

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
}
