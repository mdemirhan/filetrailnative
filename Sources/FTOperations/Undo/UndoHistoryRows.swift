import FTFoundation
import Foundation

/// One operation as the Undo History list shows it: the Edit menu's name for it, where it happened, and its items
/// for the row's tooltip.
public struct UndoHistoryRow: Equatable, Sendable {
    public var id: Int
    public var icon: CommandIcon
    /// The Edit menu's name for it, after "Undo" or "Redo": "Move of 3 Items".
    public var title: String
    /// Where it happened, by folder name: "Downloads → Projects", "in Pictures", "from Projects", "in 3 folders".
    public var place: String?
    /// The same with whole paths, the home folder as "~", for the tooltip; nil when its items are in several folders,
    /// whose lines then say theirs.
    public var placePaths: String?
    /// One line per item, at most `UndoHistoryRows.maxItemLines`, the last then saying how many more there are.
    public var items: [String]
    public var date: Date
}

/// What the Undo History list shows, top to bottom: the operations Redo would do again, the next one last, then those
/// Undo would undo, the next one first, and what the history starts after.
public struct UndoHistoryContent: Equatable, Sendable {
    public var redo: [UndoHistoryRow]
    /// How many more there are past the top of `redo`, which ends with the next one.
    public var redoMore: Int
    public var undo: [UndoHistoryRow]
    /// How many more there are past the bottom of `undo`.
    public var undoMore: Int
    public var barrier: UndoBarrier?

    /// Nothing to undo or redo: the list isn't offered.
    public var isEmpty: Bool { redo.isEmpty && undo.isEmpty }
}

/// The rows built for a list that is open, by operation: when the history changes, only the operations that are new,
/// or that a stopped Undo left smaller, are built again.
@MainActor
public final class UndoHistoryRowCache {
    fileprivate var rows: [Int: (size: Int, row: UndoHistoryRow)] = [:]

    public init() {}
}

/// What the Undo History list says of the operations in the history.
public enum UndoHistoryRows {
    /// The most item lines a row's tooltip shows.
    public static let maxItemLines = 10
    /// The most operations of each list shown; the rest are counted.
    public static let maxRows = 100

    /// `content`: the history as the list shows it, at most `limit` operations of each list. With a `cache`, the rows
    /// it holds are used again, and it is left holding the rows of this content.
    @MainActor
    public static func content(
        _ history: UndoHistory, homePath: String, limit: Int = maxRows, cache: UndoHistoryRowCache? = nil
    ) -> UndoHistoryContent {
        let redo = history.entries(.redo)
        let undo = history.entries(.undo)
        var built: [Int: (size: Int, row: UndoHistoryRow)] = [:]
        // An operation is on one list only, and a stopped Undo leaves it with fewer steps under the same id.
        func rowOf(_ entry: UndoEntry, _ direction: UndoDirection) -> UndoHistoryRow {
            let row =
                if let kept = cache?.rows[entry.id], kept.size == entry.size {
                    kept.row
                } else {
                    row(entry, direction, homePath: homePath)
                }
            built[entry.id] = (entry.size, row)
            return row
        }
        defer { cache?.rows = built }
        return UndoHistoryContent(
            redo: redo.suffix(limit).map { rowOf($0, .redo) },
            redoMore: max(0, redo.count - limit),
            undo: undo.reversed().prefix(limit).map { rowOf($0, .undo) },
            undoMore: max(0, undo.count - limit),
            // Only while the Undo list goes back to it.
            barrier: undo.count > limit ? nil : history.barrier)
    }

    /// What one item of an operation did, as the person did it. An entry on the Redo list holds what its Undo did, the
    /// other way round.
    enum Change: Equatable {
        case moved(from: String, to: String)
        case made(String)
        case trashed(String)
        case putBack(String)
    }

    /// `row`: the entry of the `direction` list, its folders written with `homePath` as "~".
    public static func row(_ entry: UndoEntry, _ direction: UndoDirection, homePath: String) -> UndoHistoryRow {
        var items: [(change: Change, replacing: Bool)] = []
        for unit in entry.units {
            let changes = unit.steps.map { changes($0, direction) }
            // A batch rename's items are each a line.
            if unit.steps.contains(where: { if case .batchRenamed = $0 { return true } else { return false } }) {
                items += changes.flatMap { $0 }.map { ($0, false) }
                continue
            }
            let all = changes.flatMap { $0 }
            // The item the unit is about: what was made or moved, or else what went to the Trash. A Trash beside it
            // is the item it replaced.
            if let main = all.last(where: { if case .trashed = $0 { return false } else { return true } }) {
                items.append((main, all.contains { if case .trashed = $0 { return true } else { return false } }))
            } else if let main = all.last {
                items.append((main, false))
            }
        }
        let place = place(items.map(\.change), homePath: homePath)
        // Only the lines the tooltip shows are written: an operation may hold many thousands of items.
        let shown = items.count > maxItemLines ? maxItemLines - 1 : items.count
        var lines = items.prefix(shown).map { item in
            line(item.change, replacing: item.replacing, withFolders: place.paths == nil, homePath: homePath)
        }
        if items.count > shown { lines.append("and \(items.count - shown) more") }
        return UndoHistoryRow(
            id: entry.id, icon: icon(entry), title: UndoHistory.labelOf(entry.action, entry.units, moves: entry.moves),
            place: place.names, placePaths: place.paths, items: lines, date: entry.date)
    }

    /// What `step` did, as the person did it: on the Redo list, the reverse of what the Undo did.
    static func changes(_ step: UndoStep, _ direction: UndoDirection) -> [Change] {
        let undone = direction == .redo
        switch step {
        case .moved(let moved):
            if moved.fromTrash == true { return [undone ? .trashed(moved.to) : .putBack(moved.to)] }
            return [undone ? .moved(from: moved.to, to: moved.from) : .moved(from: moved.from, to: moved.to)]
        case .created(let path, _, _):
            return [.made(path)]
        case .trashed(let from, _, _, _, _):
            return [undone ? .made(from) : .trashed(from)]
        case .batchRenamed(let items):
            return items.map { undone ? .moved(from: $0.to, to: $0.from) : .moved(from: $0.from, to: $0.to) }
        }
    }

    /// Where the items were, by folder name and by whole path; both nil for no items.
    static func place(_ changes: [Change], homePath: String) -> (names: String?, paths: String?) {
        guard !changes.isEmpty else { return (nil, nil) }
        var sources = Folders()
        var destinations = Folders()
        var allMoved = true
        var allTrashed = true
        for change in changes {
            switch change {
            case .moved(let from, let to):
                sources.add(NodePath.dirname(from))
                destinations.add(NodePath.dirname(to))
                allTrashed = false
            case .made(let path), .putBack(let path):
                destinations.add(NodePath.dirname(path))
                allMoved = false
                allTrashed = false
            case .trashed(let path):
                sources.add(NodePath.dirname(path))
                allMoved = false
            }
        }
        func both(_ word: String, _ folder: String) -> (String?, String?) {
            ("\(word) \(folderName(folder))", "\(word) \(tilde(folder, homePath: homePath))")
        }
        if allMoved, sources.count == 1, destinations.count == 1 {
            let (from, to) = (sources.list[0], destinations.list[0])
            if sameText(from, to) { return both("in", from) }
            return (
                "\(folderName(from)) → \(folderName(to))",
                "\(tilde(from, homePath: homePath)) → \(tilde(to, homePath: homePath))"
            )
        }
        if allMoved, destinations.count == 1 { return both("to", destinations.list[0]) }
        if allTrashed, sources.count == 1 { return both("from", sources.list[0]) }
        var folders = sources
        for folder in destinations.list { folders.add(folder) }
        if folders.count == 1 { return both("in", folders.list[0]) }
        return ("\(allTrashed ? "from" : "in") \(folders.count) folders", nil)
    }

    /// An item's line: its name, or its old and new names when it has a new one; with its folders when the row's
    /// items are in several.
    static func line(_ change: Change, replacing: Bool, withFolders: Bool, homePath: String) -> String {
        var text: String
        var folders: String
        switch change {
        case .moved(let from, let to):
            let (old, new) = (NodePath.basename(from), NodePath.basename(to))
            text = sameText(old, new) ? new : "\(old) → \(new)"
            let (source, destination) = (NodePath.dirname(from), NodePath.dirname(to))
            folders =
                sameText(source, destination)
                ? "in \(tilde(source, homePath: homePath))"
                : "\(tilde(source, homePath: homePath)) → \(tilde(destination, homePath: homePath))"
        case .made(let path), .putBack(let path):
            text = NodePath.basename(path)
            folders = "in \(tilde(NodePath.dirname(path), homePath: homePath))"
        case .trashed(let path):
            text = NodePath.basename(path)
            folders = "from \(tilde(NodePath.dirname(path), homePath: homePath))"
        }
        if replacing { text += ", replacing the one there" }
        return withFolders ? "\(text) (\(folders))" : text
    }

    /// The icon of the command that did it.
    static func icon(_ entry: UndoEntry) -> CommandIcon {
        switch entry.action {
        case .rename, .batchRename: .rename
        case .newFolder: .newFolder
        case .trash: .trash
        case .deleteImmediately: .deleteImmediately
        case .duplicate: .duplicate
        case .moveTo: .move
        case .copyTo: .copy
        case .paste, .undo, .redo: entry.moves ? .move : .copy
        }
    }

    // MARK: What can't be undone

    /// `barrierTitle`: "Can’t undo before Delete Immediately".
    public static func barrierTitle(_ barrier: UndoBarrier) -> String {
        let name: String
        switch barrier.action {
        case .emptyTrash: name = "Empty Trash"
        case .write(let action):
            switch action {
            case .paste: name = barrier.reason == .otherDiskMove ? "Move" : "Paste"
            case .copyTo: name = "Copy To"
            case .moveTo: name = "Move To"
            case .duplicate: name = "Duplicate"
            case .trash: name = "Move to Trash"
            case .deleteImmediately: name = "Delete Immediately"
            case .rename, .batchRename: name = "Rename"
            case .newFolder: name = "New Folder"
            case .undo: name = "Undo"
            case .redo: name = "Redo"
            }
        }
        return "Can\u{2019}t undo before \(name)"
    }

    /// `barrierReason`: why it can't be undone, "Items were deleted for good".
    public static func barrierReason(_ barrier: UndoBarrier) -> String {
        switch barrier.reason {
        case .merge: "A folder was merged into one already there"
        case .deletedForGood, nil: "Items were deleted for good"
        case .noTrash: "Its disk has no Trash"
        case .otherDiskMove: "Items were moved to another disk"
        case .trashLocationUnknown: "The Trash didn\u{2019}t say where an item went"
        }
    }

    // MARK: Folders

    /// A folder's own name; "/" for the top of the startup disk.
    static func folderName(_ path: String) -> String {
        let name = NodePath.basename(path)
        return name.isEmpty ? "/" : name
    }

    /// `path` with the home folder written "~".
    static func tilde(_ path: String, homePath: String) -> String {
        guard !homePath.isEmpty else { return path }
        if sameText(path, homePath) { return "~" }
        let prefix = homePath.hasSuffix("/") ? homePath : homePath + "/"
        guard path.utf8.starts(with: prefix.utf8) else { return path }
        return "~/" + String(decoding: path.utf8.dropFirst(prefix.utf8.count), as: UTF8.self)
    }

    /// Folders, each once, in the order they were added. Two are the same when their text is, scalar for scalar
    /// (`sameText`), which their UTF-8 bytes tell too.
    private struct Folders {
        private(set) var list: [String] = []
        private var seen: Set<[UInt8]> = []

        var count: Int { list.count }

        mutating func add(_ folder: String) {
            // The items of an operation are mostly in one folder after another.
            if let last = list.last, sameText(last, folder) { return }
            if seen.insert(Array(folder.utf8)).inserted { list.append(folder) }
        }
    }
}
