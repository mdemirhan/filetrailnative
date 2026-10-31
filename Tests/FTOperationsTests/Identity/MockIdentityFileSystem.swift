// Port of the reading half of MockWriteServiceFileSystem (packages/core/src/fs/testUtils.ts)
import FTFoundation
import Foundation
import os

@testable import FTOperations

/// Items in memory, looked up as APFS compares names: ignoring how accented letters are encoded, and letter case
/// unless `caseSensitive`.
final class MockIdentityFileSystem: IdentityFileSystem, @unchecked Sendable {
    enum Kind { case file, directory, symlink }

    struct Node {
        var kind: Kind
        var size: Int64 = 0
        var mode: UInt32
        var mtimeMs: Double
        var ino: UInt64
        var dev: Int64
        var target: String?
    }

    struct Seed {
        var kind: Kind
        var size: Int64?
        var mode: UInt32?
        var mtimeMs: Double?
        var ino: UInt64?
        var dev: Int64?
        var target: String?

        static func file(
            size: Int64? = nil, mode: UInt32? = nil, mtimeMs: Double? = nil, ino: UInt64? = nil, dev: Int64? = nil
        )
            -> Seed
        {
            Seed(kind: .file, size: size, mode: mode, mtimeMs: mtimeMs, ino: ino, dev: dev)
        }

        static func directory(ino: UInt64? = nil, dev: Int64? = nil) -> Seed {
            Seed(kind: .directory, ino: ino, dev: dev)
        }

        static func symlink(_ target: String, mode: UInt32? = nil, mtimeMs: Double? = nil) -> Seed {
            Seed(kind: .symlink, mode: mode, mtimeMs: mtimeMs, target: target)
        }
    }

    // In the order they were made, as a JavaScript Map keeps them.
    private var keys: [String] = []
    private var nodes: [NameKeys.Exact: Node] = [:]
    private var nextIno: UInt64 = 10
    private var nextMtimeMs: Double = 1_000
    private let counts = OSAllocatedUnfairLock(initialState: 0)

    var caseSensitive = false
    var readlinkImpl: ((String) throws -> String)?

    /// How many times `lstat` was called.
    var lstatCount: Int { counts.withLock { $0 } }

    init(_ seed: [(String, Seed)] = []) {
        addDirectory("/")
        for (path, node) in seed {
            add(path, node)
        }
    }

    func addDirectory(_ path: String, ino: UInt64? = nil, dev: Int64? = nil) {
        let normalized = Self.normalize(path)
        if normalized != "/" {
            let parent = NodePath.dirname(normalized)
            if node(at: parent) == nil {
                addDirectory(parent)
            }
        }
        if node(at: normalized) != nil { return }
        insert(normalized, Seed.directory(ino: ino, dev: dev))
    }

    func addFile(_ path: String) {
        add(path, .file())
    }

    func add(_ path: String, _ seed: Seed) {
        if seed.kind == .directory {
            addDirectory(path, ino: seed.ino, dev: seed.dev)
            return
        }
        let normalized = Self.normalize(path)
        addDirectory(NodePath.dirname(normalized))
        insert(normalized, seed)
    }

    func delete(_ path: String) {
        let key = existingKey(path)
        nodes[NameKeys.Exact(key)] = nil
        keys.removeAll { sameText($0, key) }
    }

    private func insert(_ path: String, _ seed: Seed) {
        let key = newKey(path)
        nextMtimeMs += 1
        let mtime = seed.mtimeMs ?? nextMtimeMs
        let ino = seed.ino ?? nextIno
        if seed.ino == nil {
            nextIno += 1
        }
        let mode = seed.mode ?? (seed.kind == .directory ? 0o755 : seed.kind == .file ? 0o644 : 0o777)
        let dev = seed.dev ?? folderDev(key) ?? 1
        let node = Node(
            kind: seed.kind, size: seed.kind == .file ? seed.size ?? 0 : 0, mode: mode, mtimeMs: mtime, ino: ino,
            dev: dev, target: seed.target)
        if nodes[NameKeys.Exact(key)] == nil {
            keys.append(key)
        }
        nodes[NameKeys.Exact(key)] = node
    }

    private func folderDev(_ path: String) -> Int64? {
        guard path != "/" else { return nil }
        return node(at: NodePath.dirname(path))?.dev
    }

    private func node(at path: String) -> Node? {
        nodes[NameKeys.Exact(existingKey(path))]
    }

    private static func normalize(_ path: String) -> String {
        if path == "/" { return path }
        var scalars = Array(path.unicodeScalars)
        while scalars.last == "/" {
            scalars.removeLast()
        }
        return scalars.isEmpty ? "/" : String(String.UnicodeScalarView(scalars))
    }

    private func fold(_ path: String) -> String {
        caseSensitive ? path.decomposedStringWithCanonicalMapping : NameKeys.placeKey(path)
    }

    private func existingKey(_ path: String) -> String {
        let normalized = Self.normalize(path)
        if nodes[NameKeys.Exact(normalized)] != nil {
            return normalized
        }
        let folded = fold(normalized)
        if let found = keys.first(where: { sameText(fold($0), folded) }) {
            return found
        }
        return newKey(normalized)
    }

    private func newKey(_ path: String) -> String {
        let normalized = Self.normalize(path)
        if normalized == "/" { return normalized }
        let parent = NodePath.dirname(normalized)
        let parentKey = parent == "/" ? "/" : existingKey(parent)
        return (parentKey == "/" ? "" : parentKey) + "/" + NodePath.basename(normalized)
    }

    private func nodeOrThrow(_ path: String) throws -> Node {
        guard let node = node(at: path) else {
            throw NativeError(message: "ENOENT: \(existingKey(path))", code: "ENOENT", path: existingKey(path))
        }
        return node
    }

    private static func stats(_ node: Node) -> WriteServiceStats {
        let type: WriteServiceStats.FileType =
            switch node.kind {
            case .file: .file
            case .directory: .directory
            case .symlink: .symlink
            }
        return WriteServiceStats(
            type: type, size: node.size, mode: node.mode, mtimeMs: node.mtimeMs, ino: node.ino, dev: node.dev)
    }

    func lstat(_ path: String) throws -> WriteServiceStats {
        counts.withLock { $0 += 1 }
        return Self.stats(try nodeOrThrow(path))
    }

    func stat(_ path: String) throws -> WriteServiceStats {
        let node = try nodeOrThrow(path)
        if node.kind == .symlink {
            guard let target = node.target else {
                throw NativeError(message: "ENOENT: \(path)", code: "ENOENT", path: path)
            }
            return Self.stats(try nodeOrThrow(target))
        }
        return Self.stats(node)
    }

    func realpath(_ path: String) throws -> String {
        _ = try nodeOrThrow(path)
        return existingKey(path)
    }

    func readdir(_ path: String) throws -> [String] {
        let node = try nodeOrThrow(path)
        guard node.kind == .directory else {
            throw NativeError(message: "ENOTDIR: \(path)", code: "ENOTDIR", path: path)
        }
        let key = existingKey(path)
        let prefix = key == "/" ? "/" : key + "/"
        var children: [String] = []
        for candidate in keys where !sameText(candidate, key) && startsWith(candidate, prefix) {
            let rest = String(candidate.unicodeScalars.dropFirst(prefix.unicodeScalars.count))
            if let child = rest.split(separator: "/").first.map(String.init),
                !children.contains(where: { sameText($0, child) })
            {
                children.append(child)
            }
        }
        return children.sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }
    }

    func readlink(_ path: String) throws -> String {
        if let readlinkImpl {
            return try readlinkImpl(path)
        }
        let node = try nodeOrThrow(path)
        guard node.kind == .symlink, let target = node.target else {
            throw NativeError(message: "EINVAL: \(path)", code: "EINVAL", path: path)
        }
        return target
    }
}
