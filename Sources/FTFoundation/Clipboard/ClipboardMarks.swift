import Foundation

/// How an item on the clipboard is drawn: a copy or cut glyph after its name, cut items dimmed, and a flash at the
/// moment it was copied or cut.
public enum ClipboardMark: Equatable, Sendable {
    case copy, cut

    public var isCut: Bool { self == .cut }
}

/// Which items are on the clipboard, for the rows that show them (`ClipboardMarks`).
public struct ClipboardMarks: Equatable, Sendable {
    let paths: Set<ExactKey>
    public let mode: ClipboardMode

    /// The marks of `clipboard` while Settings' "Mark copied and cut items" is on; nil otherwise, or while it is
    /// empty, and no row has marks.
    public init?(_ clipboard: CopyPasteClipboard, enabled: Bool) {
        guard enabled, case .ready(let mode, let sourcePaths, _, _) = clipboard, !sourcePaths.isEmpty else {
            return nil
        }
        paths = Set(sourcePaths.map(ExactKey.init))
        self.mode = mode
    }

    /// The mark of the item at `path` (by its exact path, so a search result is marked too), or nil.
    public func mark(for path: String?) -> ClipboardMark? {
        guard let path, paths.contains(ExactKey(path)) else { return nil }
        return mode == .cut ? .cut : .copy
    }
}

/// When the marks flash: a Copy or Cut, here or arriving from another window, changes `capturedAt`; a
/// change that keeps it (an item taken off, a follow-up) does not flash again.
public struct ClipboardFlashTracker: Sendable {
    private var lastCapturedAt: String?

    public init(_ clipboard: CopyPasteClipboard = .empty) {
        lastCapturedAt = clipboard.capturedAt
    }

    /// Notes the clipboard as it is now; true when its marks should flash.
    public mutating func changed(to clipboard: CopyPasteClipboard) -> Bool {
        let capturedAt = clipboard.capturedAt
        defer { lastCapturedAt = capturedAt }
        guard let capturedAt else { return false }
        guard let lastCapturedAt else { return true }
        return !JSString.equals(capturedAt, lastCapturedAt)
    }
}
