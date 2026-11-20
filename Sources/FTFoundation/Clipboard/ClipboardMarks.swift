import Foundation

/// How an item on the clipboard is drawn: a copy or cut glyph after its name, cut items dimmed, and a flash at the
/// moment it was copied or cut.
public enum ClipboardMark: Equatable, Sendable {
    case copy, cut

    public var isCut: Bool { self == .cut }

    init(_ mode: ClipboardMode) {
        self = mode == .cut ? .cut : .copy
    }
}

/// Which items are on the clipboard and how each is to be pasted, for the rows that show them (`ClipboardMarks`), and
/// which of their marks flash now.
public struct ClipboardMarks: Equatable, Sendable {
    let modes: [ExactKey: ClipboardMode]
    /// The marks that flash this time: nil for all of them (a new Copy or Cut), or the items an Add put on or switched.
    private(set) var flashing: Set<ExactKey>?

    /// The marks of `clipboard` while Settings' "Mark copied and cut items" is on; nil otherwise, or while it is
    /// empty, and no row has marks.
    public init?(_ clipboard: CopyPasteClipboard, enabled: Bool, flashing: Set<String>? = nil) {
        guard enabled, clipboard.hasItems else { return nil }
        modes = Dictionary(
            clipboard.picks.map { (ExactKey($0.path), $0.mode) }, uniquingKeysWith: { first, _ in first })
        self.flashing = flashing.map { Set($0.map(ExactKey.init)) }
    }

    /// What every item does; nil when some are copied and others moved.
    public var mode: ClipboardMode? {
        guard let first = modes.values.first else { return nil }
        return modes.values.allSatisfy { $0 == first } ? first : nil
    }

    /// The mark of the item at `path` (by its exact path, so a search result is marked too), or nil.
    public func mark(for path: String?) -> ClipboardMark? {
        guard let path, let mode = modes[ExactKey(path)] else { return nil }
        return ClipboardMark(mode)
    }

    /// Whether the mark of the item at `path` flashes now: it has one, and is among those that changed.
    public func flashes(_ path: String?) -> Bool {
        guard let path, modes[ExactKey(path)] != nil else { return false }
        return flashing?.contains(ExactKey(path)) ?? true
    }

    /// The same marks, with the ones that flash now.
    public func flashing(_ paths: Set<String>?) -> ClipboardMarks {
        var marks = self
        marks.flashing = paths.map { Set($0.map(ExactKey.init)) }
        return marks
    }

    /// Two sets of marks are the same when each item has the same one: which flash is not a difference.
    public static func == (lhs: ClipboardMarks, rhs: ClipboardMarks) -> Bool {
        lhs.modes == rhs.modes
    }
}

/// Which marks flash: a Copy, Cut or Put Back, here or arriving from another window, changes `capturedAt` and every
/// mark flashes; an Add flashes the marks of the items it put on or switched (`ClipboardPick.markedAt`); a change that
/// keeps both (an item taken off, a follow-up) flashes nothing.
public struct ClipboardFlashTracker: Sendable {
    private var lastCapturedAt: String?
    private var lastMarkedAt: String?

    public init(_ clipboard: CopyPasteClipboard = .empty) {
        lastCapturedAt = clipboard.capturedAt
        lastMarkedAt = Self.latestMark(clipboard)
    }

    /// What flashes after `clipboard` arrived: `.none`, `.all`, or the items at some paths.
    public enum Flash: Equatable, Sendable {
        case none, all
        case items(Set<String>)

        /// The paths for `ClipboardMarks.flashing`: nil for all.
        public var paths: Set<String>? {
            if case .items(let paths) = self { return paths }
            return nil
        }
    }

    /// Notes the clipboard as it is now, and says which marks flash.
    public mutating func changed(to clipboard: CopyPasteClipboard) -> Flash {
        let capturedAt = clipboard.capturedAt
        let previousCapturedAt = lastCapturedAt
        let previousMarkedAt = lastMarkedAt
        lastCapturedAt = capturedAt
        lastMarkedAt = Self.latestMark(clipboard)
        guard let capturedAt else { return .none }
        guard let previousCapturedAt, JSString.equals(capturedAt, previousCapturedAt) else { return .all }
        let fresh = clipboard.picks.filter { pick in
            previousMarkedAt.map { Self.isLater(pick.markedAt, than: $0) } ?? true
        }
        return fresh.isEmpty ? .none : .items(Set(fresh.map(\.path)))
    }

    private static func latestMark(_ clipboard: CopyPasteClipboard) -> String? {
        clipboard.picks.map(\.markedAt).max { isLater($1, than: $0) }
    }

    /// The marks' times are "2026-11-11T14:46:00.000Z": of one form, so the later sorts after.
    private static func isLater(_ time: String, than other: String) -> Bool {
        time.utf8.lexicographicallyPrecedes(other.utf8) == false && !JSString.equals(time, other)
    }
}
