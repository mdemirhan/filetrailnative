import Foundation

/// Copy or Cut (`ClipboardMode`): whether an item on the clipboard is pasted as a copy or moved.
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

/// One item on the clipboard: where it is, what it was put on for, and what was known of it.
public struct ClipboardPick: Equatable, Sendable {
    public var path: String
    public var mode: ClipboardMode
    public var entry: ClipboardSourceEntry?
    /// Another item on the clipboard has this one's name, and the person chose to keep both: this one is pasted under
    /// a name of its own, as Keep Both names one.
    public var renamedIfShared: Bool
    /// When it was put on, or last given another intent: its mark flashes then (`ClipboardFlashTracker`). The same
    /// form as `capturedAt`, so the later of two is the larger.
    public var markedAt: String

    public init(
        path: String, mode: ClipboardMode, entry: ClipboardSourceEntry? = nil, renamedIfShared: Bool = false,
        markedAt: String
    ) {
        self.path = path
        self.mode = mode
        self.entry = entry
        self.renamedIfShared = renamedIfShared
        self.markedAt = markedAt
    }

    /// Paths are compared by their exact bytes: two that differ only in how an accented letter is stored are two items.
    public static func == (lhs: ClipboardPick, rhs: ClipboardPick) -> Bool {
        JSString.equals(lhs.path, rhs.path) && lhs.mode == rhs.mode && lhs.entry == rhs.entry
            && lhs.renamedIfShared == rhs.renamedIfShared && JSString.equals(lhs.markedAt, rhs.markedAt)
    }
}

/// The app's clipboard of files: empty, or the items Copy, Cut and the Adds put on it, each to be copied or moved.
public enum CopyPasteClipboard: Equatable, Sendable {
    case empty
    /// `grown`: an Add put items on it besides those of the Copy or Cut it started with, so a Copy or Cut that
    /// replaces it keeps it to be put back.
    case ready(picks: [ClipboardPick], capturedAt: String, grown: Bool)

    /// The clipboard holding `picks`, or empty without any.
    public static func holding(_ picks: [ClipboardPick], capturedAt: String, grown: Bool) -> CopyPasteClipboard {
        picks.isEmpty ? .empty : .ready(picks: picks, capturedAt: capturedAt, grown: grown)
    }

    /// Identifies this clipboard: it changes with every Copy and Cut (and Put Back) and with nothing else, so a
    /// follow-up from before another Copy never changes what is on it now.
    public var capturedAt: String? {
        if case .ready(_, let capturedAt, _) = self { return capturedAt }
        return nil
    }

    public var picks: [ClipboardPick] {
        if case .ready(let picks, _, _) = self { return picks }
        return []
    }

    public var isGrown: Bool {
        if case .ready(_, _, let grown) = self { return grown }
        return false
    }

    public var sourcePaths: [String] { picks.map(\.path) }

    public var hasItems: Bool { !picks.isEmpty }

    /// The intent every item shares: nil while empty, or while some are to be copied and others moved.
    public var mode: ClipboardMode? {
        guard let first = picks.first?.mode else { return nil }
        return picks.allSatisfy { $0.mode == first } ? first : nil
    }

    /// Some items are to be copied and others moved.
    public var isMixed: Bool { hasItems && mode == nil }

    public var cutPaths: [String] { picks.filter { $0.mode == .cut }.map(\.path) }

    public var copiedPaths: [String] { picks.filter { $0.mode == .copy }.map(\.path) }

    /// The items pasted under a name of their own, as another has theirs.
    public var renamedIfSharedPaths: [String] { picks.filter(\.renamedIfShared).map(\.path) }

    /// The item at `path`, by its exact bytes.
    public func pick(at path: String) -> ClipboardPick? {
        picks.first { JSString.equals($0.path, path) }
    }

    /// Whether any of `paths` is on the clipboard, by its exact bytes: one look at each list, where `pick(at:)` for
    /// each path looks through the whole clipboard.
    public func holdsAny(of paths: [String]) -> Bool {
        guard !paths.isEmpty, !picks.isEmpty else { return false }
        let held = Set(picks.map { Array($0.path.utf8) })
        return paths.contains { held.contains(Array($0.utf8)) }
    }
}

/// A finished write, as the clipboard follows it (`WriteOperationResult`): its action, how a paste's items were put
/// on the clipboard, its items and what a Replace removed.
public struct ClipboardWrite: Sendable {
    public var action: WriteOperationAction
    public var mode: ClipboardMode?
    public var items: [WriteEffectItem]
    public var replacedPaths: [String]

    public init(
        action: WriteOperationAction, mode: ClipboardMode? = nil, items: [WriteEffectItem], replacedPaths: [String] = []
    ) {
        self.action = action
        self.mode = mode
        self.items = items
        self.replacedPaths = replacedPaths
    }
}

/// The clipboard's own rules: what Copy, Cut and the Adds put on it, and how it follows what happens to its items.
public enum ClipboardRules {
    /// Copy or Cut: the paths without repeats, empty ones or any inside another, and what is known of each.
    public static func set(
        _ mode: ClipboardMode, _ sourcePaths: [String], capturedAt: String,
        entries: [String: ClipboardSourceEntry] = [:]
    ) -> CopyPasteClipboard {
        let paths = Paths.withoutNestedPaths(sourcePaths.filter { !$0.isEmpty })
        let picks = paths.map {
            ClipboardPick(path: $0, mode: mode, entry: entry(entries, $0), markedAt: capturedAt)
        }
        return settled(.holding(picks, capturedAt: capturedAt, grown: false))
    }

    /// One item off the clipboard; `capturedAt` stays.
    public static func removeItem(_ clipboard: CopyPasteClipboard, _ path: String) -> CopyPasteClipboard {
        removeItems(clipboard, [path])
    }

    /// Items off the clipboard, by their exact paths; `capturedAt` stays.
    public static func removeItems(_ clipboard: CopyPasteClipboard, _ paths: [String]) -> CopyPasteClipboard {
        guard case .ready(let picks, let capturedAt, let grown) = clipboard, !paths.isEmpty else { return clipboard }
        let removed = Set(paths.map(ExactKey.init))
        let rest = picks.filter { !removed.contains(ExactKey($0.path)) }
        if rest.count == picks.count { return clipboard }
        return settled(.holding(rest, capturedAt: capturedAt, grown: grown))
    }

    /// Items off the clipboard, with anything on it from inside them.
    public static func dropPaths(_ clipboard: CopyPasteClipboard, _ removedPaths: [String]) -> CopyPasteClipboard {
        guard case .ready(let picks, let capturedAt, let grown) = clipboard, !removedPaths.isEmpty else {
            return clipboard
        }
        let removed = Set(removedPaths.map(ExactKey.init))
        let rest = picks.filter { deepestHolder($0.path, { removed.contains(ExactKey($0)) }) == nil }
        if rest.count == picks.count { return clipboard }
        return settled(.holding(rest, capturedAt: capturedAt, grown: grown))
    }

    /// Follows items the app renamed or moved; `capturedAt` stays. Items the write left where
    /// they were (`left`) stay, even inside a folder that moved. An item the moves brought inside a folder on the
    /// clipboard comes off, whatever its intent: it goes with the folder, as when the folder is added.
    public static func remapPaths(
        _ clipboard: CopyPasteClipboard, _ moves: [(from: String, to: String)], left: LeftInPlace = .nothing
    ) -> CopyPasteClipboard {
        guard case .ready(let picks, let capturedAt, let grown) = clipboard, !moves.isEmpty else {
            return clipboard
        }
        var movesByFrom: [ExactKey: String] = [:]
        for move in moves where movesByFrom[ExactKey(move.from)] == nil {
            movesByFrom[ExactKey(move.from)] = move.to
        }
        var changed = false
        var next: [ClipboardPick] = []
        // Where each item kept was, by where it is now.
        var cameFrom: [ExactKey: String] = [:]
        for var pick in picks {
            let moved = remappedPath(pick.path, movesByFrom, left) ?? pick.path
            if !JSString.equals(moved, pick.path) { changed = true }
            guard cameFrom[ExactKey(moved)] == nil else { continue }
            cameFrom[ExactKey(moved)] = pick.path
            pick.path = moved
            next.append(pick)
        }
        guard changed else { return clipboard }
        // Only what the moves brought together: an item that was inside its folder before stays as it was put on.
        next.removeAll { pick in
            let from = cameFrom[ExactKey(pick.path)] ?? pick.path
            let holder = deepestHolder(parentPrefix(pick.path)) { folder in
                cameFrom[ExactKey(folder)].map { !JSString.hasPrefix(from, $0 + "/") } ?? false
            }
            return holder != nil
        }
        return settled(.holding(next, capturedAt: capturedAt, grown: grown))
    }

    /// What a write that moved items left where they were: the items it skipped, or that failed or were stopped,
    /// and every folder holding one (`LeftInPlace`).
    public struct LeftInPlace: Sendable {
        fileprivate var items: Set<ExactKey>
        fileprivate var itemsAndHolders: Set<ExactKey>

        public static let nothing = LeftInPlace(items: [], itemsAndHolders: [])
    }

    static func leftInPlace(by write: ClipboardWrite) -> LeftInPlace {
        var items = Set<ExactKey>()
        var holders = Set<ExactKey>()
        for item in write.items {
            guard let source = item.sourcePath, !source.isEmpty, item.status != .completed,
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

    /// Items renamed or moved are followed there, copied and cut ones alike, and those put in the Trash or deleted
    /// are taken off, each on its own: the rest stay as they were put on. Only what really happened counts.
    public static func followThroughWrite(_ clipboard: CopyPasteClipboard, _ write: ClipboardWrite)
        -> CopyPasteClipboard
    {
        let moves =
            WriteEffects.movedItems(write.action, cut: write.mode == .cut, items: write.items)
            ? WriteEffects.followedMoves(write.action, items: write.items) : []
        let left = moves.isEmpty ? LeftInPlace.nothing : leftInPlace(by: write)
        let removed = WriteEffects.removedPaths(write.action, items: write.items, replacedPaths: write.replacedPaths)
        // What was removed first: an item moved onto a removed item's path (a Replace) is followed there.
        return remapPaths(dropPaths(clipboard, removed), moves, left: left)
    }

    /// Items another app moved away or put in the Trash are taken off, each on its own.
    public static func followThroughRemoval(_ clipboard: CopyPasteClipboard, _ removedPaths: [String])
        -> CopyPasteClipboard
    {
        dropPaths(clipboard, removedPaths)
    }

    /// A paste of this clipboard that moved items has ended: it used the clipboard up. What it pasted, moved or
    /// copied, leaves; what it didn't get to (skipped, failed, stopped) stays as it was put on, to be tried again. The
    /// items gathered were one job, and copies left behind would make a later ⌘V paste part of it. A paste that moved
    /// nothing leaves the clipboard as it is, its copies to be pasted again, as after a Copy.
    public static func afterItsPaste(_ clipboard: CopyPasteClipboard, _ write: ClipboardWrite) -> CopyPasteClipboard {
        let wholeMove = WriteEffects.movedItems(write.action, cut: write.mode == .cut)
        let done = write.items.filter { item in
            guard item.status == .completed, let source = item.sourcePath else { return false }
            return !source.isEmpty
        }
        guard done.contains(where: { $0.mode.map { $0 == .cut } ?? wholeMove }) else { return clipboard }
        return removeItems(clipboard, done.compactMap(\.sourcePath))
    }

    /// The items at `paths` are to be copied or moved as `mode` says from now on; their marks flash (`markedAt`).
    public static func setMode(
        _ clipboard: CopyPasteClipboard, _ paths: [String], to mode: ClipboardMode, at markedAt: String
    ) -> CopyPasteClipboard {
        guard case .ready(var picks, let capturedAt, let grown) = clipboard else { return clipboard }
        let changing = Set(paths.map(ExactKey.init))
        var changed = false
        for index in picks.indices where changing.contains(ExactKey(picks[index].path)) && picks[index].mode != mode {
            picks[index].mode = mode
            picks[index].markedAt = markedAt
            changed = true
        }
        return changed ? .ready(picks: picks, capturedAt: capturedAt, grown: grown) : clipboard
    }

    /// The item at `path` keeps its own name, and the one of its name that kept it is pasted under a name of its own
    /// instead (Use This One Instead, from the row of an item kept beside another).
    public static func keepName(_ clipboard: CopyPasteClipboard, of path: String) -> CopyPasteClipboard {
        guard case .ready(var picks, let capturedAt, let grown) = clipboard,
            let index = picks.firstIndex(where: { JSString.equals($0.path, path) }), picks[index].renamedIfShared
        else { return clipboard }
        let key = sharedNameKey(path)
        for other in picks.indices where other != index && sharedNameKey(picks[other].path) == key {
            picks[other].renamedIfShared = true
        }
        picks[index].renamedIfShared = false
        return .ready(picks: picks, capturedAt: capturedAt, grown: grown)
    }

    // MARK: Two items of one name

    /// How two names are told apart when pasted into one folder, as most Macs' disks tell them: whatever their
    /// letter case, and however an accented letter is stored.
    public static func sharedNameKey(_ path: String) -> NameKeys.Exact {
        NameKeys.exactDestinationKey(PathText.leafName(path))
    }

    /// Whether the item at `path` will be pasted under a name of its own, as another item has its name.
    public static func isPastedUnderAnotherName(_ clipboard: CopyPasteClipboard, _ path: String) -> Bool {
        guard let pick = clipboard.pick(at: path), pick.renamedIfShared else { return false }
        let key = sharedNameKey(path)
        return clipboard.picks.contains { !JSString.equals($0.path, path) && sharedNameKey($0.path) == key }
    }

    /// The marks of items kept beside another of their name, put right after items came off or changed name: a name
    /// that no unmarked item keeps any more is kept by the first marked item of it, which then needs no name of its
    /// own. So a mark always means the item is pasted under another name.
    static func settled(_ clipboard: CopyPasteClipboard) -> CopyPasteClipboard {
        guard case .ready(var picks, let capturedAt, let grown) = clipboard, picks.contains(where: \.renamedIfShared)
        else { return clipboard }
        var keptBy = Set<NameKeys.Exact>()
        for pick in picks where !pick.renamedIfShared {
            keptBy.insert(sharedNameKey(pick.path))
        }
        for index in picks.indices where picks[index].renamedIfShared {
            let key = sharedNameKey(picks[index].path)
            if keptBy.insert(key).inserted {
                picks[index].renamedIfShared = false
            }
        }
        return .ready(picks: picks, capturedAt: capturedAt, grown: grown)
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

    /// Everything before the last slash, by code units: "" for a top folder ("/a") and for a path without a slash.
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

    /// `path` with `source` at its start changed to `destination`: `source` itself, or what is inside it; any other
    /// path as it is.
    static func replacePathPrefix(_ path: String, _ source: String, _ destination: String) -> String {
        if JSString.equals(path, source) { return destination }
        guard JSString.hasPrefix(path, source + "/") else { return path }
        let units = Array(path.utf16)
        return destination + JSString.string(units[source.utf16.count...])
    }

    /// What is known of the item at `path`.
    static func entry(_ entries: [String: ClipboardSourceEntry], _ path: String) -> ClipboardSourceEntry? {
        entries[path]
    }
}
