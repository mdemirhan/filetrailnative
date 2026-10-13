// Port of packages/contracts/src/copyPasteChoices.ts
import Foundation

public enum CopyPasteChoice: String, Codable, CaseIterable, Sendable {
    case overwrite
    case merge
    case keepBoth = "keep_both"
    case skip
}

public enum ConflictClass: String, Codable, CaseIterable, Sendable {
    case fileConflict = "file_conflict"
    case directoryConflict = "directory_conflict"
    case typeMismatch = "type_mismatch"
}

public enum RuntimeConflictReason: String, Codable, CaseIterable, Sendable {
    case destinationChanged = "destination_changed"
    case destinationCreated = "destination_created"
    case destinationDeleted = "destination_deleted"
    case sourceChanged = "source_changed"
    case sourceDeleted = "source_deleted"
    case trashUnavailable = "trash_unavailable"
}

/// The choice "for all conflicts" of each kind.
public struct CopyPastePolicy: Codable, Equatable, Sendable {
    public var file: CopyPasteChoice
    public var directory: CopyPasteChoice
    public var mismatch: CopyPasteChoice

    public init(file: CopyPasteChoice, directory: CopyPasteChoice, mismatch: CopyPasteChoice) {
        self.file = file
        self.directory = directory
        self.mismatch = mismatch
    }
}

public enum CopyPasteChoices {
    /// The choices that make sense for a conflict of this kind ("merge" needs two folders).
    public static func isChoiceAllowed(for conflictClass: ConflictClass, _ choice: CopyPasteChoice) -> Bool {
        choice != .merge || conflictClass == .directoryConflict
    }

    /// What the paste does with a conflict: the item's own choice from the review, when it made one that
    /// fits, or else the choice for all conflicts of its kind. Replace can't take an item that isn't
    /// replaceable (the folder holding what is pasted, or another item being pasted): that item gets the
    /// safe choice instead, Merge for a folder and Keep Both otherwise. The review sheet and the paste
    /// both decide here, so the sheet says what the paste will do.
    public static func choiceForConflict(
        conflictClass: ConflictClass, replaceBlockedReason: String?, policy: CopyPastePolicy,
        override: CopyPasteChoice?
    ) -> CopyPasteChoice {
        let choice: CopyPasteChoice
        if let override, isChoiceAllowed(for: conflictClass, override) {
            choice = override
        } else {
            switch conflictClass {
            case .directoryConflict: choice = policy.directory
            case .typeMismatch: choice = policy.mismatch
            case .fileConflict: choice = policy.file
            }
        }
        if choice == .overwrite && replaceBlockedReason != nil {
            return conflictClass == .directoryConflict ? .merge : .keepBoth
        }
        return choice
    }

    /// The answers offered when something changed during an operation.
    /// - A missing source can only be skipped.
    /// - With nothing at the destination any more, there is nothing to keep or merge with: the item can
    ///   go ahead ("overwrite" just writes it) or be skipped.
    /// - When the Trash is unavailable, "overwrite" means deleting the existing item permanently.
    public static func runtimeConflictChoices(
        reason: RuntimeConflictReason, conflictClass: ConflictClass, destinationExists: Bool? = nil
    ) -> [CopyPasteChoice] {
        if reason == .sourceDeleted {
            return [.skip]
        }
        if reason == .trashUnavailable || destinationExists == false {
            return [.overwrite, .skip]
        }
        return conflictClass == .directoryConflict
            ? [.overwrite, .merge, .keepBoth, .skip] : [.overwrite, .keepBoth, .skip]
    }

    /// "Do the same for any other changes" only carries over to conflicts of the same kind: an answer
    /// about a changed source says nothing about a file someone else put at the destination, and a
    /// folder answer says nothing about a file.
    public static func runtimeConflictScope(
        reason: RuntimeConflictReason, conflictClass: ConflictClass, destinationExists: Bool? = nil
    ) -> String {
        if reason == .trashUnavailable {
            return "trash_unavailable"
        }
        let side = reason.rawValue.hasPrefix("source_") ? "source" : "destination"
        let destination = destinationExists == false ? "missing" : conflictClass.rawValue
        return "\(side):\(destination)"
    }
}
