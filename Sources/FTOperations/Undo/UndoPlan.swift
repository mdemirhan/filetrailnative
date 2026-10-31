// Port of apps/desktop/src/main/bootstrap/undoPlan.ts
import FTFoundation
import Foundation
import os

// What undoing one step does, and whether it can be done now. Nothing here changes the disk: UndoExecution.swift
// does, checking each step again just before it runs. Every call reads the disk: callers run it off the main actor.

/// Moves the item at `from` to `to`: a rename or move back, or putting an item back from the Trash (`putBack`).
/// `parentId` is the folder `to` must still be the one it was. `stamp` is how an item without a usable id looked when
/// it went to the Trash.
public struct PlannedMove: Equatable, Sendable {
    public var from: String
    public var to: String
    public var id: ItemId?
    public var itemKind: ItemKind?
    public var parentId: ItemId?
    public var putBack: Bool
    public var stamp: ItemStamp?

    public init(
        from: String, to: String, id: ItemId?, itemKind: ItemKind?, parentId: ItemId?, putBack: Bool,
        stamp: ItemStamp? = nil
    ) {
        self.from = from
        self.to = to
        self.id = id
        self.itemKind = itemKind
        self.parentId = parentId
        self.putBack = putBack
        self.stamp = stamp
    }
}

/// Moves the item at `path` to the Trash: something an operation made, or put back from the Trash (`putBack`).
/// `unlock`: it may be locked by the app's own doing (a copy of a locked item, or one put back locked), and is
/// unlocked to go.
public struct PlannedTrash: Equatable, Sendable {
    public var path: String
    public var id: ItemId?
    public var stamp: ItemStamp?
    public var putBack: Bool
    public var unlock: Bool

    public init(path: String, id: ItemId?, stamp: ItemStamp?, putBack: Bool, unlock: Bool) {
        self.path = path
        self.id = id
        self.stamp = stamp
        self.putBack = putBack
        self.unlock = unlock
    }
}

/// The reverse of a step, ready to run.
public enum PlannedStep: Equatable, Sendable {
    case move(PlannedMove)
    case trash(PlannedTrash)
    /// Renames each item at `from` back to the name in `to`, as one batch.
    case batch(items: [BatchRenamedItem])

    /// `reverseStep`.
    public init(reversing step: UndoStep) {
        switch step {
        case .moved(let moved):
            if moved.fromTrash == true {
                self = .trash(
                    PlannedTrash(
                        path: moved.to, id: moved.id, stamp: moved.stamp, putBack: true, unlock: moved.locked == true))
            } else {
                self = .move(
                    PlannedMove(
                        from: moved.to, to: moved.from, id: moved.id, itemKind: moved.itemKind,
                        parentId: moved.parentId, putBack: false))
            }
        case .created(let path, let id, let stamp):
            self = .trash(PlannedTrash(path: path, id: id, stamp: stamp, putBack: false, unlock: true))
        case .trashed(let from, let trashPath, let id, let parentId, let stamp):
            // The Trash never changes what is in it: only the very item goes back. Without an id, it has to look as
            // it did when it went.
            self = .move(
                PlannedMove(
                    from: trashPath, to: from, id: id, itemKind: stamp?.kind, parentId: parentId, putBack: true,
                    stamp: stamp))
        case .batchRenamed(let items):
            self = .batch(
                items: items.map { BatchRenamedItem(from: $0.to, to: $0.from, id: $0.id, itemKind: $0.itemKind) })
        }
    }
}

/// Why a step can't be undone, said about the item. `missing` means nothing is left where the item was: no other
/// item is in the way of the steps after it. `retry` means it can't be told now (the disk couldn't be read: no
/// permission, an error, a share not answering): the step stays to be tried again, never dropped as if its item were
/// gone.
public struct Refusal: Equatable, Sendable {
    public var reason: String
    public var missing: Bool
    public var retry: Bool

    public init(reason: String, missing: Bool, retry: Bool = false) {
        self.reason = reason
        self.missing = missing
        self.retry = retry
    }
}

/// What `checkMove` found: `id` is the item's id now, when it has one.
public enum MoveCheck: Equatable, Sendable {
    case ok(nameTaken: Bool, renamesItself: Bool, isFolder: Bool, id: ItemId?, kind: ItemKind)
    case refused(Refusal)
}

public enum TrashCheck: Equatable, Sendable {
    case ok(changed: Bool, id: ItemId?)
    case refused(Refusal)
}

/// What the steps before one in the same unit will have done by the time it runs (a Replace moves its new item away
/// before it puts the old one back): the items they move away, by id (and by place, for an item without one: only
/// FAT and exFAT, which ignore case), and the places they move items into.
public struct UnitChanges: Sendable {
    public var movedAwayIds: Set<ItemId> = []
    public var movedAwayPaths: Set<NameKeys.Exact> = []
    public var filledPlaces: Set<NameKeys.Exact> = []

    public init() {}

    mutating func noteMovedAway(_ path: String, _ id: ItemId?) {
        if let id { movedAwayIds.insert(id) }
        movedAwayPaths.insert(UndoPlan.placeKey(path))
        filledPlaces.remove(UndoPlan.placeKey(path))
    }
}

/// One item of a batch on its own (`BatchItemCheck`).
public struct BatchItemCheck: Equatable, Sendable {
    public var item: BatchRenamedItem
    public var refusal: Refusal?
    public var nameTaken: Bool
    public var isFolder: Bool
}

/// An item an Undo would move to the Trash though it changed since: one that was put back from the Trash, the new
/// item of a Replace, or one the operation made. The window is told its name; `path` tells it from another item of
/// that name in another folder.
public struct ChangedItem: Equatable, Sendable {
    public var name: String
    public var path: String
    public var putBack: Bool
    public var replaced: Bool

    public init(name: String, path: String, putBack: Bool, replaced: Bool) {
        self.name = name
        self.path = path
        self.putBack = putBack
        self.replaced = replaced
    }
}

/// A place an item goes back to that another item has taken.
public struct TakenName: Equatable, Sendable {
    public var name: String
    public var path: String

    public init(name: String, path: String) {
        self.name = name
        self.path = path
    }
}

public struct UndoQuestions: Equatable, Sendable {
    public var nameTaken: [TakenName]
    public var changed: [ChangedItem]

    public init(nameTaken: [TakenName] = [], changed: [ChangedItem] = []) {
        self.nameTaken = nameTaken
        self.changed = changed
    }
}

public enum UndoPlan {
    /// How many units `findQuestions` looks at at once (`QUESTION_CHECKS_AT_ONCE`).
    static let questionChecksAtOnce = 16

    /// `placeKey`: a place compared as a disk that ignores case and accent encoding does, as the Mac's disks do: on
    /// one that minds case, two names that differ only in case are at worst asked about though only one of them is
    /// taken.
    public static func placeKey(_ path: String) -> NameKeys.Exact {
        NameKeys.Exact(NameKeys.placeKey(path))
    }

    /// `leavesBefore`: the item at `path` leaves before the step runs. It is found by id, so "x.txt" finds the "X.TXT"
    /// a step before moved away, on a disk that takes them for one name.
    static func leavesBefore(_ stats: WriteServiceStats, _ path: String, _ changes: UnitChanges) -> Bool {
        if let id = itemIdOf(stats) {
            return changes.movedAwayIds.contains(id)
        }
        return changes.movedAwayPaths.contains(placeKey(path))
    }

    /// What is at `path`: an item, nothing at all, or an error that hides whether there is one.
    enum LookedUp {
        case found(WriteServiceStats)
        case missing
        case unreadable(Refusal)
    }

    static func lookUp(_ path: String, _ look: (String) throws -> WriteServiceStats) -> LookedUp {
        do {
            return .found(try look(path))
        } catch {
            let code = errorCode(error)
            if code == "ENOENT" || code == "ENOTDIR" {
                return .missing
            }
            return .unreadable(
                Refusal(
                    reason:
                        "\u{201C}\(NodePath.basename(path))\u{201D} couldn't be checked: \(describeCopyPasteError(error))",
                    missing: false, retry: true))
        }
    }

    /// `isExpectedItem`: whether the item at a path is the one a step was about. Its id must match; when moving or
    /// renaming it back (`relaxed`), an item of the same kind under the same name is taken too, since apps save a
    /// document by replacing its file, which gives it a new id. Without a usable id (FAT, exFAT), the kind is all
    /// there is to go by.
    static func isExpectedItem(_ stats: WriteServiceStats, _ id: ItemId?, _ itemKind: ItemKind?, relaxed: Bool) -> Bool
    {
        let currentId = itemIdOf(stats)
        if let id, let currentId {
            if id == currentId {
                return true
            }
            return relaxed && itemKind != nil && kindOfStats(stats) == itemKind
        }
        return itemKind == nil || kindOfStats(stats) == itemKind
    }

    /// `missingReason`: an item that isn't where it was: gone, or on a disk that is no longer connected. An item to
    /// be put back from the Trash goes by the name it had before (`original`, the place it goes back to), not its
    /// name in the Trash's own folders (".Trash", ".Trashes/501").
    public static func missingReason(_ fileSystem: some IdentityFileSystem, _ path: String, original: String? = nil)
        -> String
    {
        let name = NodePath.basename(original ?? path)
        if let disk = volumeName(path), (try? fileSystem.lstat("/Volumes/\(disk)")) == nil {
            return "\u{201C}\(name)\u{201D} is on \u{201C}\(disk)\u{201D}, which isn't connected."
        }
        if original != nil {
            return "\u{201C}\(name)\u{201D} isn't in the Trash any more."
        }
        return "\u{201C}\(name)\u{201D} is no longer in \u{201C}\(NodePath.basename(NodePath.dirname(path)))\u{201D}."
    }

    /// `/^\/Volumes\/([^/]+)\//u.exec(path)?.[1]`.
    private static func volumeName(_ path: String) -> String? {
        let scalars = Array(path.unicodeScalars)
        let prefix = Array("/Volumes/".unicodeScalars)
        guard scalars.starts(with: prefix) else { return nil }
        let rest = scalars[prefix.count...]
        guard let slash = rest.firstIndex(of: "/"), slash > rest.startIndex else { return nil }
        return String(String.UnicodeScalarView(rest[rest.startIndex..<slash]))
    }

    /// `replacedReason`: the item at `path` isn't the one a step was about (`expected`): another item, or the same
    /// one on a disk that was ejected and connected again, which gives it another device number (and Undo can't tell
    /// it is the same disk). `original` as for `missingReason`.
    static func replacedReason(_ path: String, _ expected: ItemId?, _ stats: WriteServiceStats, original: String? = nil)
        -> String
    {
        let name = NodePath.basename(original ?? path)
        if reconnected(expected, itemIdOf(stats)) {
            return "\u{201C}\(name)\u{201D} is on a disk that was disconnected since, so it is left as it is."
        }
        if original != nil {
            return "The \u{201C}\(name)\u{201D} in the Trash is another item now."
        }
        return
            "The \u{201C}\(name)\u{201D} in \u{201C}\(NodePath.basename(NodePath.dirname(path)))\u{201D} is another item now."
    }

    /// The same file id on another device number: the disk was ejected and connected again.
    static func reconnected(_ expected: ItemId?, _ now: ItemId?) -> Bool {
        guard let expected, let now else { return false }
        return expected.dev != now.dev && expected.ino == now.ino
    }

    /// `checkMove`: whether `step` can be done now, or once the steps before it in the same unit have made `changes`
    /// (a Replace puts its old item back where the new one was).
    public static func checkMove(
        _ fileSystem: some IdentityFileSystem, _ step: PlannedMove, _ changes: UnitChanges = UnitChanges()
    ) -> MoveCheck {
        let item: WriteServiceStats
        // An item in the Trash goes by the name it goes back to.
        let original = step.putBack ? step.to : nil
        switch lookUp(step.from, { try fileSystem.lstat($0) }) {
        case .unreadable(let refusal): return .refused(refusal)
        case .missing:
            return .refused(
                Refusal(reason: missingReason(fileSystem, step.from, original: original), missing: true))
        case .found(let stats): item = stats
        }
        if !isExpectedItem(item, step.id, step.itemKind, relaxed: !step.putBack) {
            return .refused(
                Refusal(reason: replacedReason(step.from, step.id, item, original: original), missing: false))
        }
        // In the Trash without an id to go by: only an item that looks as it did is taken.
        if let stamp = step.stamp, step.id == nil || itemIdOf(item) == nil {
            let now = readItemStamp(StampReader(fileSystem), step.from)
            // Found a moment ago, it couldn't be read just now; or a folder couldn't be listed just then. Either says
            // nothing about it: the step is kept, to be looked at again.
            guard let now, !(now.kind == .directory && now.entryCount == nil && stamp.entryCount != nil) else {
                return .refused(
                    Refusal(
                        reason: "\u{201C}\(NodePath.basename(step.from))\u{201D} couldn't be checked.", missing: false,
                        retry: true))
            }
            if !sameStamp(stamp, now) {
                return .refused(
                    Refusal(reason: replacedReason(step.from, nil, item, original: original), missing: false))
            }
        }
        let folderPath = NodePath.dirname(step.to)
        // Through a link, as when the step was recorded (see readFolderId).
        var folder: WriteServiceStats?
        switch lookUp(folderPath, { try fileSystem.stat($0) }) {
        case .unreadable(let refusal): return .refused(refusal)
        case .missing: folder = nil
        case .found(let stats): folder = stats
        }
        guard let folder, folder.isDirectory else {
            return .refused(
                Refusal(
                    reason: "Its folder \u{201C}\(NodePath.basename(folderPath))\u{201D} no longer exists.",
                    missing: false))
        }
        let folderId = itemIdOf(folder)
        if let parentId = step.parentId, let folderId, parentId != folderId {
            let name = NodePath.basename(folderPath)
            return .refused(
                Refusal(
                    reason: reconnected(parentId, folderId)
                        ? "Its folder \u{201C}\(name)\u{201D} is on a disk that was disconnected since, so it is left as it is."
                        : "Its folder \u{201C}\(name)\u{201D} was replaced by another folder.",
                    missing: false))
        }
        let kind = kindOfStats(item)
        let isFolder = kind == .directory
        let itemId = itemIdOf(item)
        var there: WriteServiceStats?
        switch lookUp(step.to, { try fileSystem.lstat($0) }) {
        case .unreadable(let refusal): return .refused(refusal)
        case .missing: there = nil
        case .found(let stats): there = stats
        }
        guard let there, !leavesBefore(there, step.to, changes) else {
            // Free by then, unless a step before puts another item there.
            let nameTaken = changes.filledPlaces.contains(placeKey(step.to))
            return .ok(nameTaken: nameTaken, renamesItself: false, isFolder: isFolder, id: itemId, kind: kind)
        }
        let renamesItself = findsItself(fileSystem, step, itemId, itemIdOf(there))
        return .ok(nameTaken: !renamesItself, renamesItself: renamesItself, isFolder: isFolder, id: itemId, kind: kind)
    }

    /// `findsItself`: on a disk that ignores case, "notes.txt" finds "Notes.txt": the item itself, not another in the
    /// way. As for a rename: the names match ignoring case and accent encoding, the ids are the same or there is none
    /// to go by (FAT, exFAT), and the folder doesn't list the name as it is spelled. Two hard links to one file, under
    /// two names, are two items.
    static func findsItself(
        _ fileSystem: some IdentityFileSystem, _ step: PlannedMove, _ itemId: ItemId?, _ thereId: ItemId?
    ) -> Bool {
        if placeKey(step.from) != placeKey(step.to) {
            return false
        }
        if let itemId, let thereId, itemId != thereId {
            return false
        }
        let name = NodePath.basename(step.to)
        let entries = try? fileSystem.readdir(NodePath.dirname(step.to))
        return !(entries?.contains { sameText($0, name) } ?? false)
    }

    /// `checkTrash`.
    public static func checkTrash(_ fileSystem: some IdentityFileSystem, _ step: PlannedTrash) -> TrashCheck {
        let item: WriteServiceStats
        switch lookUp(step.path, { try fileSystem.lstat($0) }) {
        case .unreadable(let refusal): return .refused(refusal)
        case .missing: return .refused(Refusal(reason: missingReason(fileSystem, step.path), missing: true))
        case .found(let stats): item = stats
        }
        if !isExpectedItem(item, step.id, step.stamp?.kind, relaxed: false) {
            return .refused(Refusal(reason: replacedReason(step.path, step.id, item), missing: false))
        }
        let id = itemIdOf(item)
        // Without an id or a stamp (the item couldn't be read once made), nothing tells the item at the path from
        // another one: it is asked about, not taken unasked.
        guard let stamp = step.stamp else {
            return .ok(changed: step.id == nil, id: id)
        }
        let now = readItemStamp(StampReader(fileSystem), step.path)
        return .ok(changed: now.map { !sameStamp(stamp, $0) } ?? true, id: id)
    }

    /// `sameStamp`: a folder is the same when it holds the same items, by name: its date changes with every item
    /// added or taken out, so a file moved into a new folder and back out (two Undos) would otherwise make it look
    /// changed; its items' names don't.
    static func sameStamp(_ left: ItemStamp, _ right: ItemStamp) -> Bool {
        if left.kind != right.kind {
            return false
        }
        if left.kind == .directory {
            return left.entryCount == right.entryCount
                && (left.entryNames == nil || right.entryNames == nil || left.entryNames == right.entryNames)
        }
        return left.size == right.size && left.mtimeMs == right.mtimeMs
    }

    /// `checkBatch`: each item of a batch on its own. Items of the batch make way for each other (a swap), so a name
    /// held by another item of it isn't taken.
    public static func checkBatch(_ fileSystem: some IdentityFileSystem, _ items: [BatchRenamedItem])
        -> [BatchItemCheck]
    {
        // Each item first as it is now: one refused stays where it is, holding its name, so only the items that go
        // back make way for the others.
        var sources: [BatchSource] = []
        for item in items {
            switch lookUp(item.from, { try fileSystem.lstat($0) }) {
            case .unreadable(let refusal):
                sources.append(
                    .checked(BatchItemCheck(item: item, refusal: refusal, nameTaken: false, isFolder: false)))
            case .missing:
                let refusal = Refusal(reason: missingReason(fileSystem, item.from), missing: true)
                sources.append(
                    .checked(BatchItemCheck(item: item, refusal: refusal, nameTaken: false, isFolder: false)))
            case .found(let stats):
                if !isExpectedItem(stats, item.id, item.itemKind, relaxed: true) {
                    let refusal = Refusal(reason: replacedReason(item.from, item.id, stats), missing: false)
                    sources.append(
                        .checked(BatchItemCheck(item: item, refusal: refusal, nameTaken: false, isFolder: false)))
                } else {
                    sources.append(.going(item, stats))
                }
            }
        }
        let goingBack = sources.compactMap { source -> BatchRenamedItem? in
            if case .going(let item, _) = source { return item }
            return nil
        }
        // Places the batch's own items leave, compared as the disk compares names, and the items themselves: on a
        // disk that ignores case, "B" finds the batch's own item now at "b".
        let vacated = Set(goingBack.map { NameKeys.Exact($0.from) })
        // Each item of the batch by id, with where it is: found under another spelling of that place it is the item
        // itself; elsewhere (a hard link to it) it is another entry.
        var ownPlaces: [ItemId: NameKeys.Exact] = [:]
        for item in goingBack {
            if let id = item.id { ownPlaces[id] = placeKey(item.from) }
        }
        var checks: [BatchItemCheck] = []
        for source in sources {
            guard case .going(let item, let stats) = source else {
                if case .checked(let check) = source { checks.append(check) }
                continue
            }
            // The name it goes back to, in the folder it is in now (its folder may be renamed back in the same batch,
            // after it).
            let target = "\(NodePath.dirname(item.from))/\(NodePath.basename(item.to))"
            var there: WriteServiceStats?
            if !vacated.contains(NameKeys.Exact(target)) {
                switch lookUp(target, { try fileSystem.lstat($0) }) {
                case .unreadable(let refusal):
                    checks.append(BatchItemCheck(item: item, refusal: refusal, nameTaken: false, isFolder: false))
                    continue
                case .missing: there = nil
                case .found(let stats): there = stats
                }
            }
            checks.append(
                BatchItemCheck(
                    item: item, refusal: nil, nameTaken: there.map { !isOwn($0, target, ownPlaces) } ?? false,
                    isFolder: kindOfStats(stats) == .directory))
        }
        return checks
    }

    private enum BatchSource {
        case checked(BatchItemCheck)
        case going(BatchRenamedItem, WriteServiceStats)
    }

    /// `isOwn`: whether the item found where a batch item goes back is the batch's own: the item itself, or another
    /// of its items (which makes way for it). The same id elsewhere is a hard link to it, another entry.
    private static func isOwn(_ there: WriteServiceStats, _ target: String, _ ownPlaces: [ItemId: NameKeys.Exact])
        -> Bool
    {
        guard let thereId = itemIdOf(there) else { return false }
        return ownPlaces[thereId] == placeKey(target)
    }

    // MARK: Questions

    /// `findQuestions`: what to ask before undoing `units`: the names that are taken where items would go back, and
    /// the items that would go to the Trash though they changed since. Checked as things will be by then: a step
    /// after one that can't be done isn't looked at, a place a step before it empties counts as free, and one a step
    /// before it fills as taken. It reads the disk: call it off the main actor.
    public static func findQuestions(_ fileSystem: some IdentityFileSystem, _ units: [UndoUnit]) -> UndoQuestions {
        // Units don't depend on each other, so several are looked at at once: an Undo of thousands of items would
        // otherwise wait for each item's disk reads in turn.
        let perUnit = mapAtMost(questionChecksAtOnce, Array(units.reversed())) { unitQuestions(fileSystem, $0) }
        return UndoQuestions(
            nameTaken: perUnit.flatMap(\.nameTaken), changed: perUnit.flatMap(\.changed))
    }

    /// `mapAtMost`: `run` for each of `items`, at most `limit` at a time, on threads of their own; the results in the
    /// items' order.
    static func mapAtMost<T: Sendable, R: Sendable>(_ limit: Int, _ items: [T], _ run: @Sendable (T) -> R) -> [R] {
        guard !items.isEmpty else { return [] }
        let next = OSAllocatedUnfairLock(initialState: 0)
        let results = OSAllocatedUnfairLock(initialState: [R?](repeating: nil, count: items.count))
        // Workers of their own, not `concurrentPerform`, which runs them one after another on a busy machine: a disk
        // that is slow to answer must not hold up the looks at the others.
        let workers = DispatchGroup()
        withoutActuallyEscaping(run) { run in
            for _ in 0..<min(limit, items.count) {
                DispatchQueue.global(qos: .userInitiated).async(group: workers) {
                    while true {
                        let index = next.withLock { value -> Int in
                            defer { value += 1 }
                            return value
                        }
                        guard index < items.count else { return }
                        let result = run(items[index])
                        results.withLock { $0[index] = result }
                    }
                }
            }
            workers.wait()
        }
        return results.withLock { $0.compactMap { $0 } }
    }

    private static func unitQuestions(_ fileSystem: some IdentityFileSystem, _ unit: UndoUnit) -> UndoQuestions {
        var questions = UndoQuestions()
        var changes = UnitChanges()
        steps: for step in unit.steps.reversed() {
            switch PlannedStep(reversing: step) {
            case .move(let planned):
                switch checkMove(fileSystem, planned, changes) {
                case .refused(let refusal):
                    if refusal.missing { continue steps }
                    break steps
                case .ok(let nameTaken, _, _, let id, _):
                    if nameTaken {
                        questions.nameTaken.append(TakenName(name: NodePath.basename(planned.to), path: planned.to))
                    }
                    changes.noteMovedAway(planned.from, id)
                    changes.filledPlaces.insert(placeKey(planned.to))
                }
            case .trash(let planned):
                switch checkTrash(fileSystem, planned) {
                case .refused(let refusal):
                    if refusal.missing { continue steps }
                    break steps
                case .ok(let changed, let id):
                    if changed {
                        questions.changed.append(
                            ChangedItem(
                                name: NodePath.basename(planned.path), path: planned.path, putBack: planned.putBack,
                                // A Replace's unit also has its old item's trip to the Trash.
                                replaced: !planned.putBack
                                    && unit.steps.contains {
                                        if case .trashed = $0 { return true }
                                        return false
                                    }))
                    }
                    changes.noteMovedAway(planned.path, id)
                }
            case .batch(let items):
                for check in checkBatch(fileSystem, items) where check.nameTaken {
                    let target = NodePath.join(
                        NodePath.dirname(check.item.from), NodePath.basename(check.item.to))
                    questions.nameTaken.append(TakenName(name: NodePath.basename(target), path: target))
                }
            }
        }
        return questions
    }
}
