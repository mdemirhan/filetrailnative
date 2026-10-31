// Port of springWhenHeld and resetSpringHold (apps/desktop/src/renderer/hooks/useExplorerDragAndDrop.ts): a folder a
// drag rests on springs open, as in Finder
import Foundation

/// The hold of a drag over a folder of the file list: after 700 ms the folder shows it is about to open (its icon
/// wiggles), and 625 ms later it opens, unless the pointer moves more than 3 pt or the drag-overs stop for 300 ms.
public struct SpringHold: Sendable {
    /// What a drag-over does.
    public enum Step: Equatable, Sendable {
        /// Nothing to show (a new hold, or none).
        case idle
        /// The folder is about to open (`data-drop-target-state="springing"`).
        case warning(String)
        /// Open the folder now.
        case open(String)
    }

    private struct Hover {
        var path: String
        var since: Double
        var lastAt: Double
        var at: (x: Double, y: Double)
        var warnedAt: Double?
    }

    private var hover: Hover?
    /// Where the pointer was when a folder last opened: a folder under it waits for it to move.
    private var rest: (x: Double, y: Double)?

    public init() {}

    /// The folder about to open, if one is.
    public var warningPath: String? {
        guard let hover, hover.warnedAt != nil else { return nil }
        return hover.path
    }

    /// `resetSpringHold`.
    public mutating func reset() {
        hover = nil
    }

    /// The drag is over a new session: everything is forgotten.
    public mutating func forget() {
        hover = nil
        rest = nil
    }

    /// A drag-over at `now` (ms) with the pointer at `point`, over the folder `path`. `canSpring`: the folder takes
    /// the drop and is a real folder, the drag isn't blocked, and it is not the folder on screen.
    public mutating func over(_ path: String, canSpring: Bool, at point: (x: Double, y: Double), now: Double) -> Step {
        guard canSpring else {
            reset()
            return .idle
        }
        if let rest {
            if Self.distance(point, rest) <= DragTimings.springMovePoints { return .idle }
            self.rest = nil
        }
        guard var current = hover, JSString.equals(current.path, path),
            now - current.lastAt <= DragTimings.springHoldGapMs,
            Self.distance(point, current.at) <= DragTimings.springMovePoints
        else {
            hover = Hover(path: path, since: now, lastAt: now, at: point, warnedAt: nil)
            return .idle
        }
        current.lastAt = now
        guard let warnedAt = current.warnedAt else {
            if now - current.since >= DragTimings.springLoadMs {
                current.warnedAt = now
                hover = current
                return .warning(path)
            }
            hover = current
            return .idle
        }
        hover = current
        if now - warnedAt < DragTimings.springWarnMs { return .warning(path) }
        reset()
        rest = point
        return .open(path)
    }

    private static func distance(_ a: (x: Double, y: Double), _ b: (x: Double, y: Double)) -> Double {
        ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot()
    }
}
