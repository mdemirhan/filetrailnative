// Port of apps/desktop/src/renderer/lib/undoQuestion.ts (and UndoDirection of packages/contracts/src/ipc.ts)
import Foundation

/// Which list a file Undo works from: Undo, or Redo once something was undone.
public enum UndoDirection: String, Sendable, Equatable, CaseIterable {
    case undo, redo

    /// "Undo" or "Redo".
    public var command: String { self == .undo ? "Undo" : "Redo" }
}

/// What an Undo (or Redo) asks before it starts. Each question is all or nothing: the Undo goes ahead as a whole, or
/// nothing happens, so it is never left half done by an answer.
public enum UndoQuestion: Equatable, Sendable {
    /// Items whose old names other items have taken since: they go back with a number.
    case nameTaken(names: [String])
    /// Items that changed since and would go to the Trash.
    case changed(items: [ChangedItem])

    public struct ChangedItem: Equatable, Sendable {
        public var name: String
        public var putBack: Bool
        public var replaced: Bool

        public init(name: String, putBack: Bool, replaced: Bool) {
            self.name = name
            self.putBack = putBack
            self.replaced = replaced
        }
    }

    /// Names listed under the question (`LISTED_NAMES` of `UndoQuestionAlert`); more are counted.
    public static let listedNameLimit = 5

    /// The names of the items it is about, in order.
    public var names: [String] {
        switch self {
        case .nameTaken(let names): names
        case .changed(let items): items.map(\.name)
        }
    }

    /// The lines listed under the question (`UndoQuestionAlert`): when it is about several items, up to 5 names, then
    /// "and N more". One item is named in the title, so nothing is listed. Two items can have one name (from different
    /// folders): each is listed.
    public var listedNames: [String] {
        let names = self.names
        guard names.count > 1 else { return [] }
        let listed = Array(names.prefix(Self.listedNameLimit))
        let unlisted = names.count - listed.count
        guard unlisted > 0 else { return listed }
        // `toLocaleString()`: thousands separated.
        let count = unlisted.formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US")))
        return listed + ["and \(count) more"]
    }
}

/// The words of an undo question (`UndoQuestionText`).
public struct UndoQuestionText: Equatable, Sendable {
    public var title: String
    public var message: String
    /// The button that goes ahead.
    public var confirmLabel: String
    /// Whether going ahead is the default (Return). Moving changed work to the Trash isn't: a reflex Return then
    /// leaves everything as it is.
    public var confirmIsDefault: Bool

    public init(title: String, message: String, confirmLabel: String, confirmIsDefault: Bool) {
        self.title = title
        self.message = message
        self.confirmLabel = confirmLabel
        self.confirmIsDefault = confirmIsDefault
    }

    /// `describeUndoQuestion`: the question in the words of what it undoes: "“1 copy.kt” was changed after it was
    /// duplicated", rather than only "changed since".
    public static func of(_ question: UndoQuestion, direction: UndoDirection, action: WriteOperationAction?)
        -> UndoQuestionText
    {
        let verb = direction.command
        switch question {
        case .nameTaken(let names):
            let one = names.count == 1 ? names[0] : nil
            return UndoQuestionText(
                title: one.map { "An item named \u{201C}\($0)\u{201D} is already where it would go back." }
                    ?? "\(names.count) items have names that other items have taken where they would go back.",
                message: one != nil
                    ? "\(verb) puts it back with a number added to its name."
                    : "\(verb) puts them back with a number added to their names.",
                confirmLabel: "Keep Both", confirmIsDefault: true)
        case .changed(let items):
            return changedText(items, verb: verb, action: action)
        }
    }

    private static func changedText(_ items: [UndoQuestion.ChangedItem], verb: String, action: WriteOperationAction?)
        -> UndoQuestionText
    {
        let one = items.count == 1 ? items[0].name : nil
        let count = items.count
        func text(_ title: String, _ message: String) -> UndoQuestionText {
            UndoQuestionText(title: title, message: message, confirmLabel: "Move to Trash", confirmIsDefault: false)
        }
        if items.allSatisfy(\.putBack) {
            return one.map {
                text(
                    "\u{201C}\($0)\u{201D} was changed after it was put back.",
                    "\(verb) moves it to the Trash again, along with your changes.")
            }
                ?? text(
                    "\(count) items were changed after they were put back.",
                    "\(verb) moves them to the Trash again, along with your changes.")
        }
        if items.allSatisfy(\.replaced) {
            return one.map {
                text(
                    "\u{201C}\($0)\u{201D} was changed after it replaced the old one.",
                    "Undoing moves it to the Trash, along with your changes, and puts the old \u{201C}\($0)\u{201D} back."
                )
            }
                ?? text(
                    "\(count) items were changed after they replaced the old ones.",
                    "Undoing moves them to the Trash, along with your changes, and puts the old ones back.")
        }
        let made = items.allSatisfy { !$0.putBack && !$0.replaced }
        if made && action == .duplicate {
            return one.map {
                text(
                    "\u{201C}\($0)\u{201D} was changed after it was duplicated.",
                    "Undoing the duplicate moves this copy to the Trash, along with your changes. The original isn\u{2019}t affected."
                )
            }
                ?? text(
                    "\(count) copies were changed after they were duplicated.",
                    "Undoing the duplicate moves these copies to the Trash, along with your changes. The originals aren\u{2019}t affected."
                )
        }
        if made && (action == .copyTo || action == .paste) {
            return one.map {
                text(
                    "\u{201C}\($0)\u{201D} was changed after it was copied.",
                    "Undoing the copy moves it to the Trash, along with your changes. The original isn\u{2019}t affected."
                )
            }
                ?? text(
                    "\(count) copies were changed after they were copied.",
                    "Undoing the copy moves them to the Trash, along with your changes. The originals aren\u{2019}t affected."
                )
        }
        if made && action == .newFolder, let one {
            return text(
                "\u{201C}\(one)\u{201D} isn\u{2019}t empty anymore.",
                "Undoing New Folder moves it to the Trash, along with what you put in it.")
        }
        return one.map {
            text(
                "\u{201C}\($0)\u{201D} was changed after this was done.",
                "\(verb) moves it to the Trash, along with your changes.")
        }
            ?? text(
                "\(count) items were changed after this was done.",
                "\(verb) moves them to the Trash, along with your changes.")
    }
}
