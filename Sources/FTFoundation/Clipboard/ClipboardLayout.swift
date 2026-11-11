import Foundation

/// The metrics the clipboard's marks, its menu and the drop targets are drawn with.
public enum ClipboardLayout {
    /// The mark of an item on the clipboard: a 12 pt copy or scissors glyph after the name, the name cell's 8 pt gap
    /// before it.
    public enum Mark {
        public static let iconSize = 12.0
        public static let gap = 8.0
        /// Cut items look taken out already.
        public static let cutLabelAlpha = 0.55
        public static let cutIconAlpha = 0.45
        /// The flash over a row: 0.45 at the start, 0.12 at 60%, gone at the end.
        public static let flashKeyTimes = [0.0, 0.6, 1.0]
        public static let flashOpacities = [0.45, 0.12, 0.0]
    }

    /// The clipboard menu and its rows.
    public enum Menu {
        public static let minWidth = 260.0
        public static let maxWidth = 420.0
        /// The menu is at most 420 wide, or the window's width less 16 if that is less.
        public static let viewportInset = 16.0
        /// The header: 4 above and below, 10 at the sides, 8 between the title and the hint.
        public static let headerPaddingVertical = 4.0
        public static let headerPaddingHorizontal = 10.0
        public static let headerGap = 8.0
        /// The breakdown under the header: 4 below it.
        public static let breakdownPaddingBottom = 4.0
        public static let rowHeight = 24.0
        public static let visibleRows = 10
        public static let overscanRows = 4
        /// A heading: 10 at the sides.
        public static let headingPaddingHorizontal = 10.0
        /// An item: 10 on the leading side and 4 on the trailing one; the icon and the name 6 apart.
        public static let itemPaddingLeading = 10.0
        public static let itemPaddingTrailing = 4.0
        public static let itemIconGap = 6.0
        /// The item's file icon.
        public static let itemIconSize = 18.0
        /// An item's remove button: 20 square, a 12 pt cross.
        public static let removeSize = 20.0
        public static let removeIconSize = 12.0
        /// Under the pointer, the button fills with the color of text on the accent at 22%.
        public static let removeHoverAlpha = 0.22
        /// The scroll bar's width, and the thumb's 2 pt clear edge, at 30% (48% under the pointer) of the menu's text.
        public static let scrollbarWidth = 10.0
        public static let scrollbarThumbInset = 2.0
        public static let scrollbarThumbAlpha = 0.3
        public static let scrollbarThumbActiveAlpha = 0.48
        /// The Clear button: 10 on the leading side.
        public static let clearPaddingLeading = 10.0
    }

    /// How a drop target shows on rows, the tree and the pane.
    public enum Drop {
        /// A valid row: the accent's soft fill mixed 96% over the elevated background, a 2 pt halo of the accent
        /// border at 22%, the edge at 90% with white, and a 4 pt bar 5 pt in from the top and bottom at the leading
        /// edge.
        public static let fillMix = 0.96
        public static let rowHaloWidth = 2.0
        public static let rowHaloAlpha = 0.22
        public static let edgeMix = 0.9
        public static let barWidth = 4.0
        public static let barInset = 5.0
        public static let barMix = 0.88
        /// An invalid one: the danger color at 10% with its edge at 46% and a 1 pt halo at 20%.
        public static let invalidFillAlpha = 0.1
        public static let invalidEdgeAlpha = 0.46
        public static let invalidHaloAlpha = 0.2
        /// An icon in Icon view: the same fill, with a 2 pt inset edge of the accent border
        /// mixed 90% with white; an invalid one the danger fill with a 1 pt inset edge at 46%.
        public static let iconEdgeWidth = 2.0
        public static let invalidIconEdgeWidth = 1.0
        /// The pane, a valid target: a 2 pt inset ring of the accent border mixed 90% with white.
        public static let paneRingWidth = 2.0
        public static let paneRingMix = 0.9
        /// The wiggle of a folder about to spring open: ±7° over 250 ms.
        public static let wiggleDegrees = 7.0
        public static let wiggleMs = 250.0
    }
}

/// The timings of drags and drops.
public enum DragTimings {
    public static let springLoadMs = 700.0
    public static let springWarnMs = 625.0
    public static let springMovePoints = 3.0
    public static let springHoldGapMs = 300.0
    /// Drop highlights go when drag-overs stop this long.
    public static let dropTargetsQuietMs = 300.0
    /// The tree's hover expand.
    public static let treeHoverExpandMs = 700.0
    /// A drop with no keys held waits this long for the disks.
    public static let diskAnswerWaitMs = 1500.0
    /// After a drag that ended elsewhere with a move or delete, the disk is asked which
    /// items are gone after each of these waits, one after the other (about a minute in all).
    public static let draggedAwayChecksMs: [Double] = [250, 1000, 3000, 6000, 10000, 15000, 25000]
    /// The window is checked this long after it was asked to come forward.
    public static let bringToFrontCheckMs = 250.0
}
