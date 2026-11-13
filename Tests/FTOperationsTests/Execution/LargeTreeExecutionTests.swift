import FTFoundation
import FTTestSupport
import Foundation
import Testing
import os

@testable import FTOperations

/// A disk in memory that looks items up by their exact path: the mock scans every item for a name it doesn't
/// have, which is far too slow for this many. It counts how often each item is looked at.
final class LargeFolderFileSystem: WriteServiceFileSystem, @unchecked Sendable {
    private struct Node {
        var isDirectory: Bool
        var ino: UInt64
        var size: Int64
    }

    private let lock = NSLock()
    private var nodes: [String: Node] = [:]
    private var children: [String: [String]] = [:]
    private var nextIno: UInt64 = 10
    private var readCounts: [String: Int] = [:]

    init(fileCount: Int, fileName: (Int) -> String) {
        for folder in ["/", "/source", "/source/project", "/source/project/files"] {
            add(folder, isDirectory: true)
        }
        for index in 0..<fileCount {
            add("/source/project/files/\(fileName(index))", isDirectory: false, size: 1)
        }
        add("/target", isDirectory: true)
    }

    private func add(_ path: String, isDirectory: Bool, size: Int64 = 0) {
        nodes[path] = Node(isDirectory: isDirectory, ino: nextIno, size: size)
        nextIno += 1
        if isDirectory {
            children[path] = []
        }
        if path != "/" {
            children[dirnameOf(path)]?.append(basenameOf(path))
        }
    }

    private func lookUp(_ path: String) throws -> Node {
        guard let node = nodes[path] else { throw codedError(.errno(ENOENT), "ENOENT: \(path)") }
        readCounts[path, default: 0] += 1
        return node
    }

    /// How many times an item under `folder` was looked at, at most.
    func mostReads(under folder: String) -> Int {
        withLock { readCounts.filter { $0.key.hasPrefix(folder + "/") }.values.max() ?? 0 }
    }

    private func create(_ path: String, isDirectory: Bool, size: Int64 = 0) throws {
        try withLock {
            if nodes[path] != nil {
                throw codedError(.errno(EEXIST), "EEXIST: \(path)")
            }
            _ = try lookUp(dirnameOf(path))
            add(path, isDirectory: isDirectory, size: size)
        }
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    func lstat(_ path: String) throws -> WriteServiceStats {
        let node = try withLock { try lookUp(path) }
        return WriteServiceStats(
            type: node.isDirectory ? .directory : .file, size: node.size, mode: node.isDirectory ? 0o755 : 0o644,
            mtimeMs: 1_000, ino: node.ino, dev: 1)
    }

    func stat(_ path: String) throws -> WriteServiceStats { try lstat(path) }

    func realpath(_ path: String) throws -> String {
        _ = try withLock { try lookUp(path) }
        return path
    }

    func readdir(_ path: String) throws -> [String] { withLock { children[path] ?? [] } }
    func readlink(_ path: String) throws -> String { throw codedError(.errno(EINVAL), "EINVAL: \(path)") }
    func isCaseSensitive(_ path: String) throws -> Bool? { true }
    func mkdir(_ path: String) throws { try create(path, isDirectory: true) }
    func rm(_ path: String, recursive: Bool, force: Bool) throws {}
    func rmdir(_ path: String) throws {}
    func getFlags(_ path: String) throws -> UInt32 { 0 }
    func setFlags(_ path: String, _ flags: UInt32) throws {}
    // Items keep no mode, dates or ACLs here, every folder can be written to, and there is no Trash.
    func chmod(_ path: String, _ mode: UInt32) throws {}
    func utimes(_ path: String, _ atimeMs: Double, _ mtimeMs: Double) throws {}
    func copyMetadata(_ source: String, _ destination: String) throws {}
    func copyMetadataToRunInPlace(_ source: String, _ destination: String) throws {}
    func setAcl(_ path: String, _ acl: String?) throws {}
    func trash(_ path: String) throws -> String? { throw noTrashHere() }
    func canModifyFolder(_ path: String) throws {}

    func copyFile(
        _ source: String, _ destination: String, stop: StopSignal?, onProgress: (@Sendable (Int64) -> Void)?
    ) throws {
        let size = try withLock { try lookUp(source).size }
        try create(destination, isDirectory: false, size: size)
    }

    /// A folder copied is built under a hidden name, then given its own.
    func renameExclusive(_ from: String, _ to: String) throws {
        try withLock {
            if nodes[to] != nil {
                throw codedError(.errno(EEXIST), "EEXIST: \(to)")
            }
            func moved(_ path: String) -> String? {
                path == from ? to : path.hasPrefix(from + "/") ? to + path.dropFirst(from.count) : nil
            }
            for (path, node) in nodes {
                if let target = moved(path) {
                    nodes[path] = nil
                    nodes[target] = node
                }
            }
            for (path, names) in children {
                if let target = moved(path) {
                    children[path] = nil
                    children[target] = names
                }
            }
            children[dirnameOf(from)]?.removeAll { $0 == basenameOf(from) }
            children[dirnameOf(to)]?.append(basenameOf(to))
        }
    }
}

/// A folder of 150,000 files, built and reviewed through the write service once for the two tests that need it:
/// LargeTreeAnalysisTests' review and the paste here.
enum LargeFolder {
    static let fileCount = 150_000

    /// Padded, so the files come in the order they were made.
    static func fileName(_ index: Int) -> String {
        let digits = String(index)
        return "file-" + String(repeating: "0", count: max(0, 6 - digits.count)) + digits + ".txt"
    }

    struct Reviewed: Sendable {
        let fileSystem: LargeFolderFileSystem
        /// The review of copying "/source/project" into "/target"; nil when it failed, with why.
        let report: CopyPasteAnalysisReport?
        let error: String?
        /// How many times the review looked at a file, at most.
        let mostReadsOfAFile: Int
    }

    static let reviewed = Task<Reviewed, any Error> {
        let fileSystem = LargeFolderFileSystem(fileCount: fileCount, fileName: fileName)
        let service = WriteService(.init(fileSystem: fileSystem))
        var report: CopyPasteAnalysisReport?
        var error: String?
        do {
            report = try await service.analyze(
                CopyPasteAnalysisRequest(
                    mode: .copy, sourcePaths: ["/source/project"], destinationDirectoryPath: "/target"),
                signal: StopSignal())
        } catch let failure {
            error = errorMessage(failure)
        }
        return Reviewed(
            fileSystem: fileSystem, report: report, error: error,
            mostReadsOfAFile: fileSystem.mostReads(under: "/source/project/files"))
    }
}

/// Copying a folder of 150,000 files.
struct LargeTreeExecutionTests {
    private static let fileCount = LargeFolder.fileCount
    private static func fileName(_ index: Int) -> String { LargeFolder.fileName(index) }

    // The folder is reviewed through the write service, as LargeTreeAnalysisTests' review is, and pasted on the
    // disk it was reviewed on. Only a release runs it.
    @Test(.enabled(if: ReleaseTests.enabled)) func analyzesAndCopiesEveryItem() async throws {
        let reviewed = try await LargeFolder.reviewed.value
        let fileSystem = reviewed.fileSystem
        let report = try #require(reviewed.report, Comment(rawValue: reviewed.error ?? ""))
        #expect(report.summary.totalNodeCount == Self.fileCount + 2)
        let resolvedNodes = try resolveAnalysisWithPolicy(report: report, policy: addMissing, fileSystem: fileSystem)
        let events = await execute(fileSystem, (report, resolvedNodes), operationId: "copy-large")

        let result = events.last?.result
        #expect(result?.status == .completed)
        // The folder, then each file in it.
        #expect(result?.items.count == Self.fileCount + 1)
        #expect(result?.items.first?.destinationPath == "/target/project")
        #expect(result?.items.last?.destinationPath == "/target/project/files/\(Self.fileName(Self.fileCount - 1))")
        #expect(try fileSystem.readdir("/target/project/files").count == Self.fileCount)
    }
}
