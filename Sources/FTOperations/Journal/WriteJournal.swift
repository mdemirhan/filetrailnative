// Port of the journal types of packages/core/src/fs/writeServiceTypes.ts (ReplaceJournalEntry, PartialFileJournalEntry,
// BatchRenameJournalEntry, WriteJournal, isReplaceJournalEntry)
import Foundation

/// A Replace in progress: the new item is built under `stagingPath`, a hidden name next to `finalPath`, then
/// swapped in. A folder copied (or moved to another disk) whole is written down the same way. `moved` means the
/// source itself was moved there (a move on the same volume), so the staged item is the only copy of it.
/// `staged` means the item at `stagingPath` is complete. What is at `stagingPath`, a random hidden name made for
/// it, is the paste's own. (Entries written by v0.4.3 carry ids as well, no longer read.)
public struct ReplaceJournalEntry: Equatable, Sendable {
    /// Entries written before the journal held anything else have no kind, and neither do the folder copies a
    /// paste writes down.
    public var hasKind: Bool
    public var id: String
    public var stagingPath: String
    public var finalPath: String
    public var sourcePath: String
    public var moved: Bool
    public var staged: Bool
    /// A move to another disk (a folder copied, then its original removed): put in place by recovery, its
    /// original is still there too, and the person is told.
    public var movingCopy: Bool

    public init(
        hasKind: Bool = false, id: String, stagingPath: String, finalPath: String, sourcePath: String, moved: Bool,
        staged: Bool, movingCopy: Bool = false
    ) {
        self.hasKind = hasKind
        self.id = id
        self.stagingPath = stagingPath
        self.finalPath = finalPath
        self.sourcePath = sourcePath
        self.moved = moved
        self.staged = staged
        self.movingCopy = movingCopy
    }
}

/// A large file being copied under `partialPath`, a hidden name of its own next to `finalPath`, until it is
/// complete. Cut short, it is only part of a copy (the original is where it was): the next start removes it,
/// so it doesn't take up space unseen.
public struct PartialFileJournalEntry: Equatable, Sendable {
    public var id: String
    public var partialPath: String
    public var finalPath: String

    public init(id: String, partialPath: String, finalPath: String) {
        self.id = id
        self.partialPath = partialPath
        self.finalPath = finalPath
    }
}

/// Items a rename of several moved aside under hidden names (`temporaryPath`) so others could take their names:
/// written down before the first moves, for one folder depth at a time. A crash leaves each where the next start
/// finds it: under its old name, its new one, or its old one with a number.
public struct BatchRenameJournalEntry: Equatable, Sendable {
    public struct Item: Equatable, Sendable {
        public var temporaryPath: String
        public var originalPath: String
        public var newPath: String

        public init(temporaryPath: String, originalPath: String, newPath: String) {
            self.temporaryPath = temporaryPath
            self.originalPath = originalPath
            self.newPath = newPath
        }
    }

    public var id: String
    public var items: [Item]

    public init(id: String, items: [Item]) {
        self.id = id
        self.items = items
    }
}

public enum WriteJournalEntry: Equatable, Sendable {
    case replace(ReplaceJournalEntry)
    case partialFile(PartialFileJournalEntry)
    case batchRename(BatchRenameJournalEntry)

    public var id: String {
        switch self {
        case .replace(let entry): entry.id
        case .partialFile(let entry): entry.id
        case .batchRename(let entry): entry.id
        }
    }

    /// `isReplaceJournalEntry`.
    public var isReplace: Bool {
        if case .replace = self { return true }
        return false
    }
}

/// Where writes that leave items under hidden names while they run are written down, so a crash can't strand
/// one there: the next start finishes or undoes each. `add` replaces an entry with the same id. Each write must
/// be in the file, whole, before it returns, so it outlasts a crash or force quit (a power cut may still lose
/// the latest ones).
public protocol WriteJournal: Sendable {
    func add(_ entry: WriteJournalEntry) throws
    func remove(_ id: String) throws
}

// MARK: JSON, as the original writes it

extension WriteJournalEntry {
    /// The entry as `JSON.stringify` writes it: its keys in the original's order, optional ones left out.
    var jsonObject: [(String, Any)] {
        switch self {
        case .replace(let entry):
            var object: [(String, Any)] = []
            if entry.hasKind {
                object.append(("kind", "replace"))
            }
            object += [
                ("id", entry.id), ("stagingPath", entry.stagingPath), ("finalPath", entry.finalPath),
                ("sourcePath", entry.sourcePath), ("moved", entry.moved), ("staged", entry.staged),
            ]
            if entry.movingCopy {
                object.append(("movingCopy", true))
            }
            return object
        case .partialFile(let entry):
            return [
                ("kind", "partial_file"), ("id", entry.id), ("partialPath", entry.partialPath),
                ("finalPath", entry.finalPath),
            ]
        case .batchRename(let entry):
            return [
                ("kind", "batch_rename"), ("id", entry.id),
                (
                    "items",
                    entry.items.map { item -> [(String, Any)] in
                        [
                            ("temporaryPath", item.temporaryPath), ("originalPath", item.originalPath),
                            ("newPath", item.newPath),
                        ]
                    }
                ),
            ]
        }
    }

    /// `isEntry`: an entry read back from the file, or nil for anything that isn't one.
    init?(json value: Any) {
        guard let entry = value as? [String: Any], let id = entry["id"] as? String else { return nil }
        let kind = entry["kind"]
        if let kind = kind as? String, kind == "batch_rename" {
            guard let items = entry["items"] as? [Any] else { return nil }
            var parsed: [BatchRenameJournalEntry.Item] = []
            for item in items {
                guard let item = item as? [String: Any], let temporaryPath = item["temporaryPath"] as? String,
                    let originalPath = item["originalPath"] as? String, let newPath = item["newPath"] as? String
                else { return nil }
                parsed.append(.init(temporaryPath: temporaryPath, originalPath: originalPath, newPath: newPath))
            }
            self = .batchRename(BatchRenameJournalEntry(id: id, items: parsed))
            return
        }
        guard let finalPath = entry["finalPath"] as? String else { return nil }
        if let kind = kind as? String, kind == "partial_file" {
            guard let partialPath = entry["partialPath"] as? String else { return nil }
            self = .partialFile(PartialFileJournalEntry(id: id, partialPath: partialPath, finalPath: finalPath))
            return
        }
        let hasKind = kind != nil
        if hasKind && (kind as? String) != "replace" {
            return nil
        }
        guard let stagingPath = entry["stagingPath"] as? String, let sourcePath = entry["sourcePath"] as? String,
            let moved = Self.bool(entry["moved"]), let staged = Self.bool(entry["staged"])
        else { return nil }
        self = .replace(
            ReplaceJournalEntry(
                hasKind: hasKind, id: id, stagingPath: stagingPath, finalPath: finalPath, sourcePath: sourcePath,
                moved: moved, staged: staged, movingCopy: Self.bool(entry["movingCopy"]) == true))
    }

    /// A JSON boolean: `typeof value === "boolean"`, which a number never is.
    private static func bool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
}
