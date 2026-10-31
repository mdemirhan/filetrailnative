// Port of the width math of apps/desktop/src/renderer/hooks/useExplorerPaneLayout.ts
import Foundation

/// The widths of the folder tree and the Info panel. A pane keeps the width it was given (by dragging, from the
/// keyboard, or from the saved state): a window made too narrow for it shows it narrower, and it comes back when the
/// window is widened again. What is saved is the chosen width (`preferred…`), not the squeezed one.
public struct PaneWidths: Equatable, Sendable {
    public enum Pane: Sendable {
        case tree, inspector
    }

    /// Where a drag started: the pointer, and the widths then.
    public struct DragStart: Equatable, Sendable {
        public var pane: Pane
        public var x: Double
        public var treeWidth: Double
        public var inspectorWidth: Double
    }

    /// As drawn.
    public private(set) var treeWidth: Double
    public private(set) var inspectorWidth: Double
    /// As chosen.
    public private(set) var preferredTreeWidth: Double
    public private(set) var preferredInspectorWidth: Double
    public let layout: ExplorerLayout

    public init(treeWidth: Double, inspectorWidth: Double, layout: ExplorerLayout) {
        self.treeWidth = treeWidth
        self.inspectorWidth = inspectorWidth
        preferredTreeWidth = treeWidth
        preferredInspectorWidth = inspectorWidth
        self.layout = layout
    }

    /// `getAvailableSideWidth`: what the side panes share once the content's minimum and the resizers are kept.
    public static func availableSideWidth(viewportWidth: Double, inspectorVisible: Bool, layout: ExplorerLayout)
        -> Double
    {
        let resizers = Double(inspectorVisible ? 2 : 1) * layout.resizerWidth
        return max(
            layout.treeMinWidth + (inspectorVisible ? layout.inspectorMinWidth : 0),
            viewportWidth - layout.minContentWidth - resizers)
    }

    /// `clampPaneWidth`: rounded as `Math.round`, after clamping.
    static func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        (max(lower, min(upper, value)) + 0.5).rounded(.down)
    }

    /// `restoreWidths`: widths given from outside (the saved ones) are chosen widths too.
    public mutating func restore(treeWidth: Double, inspectorWidth: Double) {
        preferredTreeWidth = treeWidth
        preferredInspectorWidth = inspectorWidth
        self.treeWidth = treeWidth
        self.inspectorWidth = inspectorWidth
    }

    public func dragStart(_ pane: Pane, x: Double) -> DragStart {
        DragStart(pane: pane, x: x, treeWidth: treeWidth, inspectorWidth: inspectorWidth)
    }

    /// A resizer dragged to `x` (window coordinates) from where `start` began: the tree grows to the right, the
    /// Info panel to the left, within their limits and the room the window leaves.
    public mutating func drag(from start: DragStart, to x: Double, viewportWidth: Double, inspectorVisible: Bool) {
        let available = Self.availableSideWidth(
            viewportWidth: viewportWidth, inspectorVisible: inspectorVisible, layout: layout)
        let delta = x - start.x
        switch start.pane {
        case .tree:
            let room =
                inspectorVisible
                ? max(layout.treeMinWidth, available - inspectorWidth) : max(layout.treeMinWidth, available)
            let next = Self.clamp(start.treeWidth + delta, layout.treeMinWidth, min(layout.treeMaxWidth, room))
            treeWidth = next
            preferredTreeWidth = next
        case .inspector:
            let room = max(layout.inspectorMinWidth, available - treeWidth)
            let next = Self.clamp(
                start.inspectorWidth - delta, layout.inspectorMinWidth, min(layout.inspectorMaxWidth, room))
            inspectorWidth = next
            preferredInspectorWidth = next
        }
    }

    /// `syncToViewport`: a window resize, or the Info panel shown or hidden, can make the widths too wide; each
    /// pane gets as much of its chosen width as fits.
    public mutating func sync(viewportWidth: Double, inspectorVisible: Bool) {
        let available = Self.availableSideWidth(
            viewportWidth: viewportWidth, inspectorVisible: inspectorVisible, layout: layout)
        var nextTree = Self.clamp(preferredTreeWidth, layout.treeMinWidth, layout.treeMaxWidth)
        var nextInspector = Self.clamp(preferredInspectorWidth, layout.inspectorMinWidth, layout.inspectorMaxWidth)
        if inspectorVisible {
            nextInspector = min(nextInspector, max(layout.inspectorMinWidth, available - nextTree))
            nextTree = min(nextTree, max(layout.treeMinWidth, available - nextInspector))
        } else {
            nextTree = min(nextTree, max(layout.treeMinWidth, available))
        }
        treeWidth = nextTree
        if inspectorVisible { inspectorWidth = nextInspector }
    }

    /// `nudgeWidth`: a pane widened or narrowed from the keyboard by `delta`, within its limits; that is its chosen
    /// width from then on.
    public mutating func nudge(_ pane: Pane, by delta: Double) {
        switch pane {
        case .tree:
            let next = Self.clamp(treeWidth + delta, layout.treeMinWidth, layout.treeMaxWidth)
            preferredTreeWidth = next
            treeWidth = next
        case .inspector:
            let next = Self.clamp(inspectorWidth + delta, layout.inspectorMinWidth, layout.inspectorMaxWidth)
            preferredInspectorWidth = next
            inspectorWidth = next
        }
    }
}
