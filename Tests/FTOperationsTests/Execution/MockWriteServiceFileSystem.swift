// Port of MockWriteServiceFileSystem and snapshotMockFileSystem (packages/core/src/fs/testUtils.ts)
import FTFoundation
import Foundation

@testable import FTOperations

/// Items in memory, looked up as APFS compares names (ignoring how accented letters are encoded, and letter case
/// unless `caseSensitive`), with the hooks the tests replace calls with.
final class MockWriteServiceFileSystem: WriteServiceFileSystem, @unchecked Sendable {
    enum Kind: Equatable { case file, directory, symlink }

    /// One item. A class, so its flags go with it through renames, as the original keeps them by node.
    final class Node {
        var kind: Kind
        var size: Int64
        var mode: UInt32
        var mtimeMs: Double
        var ino: UInt64
        var dev: Int64
        var target: String?
        var flags: UInt32 = 0

        init(kind: Kind, size: Int64, mode: UInt32, mtimeMs: Double, ino: UInt64, dev: Int64, target: String?) {
            self.kind = kind
            self.size = size
            self.mode = mode
            self.mtimeMs = mtimeMs
            self.ino = ino
            self.dev = dev
            self.target = target
        }

        func copy() -> Node {
            let node = Node(kind: kind, size: size, mode: mode, mtimeMs: mtimeMs, ino: ino, dev: dev, target: target)
            node.flags = flags
            return node
        }
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
        ) -> Seed {
            Seed(kind: .file, size: size, mode: mode, mtimeMs: mtimeMs, ino: ino, dev: dev)
        }

        static func directory(mode: UInt32? = nil, mtimeMs: Double? = nil, ino: UInt64? = nil, dev: Int64? = nil)
            -> Seed
        {
            Seed(kind: .directory, mode: mode, mtimeMs: mtimeMs, ino: ino, dev: dev)
        }

        static func symlink(
            _ target: String, mode: UInt32? = nil, mtimeMs: Double? = nil, ino: UInt64? = nil, dev: Int64? = nil
        ) -> Seed {
            Seed(kind: .symlink, mode: mode, mtimeMs: mtimeMs, ino: ino, dev: dev, target: target)
        }
    }

    private let lock = NSRecursiveLock()
    // The items by path, in the order they were made, as a JavaScript Map keeps them.
    private var order: [String?] = []
    private var positions: [NameKeys.Exact: Int] = [:]
    private var table: [NameKeys.Exact: Node] = [:]
    private var nextIno: UInt64 = 10
    private var nextMtimeMs: Double = 1_000

    var realpathOverrides: [String: String] = [:]
    var copyFileImpl: ((String, String, StopSignal?, (@Sendable (Int64) -> Void)?) throws -> Void)?
    var utimesImpl: ((String, Double, Double) throws -> Void)?
    var chmodImpl: ((String, UInt32) throws -> Void)?
    /// Every rename goes through it, the exclusive ones included (see renameExclusive).
    var renameImpl: ((String, String) throws -> Void)?
    var mkdirImpl: ((String) throws -> Void)?
    var rmImpl: ((String, Bool, Bool) throws -> Void)?
    var rmdirImpl: ((String) throws -> Void)?
    var readlinkImpl: ((String) throws -> String)?
    var lstatImpl: ((String) throws -> WriteServiceStats)?
    var statImpl: ((String) throws -> WriteServiceStats)?
    var readdirImpl: ((String) throws -> [String])?
    var realpathImpl: ((String) throws -> String)?
    var trashImpl: ((String) throws -> String?)?
    var getFlagsImpl: ((String) throws -> UInt32)?
    var setFlagsImpl: ((String, UInt32) throws -> Void)?
    var isPackageImpl: ((String) throws -> Bool?)?
    var isAppleDoubleImpl: ((String) -> Bool)?
    /// The calls the original's tests add to the mock as they need them.
    var canModifyFolderImpl: ((String) throws -> Void)?
    var copyMetadataImpl: ((String, String) throws -> Void)?
    var setAclImpl: ((String, String?) throws -> Void)?
    /// The macOS default; tests of case-sensitive volumes set this to true.
    var caseSensitive = false
    /// How the volume takes two names for one, when not as APFS does.
    var foldImpl: ((String) -> String)?
    private(set) var trashEnabled = false
    private(set) var utimesEnabled = false
    /// What went to the Trash, each said to be at "/.Trash/<n>-<name>" (nothing is kept there).
    private(set) var trashed: [String] = []

    init(_ seed: [(String, Seed)] = []) {
        addDirectory("/")
        for (path, node) in seed {
            switch node.kind {
            case .directory: addDirectory(path, node)
            case .file: addFile(path, node)
            case .symlink: addSymlink(path, node.target ?? "", node)
            }
        }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    // MARK: The ordered map

    /// The paths of every item, in the order they were made.
    var paths: [String] { locked { order.compactMap { $0 } } }

    private func get(_ key: String) -> Node? { table[NameKeys.Exact(key)] }

    private func set(_ key: String, _ node: Node) {
        let exact = NameKeys.Exact(key)
        if positions[exact] == nil {
            positions[exact] = order.count
            order.append(key)
        }
        table[exact] = node
    }

    private func delete(_ key: String) {
        let exact = NameKeys.Exact(key)
        guard let position = positions.removeValue(forKey: exact) else { return }
        order[position] = nil
        table[exact] = nil
    }

    private func has(_ key: String) -> Bool { table[NameKeys.Exact(key)] != nil }

    // MARK: The calls

    func lstat(_ path: String) throws -> WriteServiceStats {
        if let lstatImpl { return try lstatImpl(path) }
        return try lstatDirectly(path)
    }

    /// `lstat` as the mock does it, for an `lstatImpl` that changes only some looks.
    func lstatDirectly(_ path: String) throws -> WriteServiceStats {
        try locked { Self.stats(try nodeOrThrow(path)) }
    }

    /// `readdir` as the mock does it.
    func readdirDirectly(_ path: String) throws -> [String] {
        try locked {
            let node = try nodeOrThrow(path)
            guard node.kind == .directory else { throw Self.error("ENOTDIR", path) }
            return listChildren(path)
        }
    }

    func stat(_ path: String) throws -> WriteServiceStats {
        if let statImpl { return try statImpl(path) }
        return try locked {
            let node = try nodeOrThrow(path)
            if node.kind == .symlink {
                guard let target = node.target, !target.isEmpty else { throw Self.error("ENOENT", path) }
                return Self.stats(try nodeOrThrow(target))
            }
            return Self.stats(node)
        }
    }

    func realpath(_ path: String) throws -> String {
        if let realpathImpl { return try realpathImpl(path) }
        return try locked {
            if let override = realpathOverrides[path] {
                return override
            }
            _ = try nodeOrThrow(path)
            // As macOS does, with the names as they are stored.
            return existingKey(path)
        }
    }

    func readdir(_ path: String) throws -> [String] {
        if let readdirImpl { return try readdirImpl(path) }
        return try locked {
            let node = try nodeOrThrow(path)
            guard node.kind == .directory else { throw Self.error("ENOTDIR", path) }
            return listChildren(path)
        }
    }

    func readlink(_ path: String) throws -> String {
        if let readlinkImpl { return try readlinkImpl(path) }
        return try locked {
            let node = try nodeOrThrow(path)
            guard node.kind == .symlink, let target = node.target else { throw Self.error("EINVAL", path) }
            return target
        }
    }

    func isCaseSensitive(_ path: String) throws -> Bool? { caseSensitive }

    func isPackage(_ path: String) throws -> Bool? {
        try isPackageImpl?(path) ?? nil
    }

    func isAppleDouble(_ path: String) -> Bool {
        isAppleDoubleImpl?(path) ?? false
    }

    var chmod: ((String, UInt32) throws -> Void)? {
        { [self] path, mode in
            if let chmodImpl { return try chmodImpl(path, mode) }
            try locked {
                let node = try nodeOrThrow(path)
                node.mode = mode
                node.mtimeMs = bumpMtime()
            }
        }
    }

    func mkdir(_ path: String) throws {
        if let mkdirImpl { return try mkdirImpl(path) }
        try locked { try ensureDirectory(path, recursive: false) }
    }

    func mkdirRecursive(_ path: String) throws {
        try locked { try ensureDirectory(path, recursive: true) }
    }

    func rm(_ path: String, recursive: Bool, force: Bool) throws {
        if let rmImpl { return try rmImpl(path, recursive, force) }
        try removeDirectly(path, recursive: recursive, force: force)
    }

    /// `rm` as the mock does it, for an `rmImpl` that changes only some removals.
    func removeDirectly(_ path: String, recursive: Bool, force: Bool) throws {
        try locked {
            let key = existingKey(path)
            guard has(key) else {
                if force { return }
                throw Self.error("ENOENT", path)
            }
            let node = try nodeOrThrow(key)
            if node.kind == .directory {
                if !listChildren(key).isEmpty && !recursive {
                    throw Self.error("ENOTEMPTY", path)
                }
                deleteTree(key)
                return
            }
            delete(key)
        }
    }

    func rmdir(_ path: String) throws {
        if let rmdirImpl { return try rmdirImpl(path) }
        try locked {
            let node = try nodeOrThrow(path)
            guard node.kind == .directory else { throw Self.error("ENOTDIR", path) }
            if !listChildren(path).isEmpty {
                throw Self.error("ENOTEMPTY", path)
            }
            delete(existingKey(path))
        }
    }

    /// Enables `trash`: trashed items are kept in `trashed`, and each is said to be at "/.Trash/<n>-<name>".
    func enableTrash() {
        trashEnabled = true
    }

    var trash: ((String) throws -> String?)? {
        guard trashEnabled else { return nil }
        return { [self] path in
            if let trashImpl { return try trashImpl(path) }
            return try locked {
                _ = try nodeOrThrow(path)
                let key = existingKey(path)
                deleteTree(key)
                trashed.append(key)
                return "/.Trash/\(trashed.count)-\(NodePath.basename(key))"
            }
        }
    }

    /// rename(2): replaces what is at `newPath`. Through `renameImpl` when set.
    func rename(_ oldPath: String, _ newPath: String) throws {
        if let renameImpl { return try renameImpl(oldPath, newPath) }
        try renameDirectly(oldPath, newPath)
    }

    /// Fails with EEXIST when another item is at `newPath`, else renames (see `rename`).
    func renameExclusive(_ oldPath: String, _ newPath: String) throws {
        try locked {
            if let there = get(existingKey(newPath)), there !== get(existingKey(oldPath)) {
                throw Self.error("EEXIST", newPath)
            }
        }
        try rename(oldPath, newPath)
    }

    func getFlags(_ path: String) throws -> UInt32 {
        if let getFlagsImpl { return try getFlagsImpl(path) }
        return try locked { try nodeOrThrow(path).flags }
    }

    func setFlags(_ path: String, _ flags: UInt32) throws {
        if let setFlagsImpl { return try setFlagsImpl(path, flags) }
        try locked { try nodeOrThrow(path).flags = flags }
    }

    var canModifyFolder: ((String) throws -> Void)? { canModifyFolderImpl }
    var copyMetadata: ((String, String) throws -> Void)? { copyMetadataImpl }
    var setAcl: ((String, String?) throws -> Void)? { setAclImpl }

    /// rename(2) as the mock does it, for a `renameImpl` that changes only some renames.
    func renameDirectly(_ oldPath: String, _ newPath: String) throws {
        try locked {
            let normalizedOld = existingKey(oldPath)
            let normalizedNew = newKey(newPath)
            let sourceNode = try nodeOrThrow(normalizedOld)
            // Across devices: the source's against the destination folder's.
            let parentNode = try nodeOrThrow(NodePath.dirname(normalizedNew))
            if sourceNode.dev != parentNode.dev {
                throw Self.error("EXDEV", normalizedOld)
            }
            let moving = order.compactMap { $0 }.filter { isAtOrUnder($0, normalizedOld) }.map { ($0, get($0)) }
            for (path, _) in moving {
                delete(path)
            }
            // rename(2) replaces what was at the new name (stored, perhaps, in another case).
            let replacedKey = existingKey(newPath)
            for path in order.compactMap({ $0 }) where isAtOrUnder(path, replacedKey) {
                delete(path)
            }
            for (path, node) in moving {
                guard let node else { continue }
                let rest = String(
                    String.UnicodeScalarView(path.unicodeScalars.dropFirst(normalizedOld.unicodeScalars.count)))
                set(sameText(path, normalizedOld) ? normalizedNew : normalizedNew + rest, node)
            }
        }
    }

    /// copyfile(3): a file, or a link as a link, with its mode and date; never replaces an item at
    /// `destinationPath`. Through `copyFileImpl` when set.
    func copyFile(
        _ source: String, _ destination: String, stop: StopSignal?, onProgress: (@Sendable (Int64) -> Void)?
    ) throws {
        if let copyFileImpl { return try copyFileImpl(source, destination, stop, onProgress) }
        try copyDirectly(source, destination, stop: stop)
    }

    /// `copyFile` as the mock does it.
    func copyDirectly(_ sourcePath: String, _ destinationPath: String, stop: StopSignal? = nil) throws {
        try stop?.throwIfStopped()
        try locked {
            let source = try nodeOrThrow(sourcePath)
            if source.kind == .directory {
                throw Self.error("EISDIR", sourcePath)
            }
            try ensureDirectory(NodePath.dirname(destinationPath), recursive: true)
            if has(existingKey(destinationPath)) {
                throw Self.error("EEXIST", destinationPath)
            }
            set(
                newKey(destinationPath),
                createNode(
                    at: destinationPath, kind: source.kind, size: source.size, mode: source.mode,
                    mtimeMs: source.mtimeMs, target: source.target))
        }
    }

    /// Enables `utimes`, opting this mock into timestamp preservation.
    func enableUtimes() {
        utimesEnabled = true
    }

    var utimes: ((String, Double, Double) throws -> Void)? {
        guard utimesEnabled else { return nil }
        return { [self] path, atimeMs, mtimeMs in
            if let utimesImpl { return try utimesImpl(path, atimeMs, mtimeMs) }
            try locked { try nodeOrThrow(path).mtimeMs = mtimeMs }
        }
    }

    // MARK: Building and reading the tree

    func addDirectory(_ path: String, _ options: Seed = .directory()) {
        locked { try? ensureDirectory(path, recursive: true, options: options) }
    }

    func addFile(_ path: String, _ options: Seed = .file()) {
        locked {
            try? ensureDirectory(NodePath.dirname(path), recursive: true)
            set(
                newKey(path),
                createNode(
                    at: path, kind: .file, size: options.size, mode: options.mode, mtimeMs: options.mtimeMs,
                    ino: options.ino, dev: options.dev))
        }
    }

    func addSymlink(_ path: String, _ target: String, _ options: Seed = .symlink("")) {
        locked {
            try? ensureDirectory(NodePath.dirname(path), recursive: true)
            set(
                newKey(path),
                createNode(
                    at: path, kind: .symlink, mode: options.mode, mtimeMs: options.mtimeMs, ino: options.ino,
                    dev: options.dev, target: target))
        }
    }

    /// Changes an item (a copy of it, as the original spreads it) and gives it a new date.
    func mutateNode(_ path: String, _ update: (Node) -> Void) {
        locked {
            let key = existingKey(path)
            guard let node = get(key) else { return }
            let next = node.copy()
            update(next)
            next.mtimeMs = bumpMtime()
            set(key, next)
        }
    }

    func setRealpath(_ path: String, _ realPath: String) {
        realpathOverrides[Self.normalize(path)] = Self.normalize(realPath)
    }

    func exists(_ path: String) -> Bool {
        locked { has(existingKey(path)) }
    }

    func readNode(_ path: String) -> Node? {
        locked { get(existingKey(path)) }
    }

    /// Drops an item (and what is in it) from the tree.
    func remove(_ path: String) {
        locked { deleteTree(existingKey(path)) }
    }

    /// `nodes.delete(path)`: drops that one entry, leaving what was stored under it.
    @discardableResult
    func deleteNode(_ path: String) -> Bool {
        locked {
            guard has(path) else { return false }
            delete(path)
            return true
        }
    }

    /// Hidden names a Replace or a folder copy builds the new item under.
    func temporaryLeftovers() -> [String] {
        paths.filter { $0.contains(".filetrail-") }
    }

    private func ensureDirectory(_ path: String, recursive: Bool, options: Seed = .directory()) throws {
        let normalized = Self.normalize(path)
        if normalized == "/" {
            if !has("/") {
                set(
                    "/",
                    createNode(
                        at: nil, kind: .directory, mode: options.mode, mtimeMs: options.mtimeMs, ino: options.ino,
                        dev: options.dev))
            }
            return
        }
        let parent = existingKey(NodePath.dirname(normalized))
        if !has(parent) {
            if !recursive {
                throw Self.error("ENOENT", parent)
            }
            try ensureDirectory(parent, recursive: true)
        }
        if let existing = get(existingKey(normalized)) {
            if existing.kind != .directory {
                throw Self.error(recursive ? "ENOTDIR" : "EEXIST", normalized)
            }
            if !recursive {
                throw Self.error("EEXIST", normalized)
            }
            return
        }
        set(
            newKey(normalized),
            createNode(
                at: normalized, kind: .directory, mode: options.mode, mtimeMs: options.mtimeMs, ino: options.ino,
                dev: options.dev))
    }

    private func listChildren(_ path: String) -> [String] {
        let normalized = existingKey(path)
        let prefix = normalized == "/" ? "/" : normalized + "/"
        var children: [String] = []
        var seen = Set<NameKeys.Exact>()
        for candidate in order.compactMap({ $0 })
        where !sameText(candidate, normalized) && startsWith(candidate, prefix) {
            let rest = String(String.UnicodeScalarView(candidate.unicodeScalars.dropFirst(prefix.unicodeScalars.count)))
            if let name = rest.split(separator: "/", omittingEmptySubsequences: false).first.map(String.init),
                !name.isEmpty, seen.insert(NameKeys.Exact(name)).inserted
            {
                children.append(name)
            }
        }
        // `Array.prototype.sort()`: by UTF-16 code unit.
        return children.sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }
    }

    private func isAtOrUnder(_ candidate: String, _ key: String) -> Bool {
        sameText(candidate, key) || startsWith(candidate, key + "/")
    }

    private func deleteTree(_ key: String) {
        for candidate in order.compactMap({ $0 }) where isAtOrUnder(candidate, key) {
            delete(candidate)
        }
    }

    private func createNode(
        at path: String?, kind: Kind, size: Int64? = nil, mode: UInt32? = nil, mtimeMs: Double? = nil,
        ino: UInt64? = nil, dev: Int64? = nil, target: String? = nil
    ) -> Node {
        let mtime = mtimeMs ?? bumpMtime()
        let id: UInt64
        if let ino {
            id = ino
        } else {
            id = nextIno
            nextIno += 1
        }
        return Node(
            kind: kind, size: kind == .file ? size ?? 0 : 0,
            mode: mode ?? (kind == .directory ? 0o755 : kind == .file ? 0o644 : 0o777), mtimeMs: mtime, ino: id,
            dev: dev ?? folderDev(path) ?? 1, target: target)
    }

    /// The key of the item at `path`, found the way the volume compares names. A path to nothing gets the key a
    /// new item there would have.
    private func existingKey(_ path: String) -> String {
        let normalized = Self.normalize(path)
        if has(normalized) {
            return normalized
        }
        let folded = fold(normalized)
        for candidate in order.compactMap({ $0 }) where sameText(fold(candidate), folded) {
            return candidate
        }
        return newKey(normalized)
    }

    /// A new item's key: its folder as already stored, and its own name as given.
    private func newKey(_ path: String) -> String {
        let normalized = Self.normalize(path)
        if normalized == "/" {
            return normalized
        }
        let parent = NodePath.dirname(normalized)
        let parentKey = parent == "/" ? "/" : existingKey(parent)
        return (parentKey == "/" ? "" : parentKey) + "/" + NodePath.basename(normalized)
    }

    private func fold(_ path: String) -> String {
        if let foldImpl { return foldImpl(path) }
        return caseSensitive ? path.decomposedStringWithCanonicalMapping : NameKeys.placeKey(path)
    }

    private func nodeOrThrow(_ path: String) throws -> Node {
        let normalized = existingKey(path)
        guard let node = get(normalized) else {
            throw Self.error("ENOENT", normalized)
        }
        return node
    }

    private func folderDev(_ path: String?) -> Int64? {
        guard let path, Self.normalize(path) != "/" else { return nil }
        return get(existingKey(NodePath.dirname(Self.normalize(path))))?.dev
    }

    private func bumpMtime() -> Double {
        nextMtimeMs += 1
        return nextMtimeMs
    }

    private static func normalize(_ path: String) -> String {
        if path == "/" { return path }
        var scalars = Array(path.unicodeScalars)
        while scalars.last == "/" {
            scalars.removeLast()
        }
        return scalars.isEmpty ? "/" : String(String.UnicodeScalarView(scalars))
    }

    static func error(_ code: String, _ path: String) -> NativeError {
        NativeError(message: "\(code): \(path)", code: code, path: path)
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
}
