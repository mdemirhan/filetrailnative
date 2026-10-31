// Port of apps/desktop/src/main/bootstrap/batchRenameMemoryDisk.testkit.ts (and the MemoryDisk of
// batchRenameExecution.test.ts)
import FTFoundation
import Foundation
import os

@testable import FTOperations

/// An error with a code, as Node's fs gives them.
func errno(_ code: String) -> OperationError {
    OperationError("\(code): test", code: code)
}

/// What a rename call was: "rename" or "renameExclusive", from and to.
struct MemoryDiskCall: Sendable {
    var op: String
    var from: String
    var to: String
}

/// An in-memory folder tree that compares names as a disk does (ignoring case unless told otherwise, and accent
/// encoding always), refuses to replace with an exclusive rename, and fails on demand. Every item has an ino of its
/// own, which moves with it; a folder's items move along with it. Paths compare scalar for scalar, as JavaScript's
/// do.
final class MemoryDisk: BatchRenameFileSystem, @unchecked Sendable {
    enum Listing {
        case normal
        /// The disk has no `readdir`.
        case none
        case failing(any Error)
    }

    enum CaseAnswer {
        /// The disk has no `isCaseSensitive`.
        case none
        case answer(Bool?)
        case failing(any Error)
    }

    private struct Entry {
        var name: String
        var ino: Int
    }

    private struct Folder {
        var path: String
        var entries: [[UInt8]: Entry] = [:]
    }

    private let lock = NSRecursiveLock()
    private var folders: [[UInt8]: Folder] = [:]
    private var nextIno = 10
    let caseSensitive: Bool
    private(set) var calls: [String] = []
    private(set) var readdirCalls: [String] = []
    private(set) var caseCalls: [String] = []
    /// "rename:/from->/to" or "renameExclusive:/from->/to", or "lstat:/path": the error to fail with.
    var failures: [String: any Error] = [:]
    var lockedPaths: Set<String> = []
    /// Paths lstat finds as folders, outside the tree (`withFolders`).
    var folderPaths: Set<String> = []
    var listing: Listing = .normal
    var caseAnswer: CaseAnswer = .none
    /// Asked before every rename: an error to fail it with, or nil to let it go ahead.
    var failWith: (MemoryDiskCall) -> (any Error)? = { _ in nil }
    /// Told after every rename that went ahead.
    var afterMove: (MemoryDiskCall) -> Void = { _ in }
    /// Stands in for the exclusive rename, given the disk's own (a test's `disk.renameExclusive = …`).
    var renameExclusiveOverride: ((String, String, (String, String) throws -> Void) throws -> Void)?

    init(_ files: [String], caseSensitive: Bool = false) {
        self.caseSensitive = caseSensitive
        for path in files {
            add(path)
        }
    }

    @discardableResult
    func add(_ path: String) -> Int {
        locked {
            let (folder, name) = split(path)
            var entries = folders[bytes(folder)] ?? Folder(path: folder)
            let ino = nextIno
            nextIno += 1
            entries.entries[key(name)] = Entry(name: name, ino: ino)
            folders[bytes(folder)] = entries
            return ino
        }
    }

    /// The names in a folder, sorted as JavaScript sorts them.
    func names(_ folder: String = "/trip") -> [String] {
        locked {
            (folders[bytes(folder)]?.entries.values.map(\.name) ?? []).sorted(by: jsLess)
        }
    }

    /// Every item on the disk, by path.
    func entries() -> [(path: String, ino: Int)] {
        locked {
            var all: [(path: String, ino: Int)] = []
            for folder in folders.values {
                for entry in folder.entries.values {
                    all.append((folder.path == "/" ? "/\(entry.name)" : "\(folder.path)/\(entry.name)", entry.ino))
                }
            }
            return all.sorted { jsLess($0.path, $1.path) }
        }
    }

    /// Where the item is now, or nil when it is nowhere.
    func pathOf(_ ino: Int) -> String? {
        entries().first { $0.ino == ino }?.path
    }

    func inoOf(_ path: String) -> Int? {
        locked { find(path)?.ino }
    }

    private func key(_ name: String) -> [UInt8] {
        let normalized = name.decomposedStringWithCanonicalMapping
        return bytes(caseSensitive ? normalized : normalized.lowercased(with: nil))
    }

    private func find(_ path: String) -> Entry? {
        let (folder, name) = split(path)
        return folders[bytes(folder)]?.entries[key(name)]
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    // MARK: BatchRenameFileSystem

    func lstat(_ path: String) throws -> WriteServiceStats {
        try locked {
            calls.append("lstat:\(path)")
            if let failure = failures["lstat:\(path)"] {
                throw failure
            }
            if folderPaths.contains(where: { sameText($0, path) }) {
                return WriteServiceStats(type: .directory, ino: 1, dev: 1)
            }
            guard let entry = find(path) else { throw errno("ENOENT") }
            return WriteServiceStats(type: .file, ino: UInt64(entry.ino), dev: 1)
        }
    }

    var readFolder: ((String) throws -> [String])? {
        switch listing {
        case .none: return nil
        case .failing(let error):
            return { [self] folder in
                locked { readdirCalls.append(folder) }
                throw error
            }
        case .normal:
            return { [self] folder in
                locked { readdirCalls.append(folder) }
                return names(folder)
            }
        }
    }

    var readFlags: ((String) throws -> UInt32)? {
        { [self] path in locked { lockedPaths.contains(path) ? 0x2 : 0 } }
    }

    var caseSensitivity: ((String) throws -> Bool?)? {
        switch caseAnswer {
        case .none: return nil
        case .answer(let answer):
            return { [self] folder in
                locked { caseCalls.append(folder) }
                return answer
            }
        case .failing(let error):
            return { [self] folder in
                locked { caseCalls.append(folder) }
                throw error
            }
        }
    }

    func renameExclusive(_ from: String, _ to: String) throws {
        if let renameExclusiveOverride {
            try renameExclusiveOverride(from, to) { try self.diskRenameExclusive($0, $1) }
        } else {
            try diskRenameExclusive(from, to)
        }
    }

    private func diskRenameExclusive(_ from: String, _ to: String) throws {
        let call = MemoryDiskCall(op: "renameExclusive", from: from, to: to)
        try locked {
            calls.append("renameExclusive:\(from)->\(to)")
            if let failure = failures["renameExclusive:\(from)->\(to)"] ?? failWith(call) {
                throw failure
            }
            guard find(from) != nil else { throw errno("ENOENT") }
            if find(to) != nil {
                throw errno("EEXIST")
            }
            move(from, to)
        }
        afterMove(call)
    }

    func rename(_ from: String, _ to: String) throws {
        let call = MemoryDiskCall(op: "rename", from: from, to: to)
        try locked {
            calls.append("rename:\(from)->\(to)")
            if let failure = failures["rename:\(from)->\(to)"] ?? failWith(call) {
                throw failure
            }
            guard find(from) != nil else { throw errno("ENOENT") }
            move(from, to)
        }
        afterMove(call)
    }

    private func move(_ from: String, _ to: String) {
        let source = split(from)
        let destination = split(to)
        let entry = find(from)
        folders[bytes(source.folder)]?.entries[key(source.name)] = nil
        var entries = folders[bytes(destination.folder)] ?? Folder(path: destination.folder)
        // A plain rename replaces what is there, as rename(2) does: its ino is lost.
        entries.entries[key(destination.name)] = Entry(name: destination.name, ino: entry?.ino ?? 0)
        folders[bytes(destination.folder)] = entries
        // A folder takes what is inside it along.
        for (pathKey, folder) in folders where sameText(folder.path, from) || startsWith(folder.path, from + "/") {
            folders[pathKey] = nil
            let rest = String(String.UnicodeScalarView(folder.path.unicodeScalars.dropFirst(from.unicodeScalars.count)))
            var moved = folder
            moved.path = to + rest
            folders[bytes(moved.path)] = moved
        }
    }
}

func split(_ path: String) -> (folder: String, name: String) {
    let scalars = Array(path.unicodeScalars)
    let slash = scalars.lastIndex(of: "/") ?? -1
    let folder = slash <= 0 ? "/" : String(String.UnicodeScalarView(scalars[..<slash]))
    return (folder, String(String.UnicodeScalarView(scalars[(slash + 1)...])))
}

private func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

/// JavaScript's default sort order: UTF-16 code units.
func jsLess(_ left: String, _ right: String) -> Bool {
    left.utf16.lexicographicallyPrecedes(right.utf16)
}

/// A journal that keeps what is written down in memory, and can fail.
final class RenameJournal: WriteJournal, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var added: [BatchRenameJournalEntry] = []
    private(set) var live: [String: BatchRenameJournalEntry] = [:]
    private(set) var liveOrder: [String] = []
    var addFailure: (any Error)?
    /// Told of every entry written, before it is kept.
    var onAdd: (BatchRenameJournalEntry) -> Void = { _ in }

    func add(_ entry: WriteJournalEntry) throws {
        guard case .batchRename(let rename) = entry else { return }
        if let addFailure { throw addFailure }
        onAdd(rename)
        lock.withLock {
            added.append(rename)
            if live[rename.id] == nil { liveOrder.append(rename.id) }
            live[rename.id] = rename
        }
    }

    func remove(_ id: String) throws {
        lock.withLock {
            live[id] = nil
            liveOrder.removeAll { $0 == id }
        }
    }

    var liveEntries: [BatchRenameJournalEntry] {
        lock.withLock { liveOrder.compactMap { live[$0] } }
    }
}

/// mulberry32, as the original's tests draw their random cases: the same numbers for the same seed.
struct Mulberry32 {
    private var state: UInt32

    init(seed: UInt32) {
        state = seed
    }

    mutating func next() -> Double {
        state = state &+ 0x6D2B_79F5
        var value = state
        value = (value ^ (value >> 15)) &* (value | 1)
        value ^= value &+ ((value ^ (value >> 7)) &* (value | 61))
        return Double(value ^ (value >> 14)) / 4_294_967_296
    }

    mutating func chance(_ probability: Double) -> Bool { next() < probability }

    mutating func integer(_ least: Int, _ most: Int) -> Int {
        least + Int((next() * Double(most - least + 1)).rounded(.down))
    }

    mutating func pick<T>(_ choices: [T]) -> T { choices[integer(0, choices.count - 1)] }

    mutating func shuffle<T>(_ items: [T]) -> [T] {
        var shuffled = items
        var index = shuffled.count - 1
        while index > 0 {
            let other = integer(0, index)
            shuffled.swapAt(index, other)
            index -= 1
        }
        return shuffled
    }
}
