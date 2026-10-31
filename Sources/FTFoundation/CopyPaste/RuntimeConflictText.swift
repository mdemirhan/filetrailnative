// Port of the words and answers of apps/desktop/src/renderer/components/CopyPasteRuntimeConflictDialog.tsx
// (describeConflict, the answers, FingerprintCard) and getCopyLikeVerb (components/AppDialogs.tsx:670)
import Foundation

/// The verb of a copy-like operation (`getCopyLikeVerb`).
public enum CopyLikeVerb: String, Equatable, Sendable {
    case paste = "Paste"
    case copy = "Copy"
    case move = "Move"
    case duplicate = "Duplicate"

    public init(_ action: WriteOperationAction) {
        switch action {
        case .moveTo: self = .move
        case .copyTo: self = .copy
        case .duplicate: self = .duplicate
        default: self = .paste
        }
    }

    /// `VERBING`: "pasting".
    public var verbing: String {
        switch self {
        case .paste: "pasting"
        case .copy: "copying"
        case .move: "moving"
        case .duplicate: "duplicating"
        }
    }

    /// `BEING`: what the card of the item on its way is called.
    public var being: String {
        switch self {
        case .paste: "Being pasted"
        case .copy: "Being copied"
        case .move: "Being moved"
        case .duplicate: "Being duplicated"
        }
    }
}

/// The question an operation paused on (`runtimeConflict`), as its alert reads it.
public struct RuntimeConflictInput: Equatable, Sendable {
    public var reason: RuntimeConflictReason
    public var conflictClass: ConflictClass
    public var sourcePath: String
    public var destinationPath: String
    public var currentSourceFingerprint: ReviewFingerprint
    public var currentDestinationFingerprint: ReviewFingerprint

    public init(
        reason: RuntimeConflictReason, conflictClass: ConflictClass, sourcePath: String, destinationPath: String,
        currentSourceFingerprint: ReviewFingerprint, currentDestinationFingerprint: ReviewFingerprint
    ) {
        self.reason = reason
        self.conflictClass = conflictClass
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.currentSourceFingerprint = currentSourceFingerprint
        self.currentDestinationFingerprint = currentDestinationFingerprint
    }
}

/// One answer of the alert: its title, and whether it is red.
public struct RuntimeConflictAnswer: Equatable, Sendable {
    public var choice: CopyPasteChoice
    public var title: String
    public var destructive: Bool
}

/// A card of the comparison (`FingerprintCard`).
public struct RuntimeConflictCard: Equatable, Sendable {
    public var label: String
    public var name: String
    public var facts: String
}

/// What the runtime conflict alert says and offers.
public struct RuntimeConflictText: Equatable, Sendable {
    public var title: String
    public var message: String
    /// The other answers, left to right.
    public var secondary: [RuntimeConflictAnswer]
    /// The safe answer: the default, on the right.
    public var primary: RuntimeConflictAnswer
    /// "Stop Pasting".
    public var stopLabel: String
    public var checkboxLabel: String
    /// "In “folder” now", then "Being pasted".
    public var cards: [RuntimeConflictCard]

    public init(_ conflict: RuntimeConflictInput, verb: CopyLikeVerb, now: Double, dates: ReviewDateText = .shared) {
        let name = CopyPasteReview.leafName(conflict.destinationPath)
        let folder = CopyPasteReview.leafName(CopyPasteReview.dirname(conflict.destinationPath))
        let destinationExists = conflict.currentDestinationFingerprint.exists
        let trashUnavailable = conflict.reason == .trashUnavailable
        let verbing = verb.verbing
        let choices = CopyPasteChoices.runtimeConflictChoices(
            reason: conflict.reason, conflictClass: conflict.conflictClass, destinationExists: destinationExists)
        // The safe answer is the default: Merge or Keep Both when there is something to keep, Skip rather than
        // deleting permanently, and going ahead when nothing is in the way.
        let primaryChoice: CopyPasteChoice =
            trashUnavailable
            ? .skip
            : choices.contains(.merge) ? .merge : choices.contains(.keepBoth) ? .keepBoth : (choices.first ?? .skip)
        func answer(_ choice: CopyPasteChoice) -> RuntimeConflictAnswer {
            let title: String
            if choice != .overwrite {
                title = CopyPasteReview.label(choice)
            } else if trashUnavailable {
                title = "Delete Permanently"
            } else {
                title = destinationExists ? CopyPasteReview.label(.overwrite) : "\(verb.rawValue) Anyway"
            }
            return RuntimeConflictAnswer(
                choice: choice, title: title, destructive: choice == .overwrite && destinationExists)
        }
        primary = answer(primaryChoice)
        secondary = choices.filter { $0 != primaryChoice }.map(answer)
        let described = Self.describe(conflict, name: name, folder: folder, verbing: verbing)
        title = described.title
        // Merging can't be undone: said wherever Merge is one of the answers.
        message =
            choices.contains(.merge) ? "\(described.message) Merging can\u{2019}t be undone." : described.message
        stopLabel = "Stop \(verbing.prefix(1).uppercased())\(verbing.dropFirst())"
        checkboxLabel =
            trashUnavailable
            ? "Do the same for other items that can\u{2019}t be moved to the Trash while \(verbing)"
            : "Do the same for similar changes while \(verbing)"
        cards = [
            RuntimeConflictCard(
                label: "In \u{201C}\(folder)\u{201D} now", name: name,
                facts: Self.facts(conflict.currentDestinationFingerprint, now: now, dates: dates)),
            RuntimeConflictCard(
                label: verb.being, name: CopyPasteReview.leafName(conflict.sourcePath),
                facts: Self.facts(conflict.currentSourceFingerprint, now: now, dates: dates)),
        ]
    }

    /// `describeConflict`: the title and message by reason.
    private static func describe(_ conflict: RuntimeConflictInput, name: String, folder: String, verbing: String)
        -> (title: String, message: String)
    {
        let sourceName = CopyPasteReview.leafName(conflict.sourcePath)
        let isFolder = conflict.currentDestinationFingerprint.kind == .directory
        switch conflict.reason {
        case .destinationCreated:
            return (
                "\u{201C}\(name)\u{201D} appeared in \u{201C}\(folder)\u{201D} while \(verbing)",
                "Another app created it after you reviewed this. Choose what to do with your item."
            )
        case .destinationChanged:
            return (
                "\u{201C}\(name)\u{201D} in \u{201C}\(folder)\u{201D} changed while \(verbing)",
                "It\u{2019}s different from when you reviewed this, so it\u{2019}s not replaced without asking."
            )
        case .destinationDeleted:
            return (
                "\u{201C}\(name)\u{201D} is no longer in \u{201C}\(folder)\u{201D}",
                "It was removed after you reviewed this, so there\u{2019}s nothing to replace or merge with. Choose whether to go on with your item."
            )
        case .sourceChanged:
            return (
                "\u{201C}\(sourceName)\u{201D} changed while \(verbing)",
                "It\u{2019}s different from when you reviewed this. Choose whether to use it now."
            )
        case .sourceDeleted:
            return (
                "\u{201C}\(sourceName)\u{201D} is no longer available",
                "It was moved or deleted after you reviewed this, so it can only be skipped."
            )
        case .trashUnavailable:
            let what = isFolder ? "folder" : "item"
            return (
                "Couldn\u{2019}t move \u{201C}\(name)\u{201D} to the Trash",
                "\u{201C}\(folder)\u{201D} is on a volume without a Trash, so replacing the existing \(what) means deleting it permanently. This can\u{2019}t be undone."
            )
        }
    }

    /// The card's facts: "Folder" or the size, and the date; "Not there anymore".
    private static func facts(_ fingerprint: ReviewFingerprint, now: Double, dates: ReviewDateText) -> String {
        guard fingerprint.exists else { return "Not there anymore" }
        var parts: [String] = []
        if fingerprint.kind == .directory {
            parts.append("Folder")
        } else if let size = fingerprint.size {
            parts.append(SizeText.size(size))
        }
        if let mtime = fingerprint.mtimeMs { parts.append(dates.format(mtime, now: now)) }
        return parts.filter { !$0.isEmpty }.joined(separator: " \u{B7} ")
    }
}
