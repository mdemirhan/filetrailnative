// Port of what Chromium's drag autoscroll gives the scrolling lists of apps/desktop/src/renderer/components/IconGridView.tsx, ContentPane.tsx and TreePane.tsx
import AppKit

/// A drag held near an edge of a scrolling view scrolls it, faster the closer to the edge. As Chromium's, it starts after
/// a moment in the belt along the edges, so a drag that only passes over an edge scrolls nothing.
@MainActor
struct DragEdgeScroll {
    static let beltWidth: CGFloat = 20
    static let startDelay: TimeInterval = 0.2
    /// Points a second for each point into the belt.
    static let speed: CGFloat = 30
    /// The longest step: drag-overs that came late don't make a jump.
    static let longestStep: TimeInterval = 0.1

    var clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    private var sequence: Int?
    private var enteredAt: TimeInterval?
    private var steppedAt: TimeInterval?

    /// How far into the belt `position` is between `low` and `high`: negative at the low edge, positive at the high one,
    /// 0 outside the belt.
    static func depth(_ position: CGFloat, low: CGFloat, high: CGFloat) -> CGFloat {
        if position < low + beltWidth { return position - (low + beltWidth) }
        if position > high - beltWidth { return position - (high - beltWidth) }
        return 0
    }

    /// A drag-over at the drag's location. AppKit repeats them while a drag rests over a view.
    mutating func follow(_ info: any NSDraggingInfo, in scrollView: NSScrollView?) {
        if sequence != info.draggingSequenceNumber {
            reset()
            sequence = info.draggingSequenceNumber
        }
        guard let scrollView else { return }
        let clip = scrollView.contentView
        let point = clip.convert(info.draggingLocation, from: nil)
        let bounds = clip.bounds
        let depth = NSPoint(
            x: Self.depth(point.x, low: bounds.minX, high: bounds.maxX),
            y: Self.depth(point.y, low: bounds.minY, high: bounds.maxY))
        guard bounds.contains(point), depth != .zero else {
            reset()
            return
        }
        let now = clock()
        let entered = enteredAt ?? now
        enteredAt = entered
        let elapsed = min(now - (steppedAt ?? now), Self.longestStep)
        steppedAt = now
        guard now - entered >= Self.startDelay else { return }
        let step = CGFloat(elapsed) * Self.speed
        var target = bounds
        target.origin.x += depth.x * step
        target.origin.y += depth.y * step
        let origin = clip.constrainBoundsRect(target).origin
        guard origin != bounds.origin else { return }
        clip.scroll(to: origin)
        scrollView.reflectScrolledClipView(clip)
    }

    mutating func reset() {
        enteredAt = nil
        steppedAt = nil
    }
}
