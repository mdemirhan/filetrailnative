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
    /// Set for Replace Older: the files' Replace takes only a file newer than the one there, by more than this many
    /// milliseconds (`CopyPasteChoices.newerToleranceMs`, how far the disks blur a date); the others are skipped. It
    /// doesn't touch a choice made for one item.
    public var replaceOlderToleranceMs: Double?

    public init(
        file: CopyPasteChoice, directory: CopyPasteChoice, mismatch: CopyPasteChoice,
        replaceOlderToleranceMs: Double? = nil
    ) {
        self.file = file
        self.directory = directory
        self.mismatch = mismatch
        self.replaceOlderToleranceMs = replaceOlderToleranceMs
    }
}

/// Why Replace Older leaves an item that has no choice of its own.
public enum ReplaceOlderSkip: Equatable, Sendable {
    /// A file no newer than the one there.
    case notNewer
    /// A package clashing with one there. A package's date is its outer folder's, which stays as it was when
    /// something deeper inside changes (a virtual machine's disk, a photo library's database), so the dates say
    /// neither that it is newer nor that it isn't.
    case packageNotCompared
}

/// The modification dates of the item pasted and of the one there, which Replace Older compares.
public struct ModifiedDates: Equatable, Sendable {
    public var sourceMs: Double?
    public var destinationMs: Double?

    public init(sourceMs: Double?, destinationMs: Double?) {
        self.sourceMs = sourceMs
        self.destinationMs = destinationMs
    }

    /// The item pasted is later than the one there by more than `toleranceMs`. Without either date, it isn't.
    public func sourceIsNewer(toleranceMs: Double) -> Bool {
        guard let sourceMs, let destinationMs else { return false }
        return sourceMs > destinationMs + toleranceMs
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
    ///
    /// With Replace Older (`policy.replaceOlderToleranceMs`), a file without a choice of its own is replaced only when
    /// it is newer than the one there (`dates`), and skipped otherwise; a package that clashes like a file
    /// (`isPackage`) is skipped whatever its dates (`replaceOlderSkip` says which).
    public static func choiceForConflict(
        conflictClass: ConflictClass, replaceBlockedReason: String?, policy: CopyPastePolicy,
        override: CopyPasteChoice?, dates: ModifiedDates? = nil, isPackage: Bool = false
    ) -> CopyPasteChoice {
        let choice: CopyPasteChoice
        if let override, isChoiceAllowed(for: conflictClass, override) {
            choice = override
        } else {
            switch conflictClass {
            case .directoryConflict: choice = policy.directory
            case .typeMismatch: choice = policy.mismatch
            case .fileConflict:
                choice = replaceOlderLeaves(policy, dates, isPackage: isPackage) == nil ? policy.file : .skip
            }
        }
        if choice == .overwrite && replaceBlockedReason != nil {
            return conflictClass == .directoryConflict ? .merge : .keepBoth
        }
        return choice
    }

    /// Why `choiceForConflict` skips the item on Replace Older's account; nil when it doesn't, or the item has a
    /// choice of its own.
    public static func replaceOlderSkip(
        conflictClass: ConflictClass, policy: CopyPastePolicy, override: CopyPasteChoice?, dates: ModifiedDates?,
        isPackage: Bool
    ) -> ReplaceOlderSkip? {
        let hasOwnChoice = override.map { isChoiceAllowed(for: conflictClass, $0) } ?? false
        guard conflictClass == .fileConflict, !hasOwnChoice else { return nil }
        return replaceOlderLeaves(policy, dates, isPackage: isPackage)
    }

    /// Replace Older is chosen for files, and it leaves this one: a package, or a file no newer than the one there.
    private static func replaceOlderLeaves(_ policy: CopyPastePolicy, _ dates: ModifiedDates?, isPackage: Bool)
        -> ReplaceOlderSkip?
    {
        guard policy.file == .overwrite, let tolerance = policy.replaceOlderToleranceMs else { return nil }
        if isPackage { return .packageNotCompared }
        return dates?.sourceIsNewer(toleranceMs: tolerance) == true ? nil : .notNewer
    }

    /// How far apart, in milliseconds, two modification dates of one file can be once copied between disks of
    /// these file systems (`statfs`'s names): the coarsest of them. Nil when any of them keeps dates that can't be
    /// compared, and Replace Older isn't offered:
    /// - APFS keeps nanoseconds, compared here in milliseconds; HFS+ whole seconds; exFAT 10 ms, with the time zone.
    /// - SMB shares keep what the server's disk keeps; 2 seconds covers the coarsest of those.
    /// - FAT keeps local time with no time zone, so a daylight-saving change or a trip moves every date by an hour,
    ///   and anything else (NFS, AFP, WebDAV, NTFS, a disk not known) isn't relied on.
    public static func newerToleranceMs(fileSystems: [String?]) -> Double? {
        var tolerance = 0.0
        for name in fileSystems {
            let own: Double
            switch name?.lowercased() {
            case "apfs": own = 1
            case "hfs": own = 1000
            case "exfat": own = 10
            case "smbfs": own = 2000
            default: return nil
            }
            tolerance = max(tolerance, own)
        }
        return fileSystems.isEmpty ? nil : tolerance
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
