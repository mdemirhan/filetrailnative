// The review of very large and very deep trees (file-operations.md §8 note 6; copyPasteLargeTree.test.ts's paste is
// P3-03's): 150,000 items, more than the original's engine could take in one call, and a tree as deep as a path
// goes, both reviewed by the write service off the caller's thread.
import FTFoundation
import Foundation
import Testing
import os

@testable import FTOperations

/// A disk in memory that looks items up by their exact path: the mock that folds names scans every item for a name
/// it doesn't have, which is far too slow for this many.
private final class LargeTreeFileSystem: ReadOnlyWriteFileSystem, @unchecked Sendable {
    private struct Node {
        var isDirectory: Bool
        var ino: UInt64
        var children: [String] = []
    }

    private var nodes: [String: Node] = [:]
    private var nextIno: UInt64 = 10

    init() {
        add("/", isDirectory: true)
    }

    func add(_ path: String, isDirectory: Bool) {
        nodes[path] = Node(isDirectory: isDirectory, ino: nextIno)
        nextIno += 1
        if path != "/" {
            nodes[NodePath.dirname(path)]?.children.append(NodePath.basename(path))
        }
    }

    private func node(_ path: String) throws -> Node {
        guard let node = nodes[path] else {
            throw codedError("ENOENT", "ENOENT: \(path)")
        }
        return node
    }

    private func stats(_ path: String) throws -> WriteServiceStats {
        let node = try node(path)
        return WriteServiceStats(
            type: node.isDirectory ? .directory : .file, size: node.isDirectory ? 0 : 1,
            mode: node.isDirectory ? 0o755 : 0o644, mtimeMs: 1_000, ino: node.ino, dev: 1)
    }

    func lstat(_ path: String) throws -> WriteServiceStats { try stats(path) }
    func stat(_ path: String) throws -> WriteServiceStats { try stats(path) }

    func realpath(_ path: String) throws -> String {
        _ = try node(path)
        return path
    }

    func readdir(_ path: String) throws -> [String] {
        try node(path).children
    }

    func readlink(_ path: String) throws -> String {
        throw codedError("EINVAL", "EINVAL: \(path)")
    }
}

struct LargeTreeAnalysisTests {
    // More items than V8 takes as the arguments of one call (from about 124,000): LargeTreeExecutionTests' folder,
    // reviewed once through the write service for both tests.
    // F-434
    @Test func reviewsAFolderOfMoreThan125000ItemsReadingEachOnlyAFewTimes() async throws {
        let fileCount = LargeFolder.fileCount
        let reviewed = try await LargeFolder.reviewed.value
        #expect(reviewed.status == .complete, Comment(rawValue: reviewed.error ?? ""))
        let report = reviewed.report

        #expect(report?.summary.totalNodeCount == fileCount + 2)
        #expect(report?.summary.totalBytes == Int64(fileCount))
        #expect(report?.nodes.first?.children.first?.children.count == fileCount)
        // Each file is read once, by the walk.
        #expect(reviewed.mostReadsOfAFile == 1)
    }

    // A path names at most 1,024 bytes: "/source" and 508 folders "/d" deep is as deep as one goes. The review goes
    // one call deeper for each folder level, on its own thread with room for it, and so does the resolution of the
    // review when the paste starts.
    // F-434
    @Test func reviewsAndResolvesATreeAsDeepAsAPathGoes() async throws {
        let depth = 508
        let fileSystem = LargeTreeFileSystem()
        fileSystem.add("/source", isDirectory: true)
        fileSystem.add("/target", isDirectory: true)
        var path = "/source"
        for _ in 0..<depth {
            path += "/d"
            fileSystem.add(path, isDirectory: true)
        }
        #expect(path.utf8.count < 1024)
        let resolvedDepth = OSAllocatedUnfairLock<Int?>(initialState: nil)
        let service = WriteService(
            .init(
                fileSystem: fileSystem,
                executeCopyPaste: { execution in
                    var levels = 0
                    var level = execution.resolvedNodes
                    while let node = level.first {
                        levels += 1
                        level = node.children
                    }
                    resolvedDepth.withLock { [levels] in $0 = levels }
                }))
        let analysisId = try service.startCopyPasteAnalysis(
            CopyPasteAnalysisRequest(mode: .copy, sourcePaths: ["/source/d"], destinationDirectoryPath: "/target")
        ).analysisId
        _ = await waitFor(timeout: .seconds(60)) { try service.getCopyPasteAnalysisUpdate(analysisId).done }
        let update = try service.getCopyPasteAnalysisUpdate(analysisId)
        #expect(update.status == .complete, Comment(rawValue: update.error ?? ""))
        #expect(update.report?.summary.totalNodeCount == depth)

        _ = try service.startCopyPaste(CopyPasteExecutionRequest(analysisId: analysisId, policy: .defaultCopyPaste))

        #expect(await waitFor { resolvedDepth.withLock { $0 } != nil })
        #expect(resolvedDepth.withLock { $0 } == depth)
    }
}

/// How long the review of a big folder takes against the least any review must do: look up each item and the
/// name it would take. Building each item's paths once cost several times the lookups themselves, which made the
/// review of a large paste no faster than the original's.
struct LargeTreeAnalysisSpeedTests {
    private static let fileCount = 50_000

    // F-434
    @Test func reviewsABigFolderInFewTimesTheCostOfLookingUpItsItems() throws {
        let fileSystem = LargeTreeFileSystem()
        for folder in ["/source", "/source/project", "/source/project/files", "/target"] {
            fileSystem.add(folder, isDirectory: true)
        }
        var names: [String] = []
        for index in 0..<Self.fileCount {
            let name = "file-\(index)-with-a-longer-name.txt"
            names.append(name)
            fileSystem.add("/source/project/files/\(name)", isDirectory: false)
        }
        let request = CopyPasteAnalysisRequest(
            mode: .copy, sourcePaths: ["/source/project"], destinationDirectoryPath: "/target")
        let clock = ContinuousClock()
        // The quickest of three runs of each, so a busy machine slows neither one alone.
        var lookups = Duration.seconds(1_000)
        var review = Duration.seconds(1_000)
        for _ in 0..<3 {
            lookups = min(
                lookups,
                clock.measure {
                    for name in names {
                        _ = try? fileSystem.lstat("/source/project/files/" + name)
                        _ = try? fileSystem.lstat("/target/project/files/" + name)
                    }
                })
            review = min(
                review,
                try clock.measure {
                    let report = try buildCopyPasteAnalysisReport(
                        analysisId: "analysis-1", request: request, fileSystem: fileSystem,
                        thresholds: .writeService)
                    #expect(report.summary.totalNodeCount == Self.fileCount + 2)
                })
        }

        #expect(review < lookups * 12, "review \(review), lookups \(lookups)")
    }

    // A child's path is its folder's and its name put together only where `path.join` would give just that.
    @Test func joinsAChildPathAsPathJoinDoes() {
        let folders = [
            "/", "/a", "/a/b", "/a b/c.d", "/.hidden", "/a/..b", "/a/b..", "/...", "/a/...", "/\u{0301}e", "/e\u{0301}",
            "//", "/a/", "/a//b", "/./a", "/a/.", "/a/..", "/../a", "/a/./b", "/a/../b", ".", "a", "a/b", "./a", "",
        ]
        let names = [
            "x", "x.txt", ".x", "..x", "x..", "...", "._x", "e\u{0301}", "\u{1F600}", " ", ".", "..", "", "a/b", "/x",
            "x/",
        ]
        for folder in folders {
            for name in names {
                #expect(joinChildPath(folder, name) == NodePath.join(folder, name), "\(folder) + \(name)")
            }
        }
    }
}
