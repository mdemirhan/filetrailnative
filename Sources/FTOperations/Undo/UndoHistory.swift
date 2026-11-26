import FTFoundation
import Foundation

/// One operation that can be undone (or, once undone, done again).
public struct UndoEntry: Equatable, Sendable {
    public var id: Int
    public var action: WriteOperationAction
    public var units: [UndoUnit]
    /// Whether it moved anything, so a paste is named a Move for as long as it is in the history: what a stop leaves
    /// of a moving Replace may be only its trip to the Trash.
    public var moves: Bool
    /// How many item steps it holds (`itemStepCount`), for keeping the history's size.
    public var size: Int
    /// When it was done or, on the Redo list, undone: what the history's list shows.
    public var date: Date
}

/// An operation that couldn't be undone, kept in the history where it happened: what it was, when, and why it can't
/// be undone. Undo stops at it once, to say so (`passed`), and then goes on to the operations before it.
public struct CantUndoEntry: Equatable, Sendable {
    public var id: Int
    public var action: FinishedWrite.Action
    /// Why it can't be undone; nil for emptying the Trash.
    public var reason: CantUndoReason?
    public var date: Date
    /// Whether Undo has said that it can't be undone: the next Undo goes on to the operation before it.
    public var passed = false

    public init(id: Int, action: FinishedWrite.Action, reason: CantUndoReason?, date: Date, passed: Bool = false) {
        self.id = id
        self.action = action
        self.reason = reason
        self.date = date
        self.passed = passed
    }
}

/// One thing in the Undo list: an operation Undo can undo, or one it can't.
public enum UndoHistoryItem: Equatable, Sendable {
    case entry(UndoEntry)
    case cantUndo(CantUndoEntry)

    var id: Int {
        switch self {
        case .entry(let entry): entry.id
        case .cantUndo(let entry): entry.id
        }
    }

    /// What it counts for in the history's size: its item steps, or one.
    var size: Int {
        switch self {
        case .entry(let entry): entry.size
        case .cantUndo: 1
        }
    }
}

/// What the Edit menu shows after "Undo " and "Redo " ("Move of “a.txt”"), or nil when there is nothing; `cantUndo`
/// when the next thing Undo meets is an operation that can't be undone, which it then says, undoing nothing.
public struct UndoMenuLabels: Equatable, Sendable {
    public var undo: String?
    public var redo: String?
    public var cantUndo: Bool

    public init(undo: String?, redo: String?, cantUndo: Bool) {
        self.undo = undo
        self.redo = redo
        self.cantUndo = cantUndo
    }
}

/// The history refused to finish an entry that is no longer on top of its list.
public struct UndoHistoryError: Error, Equatable, Sendable, CustomStringConvertible, LocalizedError {
    public var message: String
    public var description: String { message }
    public var errorDescription: String? { message }
}

/// The operations that can be undone and redone, newest last, for as long as the app runs (up to
/// `maxItemStepsDefault`). Kept in memory only: nothing is written to disk, and quitting forgets them, as Finder does.
///
/// Only what an operation really did is kept, and nothing in here is trusted when undoing: every step is checked on
/// disk first (see UndoPlan.swift).
@MainActor
public final class UndoHistory {
    /// How many item steps the Undo and Redo lists may hold together (each item of a
    /// batch rename is one): a few hundred bytes each, so a few hundred MB at most. Past it, the oldest operations are
    /// let go, never the one just done.
    public static let maxItemStepsDefault = 1_000_000

    private let maxItemSteps: Int
    private let clock: () -> Date
    /// The operations done, oldest first: those Undo can undo and, where they happened among them, those it can't.
    private var undoList: [UndoHistoryItem] = []
    private var redoList: [UndoEntry] = []
    private var nextId = 1
    /// Goes up with every change, so an Undo prepared before one is refused.
    public private(set) var generation = 0
    private var listeners: [Int: @MainActor () -> Void] = [:]
    private var nextListener = 0

    public init(maxItemSteps: Int = UndoHistory.maxItemStepsDefault, clock: @escaping () -> Date = { AppClock.now }) {
        self.maxItemSteps = maxItemSteps
        self.clock = clock
    }

    private func changed() {
        generation += 1
        for (_, listener) in listeners.sorted(by: { $0.key < $1.key }) {
            listener()
        }
    }

    private func entryOf(_ units: [UndoUnit], _ action: WriteOperationAction, _ moves: Bool) -> UndoEntry {
        defer { nextId += 1 }
        return UndoEntry(
            id: nextId, action: action, units: units, moves: moves, size: Self.itemStepCount(units), date: clock())
    }

    /// Lets go of the oldest operations, the bottom of the Undo list first, while the two lists hold more than they
    /// may; never those in `keep`, the ones just changed.
    /// Every entry, on both lists, knowing the items in `ids` by the ids they map to (`UndoPlan.remapIds`).
    private func renumber(_ ids: [ItemId: ItemId]) {
        for index in undoList.indices {
            if case .entry(var entry) = undoList[index] {
                entry.units = UndoPlan.remapIds(entry.units, ids)
                undoList[index] = .entry(entry)
            }
        }
        for index in redoList.indices {
            redoList[index].units = UndoPlan.remapIds(redoList[index].units, ids)
        }
    }

    private func keepWithinSize(_ keep: Set<Int>) {
        var size = undoList.reduce(0) { $0 + $1.size } + redoList.reduce(0) { $0 + $1.size }
        while size > maxItemSteps, let first = undoList.first, !keep.contains(first.id) {
            size -= undoList.removeFirst().size
        }
        while size > maxItemSteps, let first = redoList.first, !keep.contains(first.id) {
            size -= redoList.removeFirst().size
        }
    }

    /// `record`: a finished operation, on top, leaving nothing to redo. One that can't be undone is kept as what it
    /// was and why, and the operations before it stay: Undo says it can't be undone, once, and then goes on to them.
    public func record(_ finished: FinishedWrite) {
        // One that changed nothing leaves the history as it was (callers leave it out too).
        if case .undoable(let units) = finished.log, units.isEmpty {
            return
        }
        redoList.removeAll()
        // (Emptying the Trash is never undoable.)
        guard case .write(let action) = finished.action, case .undoable(let units) = finished.log else {
            var reason: CantUndoReason?
            if case .notUndoable(let why) = finished.log { reason = why }
            let entry = CantUndoEntry(id: nextId, action: finished.action, reason: reason, date: clock())
            nextId += 1
            undoList.append(.cantUndo(entry))
            keepWithinSize([entry.id])
            changed()
            return
        }
        let entry = entryOf(units, action, Self.movesAnything(units))
        undoList.append(.entry(entry))
        keepWithinSize([entry.id])
        changed()
    }

    /// `replaceTop`: the operation on top of the Undo list, `entryId`, holds `units` now: the permissions popover's
    /// one entry for each time it is open, given each change made while it is. Taken out when `units` is empty (every
    /// item is back as it was). Nothing changes, and it answers false, when `entryId` isn't on top: Undo took it, or
    /// another operation came after it.
    @discardableResult
    public func replaceTop(_ entryId: Int, units: [UndoUnit]) -> Bool {
        guard case .entry(var entry) = undoList.last, entry.id == entryId else { return false }
        if units.isEmpty {
            undoList.removeLast()
        } else {
            entry.units = units
            entry.size = Self.itemStepCount(units)
            entry.date = clock()
            undoList[undoList.count - 1] = .entry(entry)
            keepWithinSize([entry.id])
        }
        changed()
        return true
    }

    /// Where in the Undo list the next thing Undo meets is: the newest operation, past those that can't be undone
    /// and were said so.
    private var nextUndoIndex: Int? {
        undoList.lastIndex { item in
            if case .cantUndo(let entry) = item { return !entry.passed }
            return true
        }
    }

    /// The operation Undo (or Redo) takes next; nil for Undo while the next thing it meets can't be undone
    /// (`cantUndoNext`).
    public func top(_ direction: UndoDirection) -> UndoEntry? {
        guard direction == .undo else { return redoList.last }
        guard let index = nextUndoIndex, case .entry(let entry) = undoList[index] else { return nil }
        return entry
    }

    /// `needsExactItems`: whether the operation Undo takes next was done before one that can't be undone (and was
    /// passed). That one may have taken its items away and left others of the same kind under their names (a move
    /// to another disk and one back): its Undo takes only the very items, by id, where an Undo otherwise
    /// takes an item of the same kind under the same name for one it moves or renames back. Never for Redo.
    public func needsExactItems(_ direction: UndoDirection) -> Bool {
        guard direction == .undo, let index = nextUndoIndex, case .entry = undoList[index] else { return false }
        return index < undoList.count - 1
    }

    /// The operation that can't be undone which Undo meets next: Undo says so and undoes nothing (`passCantUndo`).
    public var cantUndoNext: CantUndoEntry? {
        guard let index = nextUndoIndex, case .cantUndo(let entry) = undoList[index] else { return nil }
        return entry
    }

    /// `passCantUndo`: Undo met the operation that can't be undone and said so: the next Undo goes on to the
    /// operation before it. It stays in the list. Returns it, or nil when Undo doesn't meet one next.
    @discardableResult
    public func passCantUndo() -> CantUndoEntry? {
        guard let index = nextUndoIndex, case .cantUndo(var entry) = undoList[index] else { return nil }
        entry.passed = true
        undoList[index] = .cantUndo(entry)
        changed()
        return entry
    }

    /// `entries`: the operations of one list that can be undone or redone, oldest first.
    public func entries(_ direction: UndoDirection) -> [UndoEntry] {
        guard direction == .undo else { return redoList }
        return undoList.compactMap { item in
            if case .entry(let entry) = item { return entry }
            return nil
        }
    }

    /// `undoItems`: the Undo list as it happened, oldest first: its operations, and those that can't be undone among
    /// them.
    public func undoItems() -> [UndoHistoryItem] { undoList }

    /// `finish`: an Undo or Redo of `entryId` ended. `done` is what it did, in the order it did it, which is what the
    /// other direction reverses; `leftover` is what a stop left to do and what failed to be written, kept on top so
    /// the next Undo goes on from there. What the disk check refused (changed outside the app) is dropped.
    /// `remade`: the folders the Undo made again for merges' items, by the id each had to the one it has now. Every
    /// other step that knew one by its old id knows it by the new one: the folder it knew is gone, and the one made in
    /// its place is where its items went back.
    public func finish(
        _ direction: UndoDirection, entryId: Int, done: [UndoUnit], leftover: [UndoUnit],
        remade: [ItemId: ItemId] = [:]
    ) throws {
        // Nothing else can change the history while an Undo holds the write slot.
        guard let entry = top(direction), entry.id == entryId else {
            let verb = direction == .undo ? "undone" : "redone"
            throw UndoHistoryError(
                message:
                    "The \(direction.command) list changed while something on it was being \(verb).")
        }
        if !remade.isEmpty {
            renumber(remade)
        }
        var kept: Set<Int> = []
        var left: UndoEntry?
        if !leftover.isEmpty {
            var rest = entry
            rest.units = UndoPlan.remapIds(leftover, remade)
            rest.size = Self.itemStepCount(leftover)
            left = rest
            kept.insert(rest.id)
        }
        // What is left stays where the operation was: under any that can't be undone and were passed.
        if direction == .redo {
            redoList.removeLast()
            if let left { redoList.append(left) }
        } else if let index = nextUndoIndex {
            if let left { undoList[index] = .entry(left) } else { undoList.remove(at: index) }
        }
        // Each try is its own entry on the other list: what it did, exactly, so the other command puts back where
        // each item was before it, whatever was tried after it.
        if !done.isEmpty {
            let doneEntry = entryOf(done, entry.action, entry.moves)
            if direction == .undo { redoList.append(doneEntry) } else { undoList.append(.entry(doneEntry)) }
            kept.insert(doneEntry.id)
        }
        keepWithinSize(kept)
        changed()
    }

    /// `menu`: named after what is left to do: a stopped Undo of 3 items leaves "of 2 Items". `whole`: with a long
    /// name whole, for a notice or a tooltip; a menu's item shortens it.
    public func menu(whole: Bool = false) -> UndoMenuLabels {
        UndoMenuLabels(
            undo: top(.undo).map { Self.labelOf($0.action, $0.units, moves: $0.moves, inMenu: !whole) },
            redo: redoList.last.map { Self.labelOf($0.action, $0.units, moves: $0.moves, inMenu: !whole) },
            cantUndo: cantUndoNext != nil)
    }

    /// `onChange`: returns what stops listening.
    @discardableResult
    public func onChange(_ listener: @escaping @MainActor () -> Void) -> @MainActor () -> Void {
        let token = nextListener
        nextListener += 1
        listeners[token] = listener
        return { [weak self] in self?.listeners[token] = nil }
    }

    // MARK: Labels

    /// `labelOf`: "Rename", "Move of “a.txt”", "Copy of 3 Items"…: what the Edit menu puts after "Undo". A paste is
    /// a Move when it `moves` anything, a Copy otherwise. `inMenu`: a long name is shortened, as the menus show names.
    public nonisolated static func labelOf(
        _ action: WriteOperationAction, _ units: [UndoUnit], moves: Bool? = nil, inMenu: Bool = false
    ) -> String {
        switch action {
        case .rename:
            return "Rename"
        case .batchRename:
            let count = itemStepCount(units)
            return count == 1 ? "Rename" : "Rename of \(FormatLocale.count(count)) Items"
        case .newFolder:
            return "New Folder"
        case .newFolderWithSelection:
            return "New Folder with Selection"
        case .pasteAsFile:
            return "Paste as File"
        case .newFile:
            return "New File"
        case .compress:
            return "Compress"
        case .extract:
            return "Extract"
        case .convertImages:
            let count = itemStepCount(units)
            return count == 1 ? "Convert Image" : "Convert \(FormatLocale.count(count)) Images"
        case .makeAlias:
            let count = itemStepCount(units)
            return count == 1 ? "Make Alias" : "Make \(FormatLocale.count(count)) Aliases"
        case .changePermissions:
            let count = itemStepCount(units)
            guard count == 1, let path = units.first.flatMap({ mainPathOf($0.steps) }) else {
                return "Permissions of \(FormatLocale.count(count)) Items"
            }
            let name = NodePath.basename(path)
            return "Permissions of \(inMenu ? MenuName.quoted(name) : "\u{201C}\(name)\u{201D}")"
        case .changeTags:
            let count = itemStepCount(units)
            guard count == 1, let path = units.first.flatMap({ mainPathOf($0.steps) }) else {
                return "Tags of \(FormatLocale.count(count)) Items"
            }
            let name = NodePath.basename(path)
            return "Tags of \(inMenu ? MenuName.quoted(name) : "\u{201C}\(name)\u{201D}")"
        case .trash:
            return "Move to Trash of \(itemsName(units, inMenu: inMenu))"
        case .duplicate:
            return "Duplicate of \(itemsName(units, inMenu: inMenu))"
        case .moveTo:
            return "Move of \(itemsName(units, inMenu: inMenu))"
        case .copyTo:
            return "Copy of \(itemsName(units, inMenu: inMenu))"
        default:
            return "\((moves ?? movesAnything(units)) ? "Move" : "Copy") of \(itemsName(units, inMenu: inMenu))"
        }
    }

    /// `itemStepCount`: how many steps `units` hold, each item of a batch rename or of a change of permissions
    /// counted as one, and each of a merged folder's, with the folder itself when it is made again or removed: what an
    /// Undo's progress counts, and what the history's size is kept by.
    public nonisolated static func itemStepCount(_ units: [UndoUnit]) -> Int {
        var count = 0
        for unit in units {
            for step in unit.steps {
                switch step {
                case .batchRenamed(let items): count += items.count
                case .permissions(let items): count += items.count
                case .tags(let items): count += items.count
                case .merged(let merged):
                    count +=
                        itemStepCount(merged.units) + (merged.removed != nil ? 1 : 0) + (merged.made != nil ? 1 : 0)
                case .moved, .created, .trashed: count += 1
                }
            }
        }
        return count
    }

    nonisolated static func movesAnything(_ units: [UndoUnit]) -> Bool {
        units.contains { unit in
            unit.steps.contains { step in
                switch step {
                case .moved(let moved): moved.fromTrash != true
                case .merged(let merged): merged.removed != nil || merged.made != nil || movesAnything(merged.units)
                case .created, .trashed, .batchRenamed, .permissions, .tags: false
                }
            }
        }
    }

    /// “a.txt” for one item, "3 Items" for more.
    /// `inMenu`: a long name is shortened, as the menus show names (`MenuName`).
    private nonisolated static func itemsName(_ units: [UndoUnit], inMenu: Bool) -> String {
        guard units.count == 1 else { return "\(FormatLocale.count(units.count)) Items" }
        guard let path = mainPathOf(units[0].steps) else { return "1 Item" }
        let name = NodePath.basename(path)
        return inMenu ? MenuName.quoted(name) : "\u{201C}\(name)\u{201D}"
    }

    /// The item a unit is about: what was made or moved, or else what went to the Trash.
    private nonisolated static func mainPathOf(_ steps: [UndoStep]) -> String? {
        for step in steps.reversed() {
            switch step {
            case .created(let path, _, _): return path
            case .moved(let moved): return moved.to
            case .trashed(let from, _, _, _, _): return from
            case .batchRenamed: continue
            case .permissions(let items): if let item = items.first { return item.path }
            case .tags(let items): if let item = items.first { return item.path }
            case .merged(let merged): return merged.to
            }
        }
        return nil
    }
}
