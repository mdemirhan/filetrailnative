// Port of apps/desktop/src/renderer/lib/copyPasteClipboard.ts
import Foundation

/// Copy or Cut (`ClipboardMode`).
public enum ClipboardMode: String, Sendable, Equatable, Codable {
    case copy, cut
}

/// What was known about an item when it was copied: enough to draw its icon and to say whether it is a folder. Items
/// copied from somewhere that does not say (a path alone) have no entry.
public struct ClipboardSourceEntry: Equatable, Sendable {
    public var kind: EntryKind
    public var isSymlink: Bool
    public var isExecutable: Bool?

    public init(kind: EntryKind, isSymlink: Bool, isExecutable: Bool? = nil) {
        self.kind = kind
        self.isSymlink = isSymlink
        self.isExecutable = isExecutable
    }
}

/// The app's clipboard of files (`CopyPasteClipboardState`): empty, or what Copy or Cut put on it.
public enum CopyPasteClipboard: Equatable, Sendable {
    case empty
    case ready(
        mode: ClipboardMode, sourcePaths: [String], sourceEntries: [String: ClipboardSourceEntry], capturedAt: String)

    /// Identifies this clipboard: it changes with every Copy and Cut and with nothing else.
    public var capturedAt: String? {
        if case .ready(_, _, _, let capturedAt) = self { return capturedAt }
        return nil
    }

    public var mode: ClipboardMode? {
        if case .ready(let mode, _, _, _) = self { return mode }
        return nil
    }

    public var sourcePaths: [String] {
        if case .ready(_, let paths, _, _) = self { return paths }
        return []
    }

    public var sourceEntries: [String: ClipboardSourceEntry] {
        if case .ready(_, _, let entries, _) = self { return entries }
        return [:]
    }

    /// `hasClipboardItems`.
    public var hasItems: Bool { !sourcePaths.isEmpty }
}

/// A finished write, as the clipboard follows it (`WriteOperationResult`): its action, how a paste's items were put
/// on the clipboard, its items and what a Replace removed.
public struct ClipboardWrite: Sendable {
    /// "paste", "move_to", "rename", "batch_rename", "trash", "delete_immediately", "undo", "redo" and the like.
    public var action: String
    public var mode: ClipboardMode?
    public var items: [WriteEffectItem]
    public var replacedPaths: [String]

    public init(action: String, mode: ClipboardMode? = nil, items: [WriteEffectItem], replacedPaths: [String] = []) {
        self.action = action
        self.mode = mode
        self.items = items
        self.replacedPaths = replacedPaths
    }

    var isUndoOrRedo: Bool { action == "undo" || action == "redo" }

    /// `isRenameOrMove`.
    var isRenameOrMove: Bool {
        action == "rename" || action == "batch_rename" || action == "move_to" || isUndoOrRedo
    }

    /// `movedItems`: a write that gave items new paths: a rename or move, or a paste that moved what was cut.
    public var movedItems: Bool { isRenameOrMove || mode == .cut }

    /// `collectFollowedMoves`.
    var followedMoves: [(from: String, to: String)] {
        items.compactMap { item in
            guard WriteEffects.isFollowedMove(item, action: action), let from = item.sourcePath,
                let to = item.destinationPath
            else { return nil }
            return (from, to)
        }
    }

    /// `removedByWrite`: everything a Trash or delete was asked to remove, what an Undo moved to the Trash, and what
    /// a Replace removed (another item has its path now).
    public var removedPaths: [String] {
        if action == "trash" || action == "delete_immediately" {
            return items.compactMap { item in
                guard item.status == "completed", let path = item.sourcePath, !path.isEmpty else { return nil }
                return path
            }
        }
        if isUndoOrRedo {
            let removed = items.compactMap { item -> String? in
                guard item.status == "completed", item.destinationPath == nil, let path = item.sourcePath,
                    !path.isEmpty
                else { return nil }
                return path
            }
            return removed + replacedPaths
        }
        return replacedPaths
    }
}

/// The clipboard's own rules: what Copy and Cut put on it, and how it follows what happens to its items.
public enum ClipboardRules {
    /// `setCopyPasteClipboard`: the paths without repeats or empty ones, and what is known of each.
    public static func set(
        _ mode: ClipboardMode, _ sourcePaths: [String], capturedAt: String,
        entries: [String: ClipboardSourceEntry] = [:]
    ) -> CopyPasteClipboard {
        var seen = Set<ExactKey>()
        let paths = sourcePaths.filter { !$0.isEmpty && seen.insert(ExactKey($0)).inserted }
        guard !paths.isEmpty else { return .empty }
        var known: [String: ClipboardSourceEntry] = [:]
        for path in paths {
            if let entry = entries[path] { known[path] = entry }
        }
        return .ready(mode: mode, sourcePaths: paths, sourceEntries: known, capturedAt: capturedAt)
    }

    /// `removeClipboardItem`: one item off the clipboard; `capturedAt` stays.
    public static func removeItem(_ clipboard: CopyPasteClipboard, _ path: String) -> CopyPasteClipboard {
        guard case .ready(let mode, let paths, var entries, let capturedAt) = clipboard,
            paths.contains(where: { JSString.equals($0, path) })
        else { return clipboard }
        let rest = paths.filter { !JSString.equals($0, path) }
        guard !rest.isEmpty else { return .empty }
        entries.removeValue(forKey: path)
        return .ready(mode: mode, sourcePaths: rest, sourceEntries: entries, capturedAt: capturedAt)
    }

    /// `dropClipboardPaths`: items off the clipboard, with anything on it from inside them.
    public static func dropPaths(_ clipboard: CopyPasteClipboard, _ removedPaths: [String]) -> CopyPasteClipboard {
        guard case .ready(let mode, let paths, let entries, let capturedAt) = clipboard, !removedPaths.isEmpty else {
            return clipboard
        }
        let removed = Set(removedPaths.map(ExactKey.init))
        let rest = paths.filter { deepestHolder($0, { removed.contains(ExactKey($0)) }) == nil }
        if rest.count == paths.count { return clipboard }
        guard !rest.isEmpty else { return .empty }
        var kept: [String: ClipboardSourceEntry] = [:]
        for path in rest {
            if let entry = entries[path] { kept[path] = entry }
        }
        return .ready(mode: mode, sourcePaths: rest, sourceEntries: kept, capturedAt: capturedAt)
    }

    /// `remapClipboardPaths`: follows items the app renamed or moved; `capturedAt` stays. Items the write left where
    /// they were (`left`) stay, even inside a folder that moved.
    public static func remapPaths(
        _ clipboard: CopyPasteClipboard, _ moves: [(from: String, to: String)], left: LeftInPlace = .nothing
    ) -> CopyPasteClipboard {
        guard case .ready(let mode, let paths, let entries, let capturedAt) = clipboard, !moves.isEmpty else {
            return clipboard
        }
        var movesByFrom: [ExactKey: String] = [:]
        for move in moves where movesByFrom[ExactKey(move.from)] == nil {
            movesByFrom[ExactKey(move.from)] = move.to
        }
        var changed = false
        var next: [String] = []
        var kept = Set<ExactKey>()
        var nextEntries: [String: ClipboardSourceEntry] = [:]
        for path in paths {
            let moved = remappedPath(path, movesByFrom, left) ?? path
            if !JSString.equals(moved, path) { changed = true }
            guard kept.insert(ExactKey(moved)).inserted else { continue }
            next.append(moved)
            if let entry = entries[path] { nextEntries[moved] = entry }
        }
        return changed
            ? .ready(mode: mode, sourcePaths: next, sourceEntries: nextEntries, capturedAt: capturedAt) : clipboard
    }

    /// What a write that moved items left where they were: the items it skipped, or that failed or were stopped,
    /// and every folder holding one (`LeftInPlace`).
    public struct LeftInPlace: Sendable {
        fileprivate var items: Set<ExactKey>
        fileprivate var itemsAndHolders: Set<ExactKey>

        public static let nothing = LeftInPlace(items: [], itemsAndHolders: [])
    }

    /// `leftInPlaceBy`.
    static func leftInPlace(by write: ClipboardWrite) -> LeftInPlace {
        var items = Set<ExactKey>()
        var holders = Set<ExactKey>()
        for item in write.items {
            guard let source = item.sourcePath, !source.isEmpty, item.status != "completed",
                !WriteEffects.isFollowedMove(item, action: write.action)
            else { continue }
            items.insert(ExactKey(source))
            var path = source
            while !path.isEmpty, holders.insert(ExactKey(path)).inserted {
                path = parentPrefix(path)
            }
        }
        return items.isEmpty ? .nothing : LeftInPlace(items: items, itemsAndHolders: holders)
    }

    /// `followClipboardThroughWrite`: copied items renamed or moved are followed, those put in the Trash or deleted
    /// are taken off; a cut is cancelled once any of its items is renamed, moved, trashed or deleted. Only what
    /// really happened counts.
    public static func followThroughWrite(_ clipboard: CopyPasteClipboard, _ write: ClipboardWrite)
        -> CopyPasteClipboard
    {
        let moves = write.movedItems ? write.followedMoves : []
        let left = moves.isEmpty ? LeftInPlace.nothing : leftInPlace(by: write)
        return follow(clipboard, moves: moves, removed: write.removedPaths, left: left)
    }

    /// `followClipboardThroughRemoval`: items another app moved away or put in the Trash are taken off, and a cut
    /// of any is cancelled.
    public static func followThroughRemoval(_ clipboard: CopyPasteClipboard, _ removedPaths: [String])
        -> CopyPasteClipboard
    {
        follow(clipboard, moves: [], removed: removedPaths, left: .nothing)
    }

    private static func follow(
        _ clipboard: CopyPasteClipboard, moves: [(from: String, to: String)], removed: [String], left: LeftInPlace
    ) -> CopyPasteClipboard {
        guard case .ready(let mode, let paths, _, _) = clipboard else { return clipboard }
        if mode == .cut {
            let changed = Set(moves.map { ExactKey($0.from) } + removed.map(ExactKey.init))
            let touched = paths.contains { deepestHolder($0, { changed.contains(ExactKey($0)) }) != nil }
            return touched ? .empty : clipboard
        }
        // What was removed first: an item moved onto a removed item's path (a Replace) is followed there.
        return remapPaths(dropPaths(clipboard, removed), moves, left: left)
    }

    /// `buildPasteRequest`: what a paste asks to analyze.
    public static func pasteRequest(_ clipboard: CopyPasteClipboard, destination: String) -> PasteRequest? {
        guard case .ready(let mode, let paths, _, _) = clipboard else { return nil }
        return PasteRequest(mode: mode, sourcePaths: paths, destinationDirectoryPath: destination, action: "paste")
    }

    /// `clearClipboardAfterSuccessfulPaste`.
    public static func clearedAfterSuccessfulPaste(_ clipboard: CopyPasteClipboard) -> CopyPasteClipboard {
        .empty
    }

    // MARK: Paths

    /// `path` itself or the deepest folder holding it that `matches`, looked up along its own path.
    static func deepestHolder(_ path: String, _ matches: (String) -> Bool) -> String? {
        var holder = path
        while !holder.isEmpty {
            if matches(holder) { return holder }
            holder = parentPrefix(holder)
        }
        return nil
    }

    /// `path.slice(0, max(0, path.lastIndexOf("/")))`.
    static func parentPrefix(_ path: String) -> String {
        let units = Array(path.utf16)
        guard let slash = JSString.lastIndex(of: 0x2F, in: units) else { return "" }
        return JSString.string(units[..<slash])
    }

    private static func remappedPath(_ path: String, _ movesByFrom: [ExactKey: String], _ left: LeftInPlace)
        -> String?
    {
        guard let from = deepestHolder(path, { movesByFrom[ExactKey($0)] != nil }), !staysInPlace(path, from, left),
            let to = movesByFrom[ExactKey(from)]
        else { return nil }
        return replacePathPrefix(path, from, to)
    }

    private static func staysInPlace(_ path: String, _ movedFrom: String, _ left: LeftInPlace) -> Bool {
        guard !left.items.isEmpty else { return false }
        if left.itemsAndHolders.contains(ExactKey(path)) { return true }
        let floor = movedFrom.utf16.count
        var holder = parentPrefix(path)
        while holder.utf16.count >= floor {
            if left.items.contains(ExactKey(holder)) { return true }
            if holder.isEmpty { break }
            holder = parentPrefix(holder)
        }
        return false
    }

    /// `replacePathPrefix`.
    static func replacePathPrefix(_ path: String, _ source: String, _ destination: String) -> String {
        if JSString.equals(path, source) { return destination }
        guard JSString.hasPrefix(path, source + "/") else { return path }
        let units = Array(path.utf16)
        return destination + JSString.string(units[source.utf16.count...])
    }
}

/// `IpcRequest<"copyPaste:analyzeStart">` as a paste makes it.
public struct PasteRequest: Equatable, Sendable {
    public var mode: ClipboardMode
    public var sourcePaths: [String]
    public var destinationDirectoryPath: String
    public var action: String
}
