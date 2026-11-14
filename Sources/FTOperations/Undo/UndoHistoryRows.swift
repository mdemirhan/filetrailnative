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

/// The rows built for the list, by operation of one history: an operation is gone over once, the first time the list
/// shows it, and again only when a stopped Undo left it smaller.
@MainActor
public final class UndoHistoryRowCache {
    fileprivate weak var history: UndoHistory?
    fileprivate var rows: [Int: (size: Int, row: UndoHistoryRow)] = [:]

    public init() {}
}

/// What the Undo History list says of the operations in the history.
public enum UndoHistoryRows {
    /// The most item lines a row's tooltip shows.
    public static let maxItemLines = 10
    /// The most operations of each list shown; the rest are counted.
    public static let maxRows = 100
    /// The most items of an operation whose folders are read: a longer one is told by its first 1,000, and the rest
    /// are only counted.
    public static let maxItemsRead = 1_000
    /// The most folders an operation's items are counted in: past it the row says "in over 100 folders".
    public static let maxFolders = 100

    /// `content`: the history as the list shows it, at most `limit` operations of each list. With a `cache`, the rows
    /// it holds are used again, and it is left holding the rows of this content.
    @MainActor
    public static func content(
        _ history: UndoHistory, homePath: String, limit: Int = maxRows, cache: UndoHistoryRowCache? = nil
    ) -> UndoHistoryContent {
        let redo = history.entries(.redo)
        let undo = history.entries(.undo)
        // Another history numbers its operations from 1 again.
        if let cache, cache.history !== history {
            cache.history = history
            cache.rows = [:]
        }
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

    /// `row`: the entry of the `direction` list, its folders written with `homePath` as "~". Where it happened is
    /// read from its first `maxItemsRead` items; the items past those are counted, and nothing of them is read.
    public static func row(_ entry: UndoEntry, _ direction: UndoDirection, homePath: String) -> UndoHistoryRow {
        var count = 0
        // The items the tooltip's lines are about.
        var first: [(change: Change, replacing: Bool)] = []
        var places = Places()
        func take(_ change: Change, replacing: Bool) {
            count += 1
            if first.count < maxItemLines { first.append((change, replacing)) }
            places.add(change)
        }
        for unit in entry.units {
            // A batch rename's items are each a line.
            if unit.steps.contains(where: { if case .batchRenamed = $0 { return true } else { return false } }) {
                for step in unit.steps {
                    guard case .batchRenamed(let items) = step else {
                        if count < maxItemsRead, let change = change(step, direction) {
                            take(change, replacing: false)
                        } else {
                            count += 1
                        }
                        continue
                    }
                    let read = min(items.count, max(0, maxItemsRead - count))
                    let undone = direction == .redo
                    for item in items.prefix(read) {
                        take(
                            undone ? .moved(from: item.to, to: item.from) : .moved(from: item.from, to: item.to),
                            replacing: false)
                    }
                    count += items.count - read
                }
                continue
            }
            guard count < maxItemsRead else {
                if !unit.steps.isEmpty { count += 1 }
                continue
            }
            // The item the unit is about: what was made or moved, or else what went to the Trash. A Trash beside it
            // is the item it replaced.
            var main: Change?
            var last: Change?
            var trashes = false
            for step in unit.steps.reversed() {
                guard let change = change(step, direction) else { continue }
                if last == nil { last = change }
                if case .trashed = change { trashes = true } else if main == nil { main = change }
            }
            if let main { take(main, replacing: trashes) } else if let last { take(last, replacing: false) }
        }
        let place = place(places, homePath: homePath)
        let shown = count > maxItemLines ? maxItemLines - 1 : count
        var lines = first.prefix(shown).map { item in
            line(item.change, replacing: item.replacing, withFolders: place.paths == nil, homePath: homePath)
        }
        if count > shown { lines.append("and \(count - shown) more") }
        return UndoHistoryRow(
            id: entry.id, icon: icon(entry), title: UndoHistory.labelOf(entry.action, entry.units, moves: entry.moves),
            place: place.names, placePaths: place.paths, items: lines, date: entry.date)
    }

    /// What a step of one item did; nil for a batch rename, which holds many (`changes`).
    static func change(_ step: UndoStep, _ direction: UndoDirection) -> Change? {
        let undone = direction == .redo
        switch step {
        case .moved(let moved):
            if moved.fromTrash == true { return undone ? .trashed(moved.to) : .putBack(moved.to) }
            return undone ? .moved(from: moved.to, to: moved.from) : .moved(from: moved.from, to: moved.to)
        case .created(let path, _, _):
            return .made(path)
        case .trashed(let from, _, _, _, _):
            return undone ? .made(from) : .trashed(from)
        case .batchRenamed:
            return nil
        }
    }

    /// What `step` did, as the person did it: on the Redo list, the reverse of what the Undo did.
    static func changes(_ step: UndoStep, _ direction: UndoDirection) -> [Change] {
        guard case .batchRenamed(let items) = step else { return change(step, direction).map { [$0] } ?? [] }
        let undone = direction == .redo
        return items.map { undone ? .moved(from: $0.to, to: $0.from) : .moved(from: $0.from, to: $0.to) }
    }

    /// The folders the items of an operation were taken from and put in, and whether every item was moved, or every
    /// one went to the Trash.
    struct Places {
        var sources = Folders()
        var destinations = Folders()
        var allMoved = true
        var allTrashed = true
        var isEmpty = true

        mutating func add(_ change: Change) {
            isEmpty = false
            switch change {
            case .moved(let from, let to):
                sources.add(parentOf: from)
                destinations.add(parentOf: to)
                allTrashed = false
            case .made(let path), .putBack(let path):
                destinations.add(parentOf: path)
                allMoved = false
                allTrashed = false
            case .trashed(let path):
                sources.add(parentOf: path)
                allMoved = false
            }
        }
    }

    /// Where the items were, by folder name and by whole path; both nil for no items.
    static func place(_ places: Places, homePath: String) -> (names: String?, paths: String?) {
        guard !places.isEmpty else { return (nil, nil) }
        let (sources, destinations) = (places.sources, places.destinations)
        let (allMoved, allTrashed) = (places.allMoved, places.allTrashed)
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
        let word = allTrashed ? "from" : "in"
        if sources.isOver || destinations.isOver || folders.isOver {
            return ("\(word) over \(maxFolders) folders", nil)
        }
        return ("\(word) \(folders.count) folders", nil)
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
        case .pasteAsFile: .pasteAsFile
        case .compress: .compress
        case .extract: .extract
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
            case .pasteAsFile: name = "Paste as File"
            case .compress: name = "Compress"
            case .extract: name = "Extract"
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

    /// Folders, each once, in the order they were added, up to `maxFolders` of them: past that they are no longer
    /// told apart (`isOver`). Two are the same when their text is, scalar for scalar (`sameText`), which their UTF-8
    /// bytes tell too.
    struct Folders {
        private(set) var list: [String] = []
        private var seen: Set<[UInt8]> = []
        private(set) var isOver = false

        var count: Int { list.count }

        /// The folder `path` is in.
        mutating func add(parentOf path: String) {
            guard !isOver else { return }
            // The items of an operation are mostly in one folder after another: nothing is made for those.
            if let last = list.last, Self.isDirectly(path, in: last) { return }
            add(NodePath.dirname(path))
        }

        mutating func add(_ folder: String) {
            guard !isOver else { return }
            if let last = list.last, sameText(last, folder) { return }
            guard seen.insert(Array(folder.utf8)).inserted else { return }
            if list.count == maxFolders {
                isOver = true
            } else {
                list.append(folder)
            }
        }

        /// Whether `path` is `folder`, a "/" and one name: `folder` is then what `NodePath.dirname` gives for it.
        static func isDirectly(_ path: String, in folder: String) -> Bool {
            let (path, folder) = (path.utf8, folder.utf8)
            let slash = UInt8(ascii: "/")
            guard folder.last != slash, path.count > folder.count + 1, path.starts(with: folder) else { return false }
            let rest = path.dropFirst(folder.count)
            return rest.first == slash && !rest.dropFirst().contains(slash)
        }
    }
}
