// Port of apps/desktop/src/main/bootstrap/undoHistory.ts
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
}

/// What the Edit menu shows after "Undo " and "Redo " ("Move of “a.txt”"), or nil when there is nothing; `cantUndo`
/// when the last operation can't be undone.
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
    /// `UNDO_HISTORY_MAX_ITEM_STEPS`: how many item steps the Undo and Redo lists may hold together (each item of a
    /// batch rename is one): a few hundred bytes each, so a few hundred MB at most. Past it, the oldest operations are
    /// let go, never the one just done.
    public static let maxItemStepsDefault = 1_000_000

    private let maxItemSteps: Int
    private var undoList: [UndoEntry] = []
    private var redoList: [UndoEntry] = []
    // Set by an operation that can't be undone, until the next one that can.
    private var cantUndo = false
    private var nextId = 1
    /// Goes up with every change, so an Undo prepared before one is refused.
    public private(set) var generation = 0
    private var listeners: [Int: @MainActor () -> Void] = [:]
    private var nextListener = 0

    public init(maxItemSteps: Int = UndoHistory.maxItemStepsDefault) {
        self.maxItemSteps = maxItemSteps
    }

    private func changed() {
        generation += 1
        for (_, listener) in listeners.sorted(by: { $0.key < $1.key }) {
            listener()
        }
    }

    private func entryOf(_ units: [UndoUnit], _ action: WriteOperationAction, _ moves: Bool) -> UndoEntry {
        defer { nextId += 1 }
        return UndoEntry(id: nextId, action: action, units: units, moves: moves, size: Self.itemStepCount(units))
    }

    /// Lets go of the oldest operations, the bottom of the Undo list first, while the two lists hold more than they
    /// may; never those in `keep`, the ones just changed.
    private func keepWithinSize(_ keep: Set<Int>) {
        var size = undoList.reduce(0) { $0 + $1.size } + redoList.reduce(0) { $0 + $1.size }
        while size > maxItemSteps, let first = undoList.first, !keep.contains(first.id) {
            size -= undoList.removeFirst().size
        }
        while size > maxItemSteps, let first = redoList.first, !keep.contains(first.id) {
            size -= redoList.removeFirst().size
        }
    }

    /// `record`: a finished operation. One that can be undone goes on top and leaves nothing to redo; one that can't
    /// leaves nothing to undo either.
    public func record(_ finished: FinishedWrite) {
        // One that changed nothing leaves the history as it was (callers leave it out too).
        if case .undoable(let units) = finished.log, units.isEmpty {
            return
        }
        redoList.removeAll()
        // (Emptying the Trash is never undoable.)
        guard case .write(let action) = finished.action, case .undoable(let units) = finished.log else {
            undoList.removeAll()
            cantUndo = true
            changed()
            return
        }
        let entry = entryOf(units, action, Self.movesAnything(units))
        undoList.append(entry)
        keepWithinSize([entry.id])
        cantUndo = false
        changed()
    }

    public func top(_ direction: UndoDirection) -> UndoEntry? {
        direction == .undo ? undoList.last : redoList.last
    }

    /// `finish`: an Undo or Redo of `entryId` ended. `done` is what it did, in the order it did it, which is what the
    /// other direction reverses; `leftover` is what a stop left to do and what failed to be written, kept on top so
    /// the next Undo goes on from there. What the disk check refused (changed outside the app) is dropped.
    public func finish(_ direction: UndoDirection, entryId: Int, done: [UndoUnit], leftover: [UndoUnit]) throws {
        let list = direction == .undo ? undoList : redoList
        // Nothing else can change the history while an Undo holds the write slot.
        guard let entry = list.last, entry.id == entryId else {
            let verb = direction == .undo ? "undone" : "redone"
            throw UndoHistoryError(
                message:
                    "The \(direction.command) list changed while one of its operations was being \(verb).")
        }
        var kept: Set<Int> = []
        var own = list
        own.removeLast()
        if !leftover.isEmpty {
            var left = entry
            left.units = leftover
            left.size = Self.itemStepCount(leftover)
            own.append(left)
            kept.insert(left.id)
        }
        if direction == .undo { undoList = own } else { redoList = own }
        // Each try is its own entry on the other list: what it did, exactly, so the other command puts back where
        // each item was before it, whatever was tried after it.
        if !done.isEmpty {
            let doneEntry = entryOf(done, entry.action, entry.moves)
            if direction == .undo { redoList.append(doneEntry) } else { undoList.append(doneEntry) }
            kept.insert(doneEntry.id)
        }
        keepWithinSize(kept)
        changed()
    }

    /// `menu`: named after what is left to do: a stopped Undo of 3 items leaves "of 2 Items".
    public func menu() -> UndoMenuLabels {
        UndoMenuLabels(
            undo: undoList.last.map { Self.labelOf($0.action, $0.units, moves: $0.moves) },
            redo: redoList.last.map { Self.labelOf($0.action, $0.units, moves: $0.moves) },
            cantUndo: cantUndo && undoList.isEmpty)
    }

    /// `onChange`: returns what stops listening.
    @discardableResult
    public func onChange(_ listener: @escaping @MainActor () -> Void) -> @MainActor () -> Void {
        let token = nextListener
        nextListener += 1
        listeners[token] = listener
        return { [weak self] in self?.listeners[token] = nil }
    }

    /// The lists, oldest first, for tests.
    var entries: (undo: [UndoEntry], redo: [UndoEntry]) { (undoList, redoList) }

    // MARK: Labels

    /// `labelOf`: "Rename", "Move of “a.txt”", "Copy of 3 Items"…: what the Edit menu puts after "Undo". A paste is
    /// a Move when it `moves` anything, a Copy otherwise.
    public nonisolated static func labelOf(_ action: WriteOperationAction, _ units: [UndoUnit], moves: Bool? = nil)
        -> String
    {
        switch action {
        case .rename:
            return "Rename"
        case .batchRename:
            let count = itemStepCount(units)
            return count == 1 ? "Rename" : "Rename of \(count) Items"
        case .newFolder:
            return "New Folder"
        case .trash:
            return "Move to Trash of \(itemsName(units))"
        case .duplicate:
            return "Duplicate of \(itemsName(units))"
        case .moveTo:
            return "Move of \(itemsName(units))"
        case .copyTo:
            return "Copy of \(itemsName(units))"
        default:
            return "\((moves ?? movesAnything(units)) ? "Move" : "Copy") of \(itemsName(units))"
        }
    }

    /// `itemStepCount`: how many steps `units` hold, each item of a batch rename counted as one: what an Undo's
    /// progress counts, and what the history's size is kept by.
    public nonisolated static func itemStepCount(_ units: [UndoUnit]) -> Int {
        var count = 0
        for unit in units {
            for step in unit.steps {
                if case .batchRenamed(let items) = step {
                    count += items.count
                } else {
                    count += 1
                }
            }
        }
        return count
    }

    nonisolated static func movesAnything(_ units: [UndoUnit]) -> Bool {
        units.contains { unit in
            unit.steps.contains { step in
                if case .moved(let moved) = step { return moved.fromTrash != true }
                return false
            }
        }
    }

    /// “a.txt” for one item, "3 Items" for more.
    private nonisolated static func itemsName(_ units: [UndoUnit]) -> String {
        guard units.count == 1 else { return "\(units.count) Items" }
        guard let path = mainPathOf(units[0].steps) else { return "1 Item" }
        return "\u{201C}\(NodePath.basename(path))\u{201D}"
    }

    /// The item a unit is about: what was made or moved, or else what went to the Trash.
    private nonisolated static func mainPathOf(_ steps: [UndoStep]) -> String? {
        for step in steps.reversed() {
            switch step {
            case .created(let path, _, _): return path
            case .moved(let moved): return moved.to
            case .trashed(let from, _, _, _, _): return from
            case .batchRenamed: continue
            }
        }
        return nil
    }
}
