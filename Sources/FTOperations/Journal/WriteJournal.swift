import Foundation

/// A Replace in progress: the new item is built under `stagingPath`, a hidden name next to `finalPath`, then
/// swapped in. A folder copied (or moved to another disk) whole is written down the same way. `moved` means the
/// source itself was moved there (a move on the same volume), so the staged item is the only copy of it.
/// `staged` means the item at `stagingPath` is complete. What is at `stagingPath`, a random hidden name made for
/// it, is the paste's own. It is written without a kind; the other entries name theirs.
///
/// `disk`, on every kind of entry, is the disk the hidden item is on (`NativeFS.diskId`), written by the journal's
/// file when the entry is added; nil when the disk has none, and in entries written before it was kept. With it, a
/// folder that is gone from a disk that is connected is told from a disk that is away, or another one of its name.
public struct ReplaceJournalEntry: Equatable, Sendable {
    public var id: String
    public var stagingPath: String
    public var finalPath: String
    public var sourcePath: String
    public var moved: Bool
    public var staged: Bool
    /// A move to another disk (a folder copied, then its original removed), kept until the originals are gone:
    /// put in place by recovery, or found in place, with its original still there too, the person is told.
    public var movingCopy: Bool
    public var disk: String?

    public init(
        id: String, stagingPath: String, finalPath: String, sourcePath: String, moved: Bool, staged: Bool,
        movingCopy: Bool = false, disk: String? = nil
    ) {
        self.disk = disk
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
    public var disk: String?

    public init(id: String, partialPath: String, finalPath: String, disk: String? = nil) {
        self.disk = disk
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
    public var disk: String?

    public init(id: String, items: [Item], disk: String? = nil) {
        self.disk = disk
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

    /// The disk the entry's hidden item is on, when it was written down.
    public var disk: String? {
        get {
            switch self {
            case .replace(let entry): entry.disk
            case .partialFile(let entry): entry.disk
            case .batchRename(let entry): entry.disk
            }
        }
        set {
            switch self {
            case .replace(var entry):
                entry.disk = newValue
                self = .replace(entry)
            case .partialFile(var entry):
                entry.disk = newValue
                self = .partialFile(entry)
            case .batchRename(var entry):
                entry.disk = newValue
                self = .batchRename(entry)
            }
        }
    }

    /// The hidden item the entry guards (the first, for a rename of several).
    public var hiddenPath: String? {
        switch self {
        case .replace(let entry): entry.stagingPath
        case .partialFile(let entry): entry.partialPath
        case .batchRename(let entry): entry.items.first?.temporaryPath
        }
    }
}

/// Where writes that leave items under hidden names while they run are written down, so a crash can't strand
/// one there: the next start finishes or undoes each. `add` replaces an entry with the same id. Each write must
/// be in the file, whole, before it returns, so it outlasts a crash or force quit (a power cut may still lose
/// the latest ones). `addFlushed` is `add` that is on the drive itself before it returns, so it outlasts a power
/// cut too: for the entry that guards an item's only copy.
public protocol WriteJournal: Sendable {
    func add(_ entry: WriteJournalEntry) throws
    func addFlushed(_ entry: WriteJournalEntry) throws
    func remove(_ id: String) throws
}

extension WriteJournal {
    /// A journal kept in memory has nothing to flush.
    public func addFlushed(_ entry: WriteJournalEntry) throws {
        try add(entry)
    }
}

// MARK: JSON

extension WriteJournalEntry {
    /// The entry as JSON: its keys in a fixed order, optional ones left out.
    var jsonObject: [(String, Any)] {
        var object = jsonObjectWithoutDisk
        if let disk {
            object.append(("disk", disk))
        }
        return object
    }

    private var jsonObjectWithoutDisk: [(String, Any)] {
        switch self {
        case .replace(let entry):
            var object: [(String, Any)] = [
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

    /// An entry read back from the file, or nil for anything that isn't one.
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
            self = .batchRename(BatchRenameJournalEntry(id: id, items: parsed, disk: entry["disk"] as? String))
            return
        }
        guard let finalPath = entry["finalPath"] as? String else { return nil }
        if let kind = kind as? String, kind == "partial_file" {
            guard let partialPath = entry["partialPath"] as? String else { return nil }
            self = .partialFile(
                PartialFileJournalEntry(
                    id: id, partialPath: partialPath, finalPath: finalPath, disk: entry["disk"] as? String))
            return
        }
        // A kind this build doesn't know: the entry is left out.
        if kind != nil {
            return nil
        }
        guard let stagingPath = entry["stagingPath"] as? String, let sourcePath = entry["sourcePath"] as? String,
            let moved = Self.bool(entry["moved"]), let staged = Self.bool(entry["staged"])
        else { return nil }
        self = .replace(
            ReplaceJournalEntry(
                id: id, stagingPath: stagingPath, finalPath: finalPath, sourcePath: sourcePath,
                moved: moved, staged: staged, movingCopy: Self.bool(entry["movingCopy"]) == true,
                disk: entry["disk"] as? String))
    }

    /// A JSON `true` or `false`, never a number, though Foundation reads both as an `NSNumber`.
    private static func bool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
}
