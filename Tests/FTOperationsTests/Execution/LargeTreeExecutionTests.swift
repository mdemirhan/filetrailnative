// Port of packages/core/src/fs/copyPasteLargeTree.test.ts
import FTFoundation
import FTTestSupport
import Foundation
import Testing
import os

@testable import FTOperations

/// A disk in memory that looks items up by their exact path: the mock scans every item for a name it doesn't
/// have, which is far too slow for this many.
private final class LargeFolderFileSystem: WriteServiceFileSystem, @unchecked Sendable {
    private struct Node {
        var isDirectory: Bool
        var ino: UInt64
        var size: Int64
    }

    private let lock = NSLock()
    private var nodes: [String: Node] = [:]
    private var children: [String: [String]] = [:]
    private var nextIno: UInt64 = 10

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
        guard let node = nodes[path] else { throw codedError("ENOENT", "ENOENT: \(path)") }
        return node
    }

    private func create(_ path: String, isDirectory: Bool, size: Int64 = 0) throws {
        try withLock {
            if nodes[path] != nil {
                throw codedError("EEXIST", "EEXIST: \(path)")
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
    func readlink(_ path: String) throws -> String { throw codedError("EINVAL", "EINVAL: \(path)") }
    func isCaseSensitive(_ path: String) throws -> Bool? { true }
    func mkdir(_ path: String) throws { try create(path, isDirectory: true) }
    func rm(_ path: String, recursive: Bool, force: Bool) throws {}
    func rmdir(_ path: String) throws {}
    func getFlags(_ path: String) throws -> UInt32 { 0 }
    func setFlags(_ path: String, _ flags: UInt32) throws {}

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
                throw codedError("EEXIST", "EEXIST: \(to)")
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

/// Copying a folder with more items than one call takes as arguments.
struct LargeTreeExecutionTests {
    // More items than V8 takes as the arguments of one call (from about 124,000).
    private static let fileCount = 150_000

    /// Padded, so the files come in the order they were made.
    private static func fileName(_ index: Int) -> String {
        let digits = String(index)
        return "file-" + String(repeating: "0", count: max(0, 6 - digits.count)) + digits + ".txt"
    }

    // T-aa0802fe F-447
    @Test func analyzesAndCopiesEveryItem() async throws {
        let fileSystem = LargeFolderFileSystem(fileCount: Self.fileCount, fileName: Self.fileName)
        let report = try await WriteService.withRoomForDepth(name: "test review") {
            try buildCopyPasteAnalysisReport(
                analysisId: "analysis-large",
                request: CopyPasteAnalysisRequest(
                    mode: .copy, sourcePaths: ["/source/project"], destinationDirectoryPath: "/target"),
                fileSystem: fileSystem,
                thresholds: CopyPasteThresholds(largeBatchItemThreshold: 100, largeBatchByteThreshold: 1000))
        }
        #expect(report.summary.totalNodeCount == Self.fileCount + 2)
        let resolvedNodes = try resolveAnalysisWithPolicy(report: report, policy: addMissing, fileSystem: fileSystem)
        let clock = ContinuousClock()
        let started = clock.now

        let events = await execute(fileSystem, (report, resolvedNodes), operationId: "copy-large")

        let elapsed = clock.now - started
        print("copyPasteLargeTree: \(Self.fileCount) files pasted in \(elapsed)")
        let result = events.last?.result
        #expect(result?.status == .completed)
        // The folder, then each file in it.
        #expect(result?.items.count == Self.fileCount + 1)
        #expect(result?.items.first?.destinationPath == "/target/project")
        #expect(result?.items.last?.destinationPath == "/target/project/files/\(Self.fileName(Self.fileCount - 1))")
        #expect(try fileSystem.readdir("/target/project/files").count == Self.fileCount)
    }
}
