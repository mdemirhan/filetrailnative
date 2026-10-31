// Port of the clipboard button, menu and marks rules of apps/desktop/src/renderer/styles.css (7504-7835), of the
// drop-target rules (1844, 2452-2464, 2514-2517, 2642-2653, 2795-2813, 8054-8094) and of the timings of
// lib/clipboardMarks.tsx, components/ClipboardButton.tsx and hooks/useExplorerDragAndDrop.ts
import Foundation

/// The metrics the clipboard's marks, its menu and the drop targets are drawn with.
public enum ClipboardLayout {
    /// `.clipboard-mark-icon`: a 12 pt copy or scissors glyph after the name, the name cell's 8 pt gap before it.
    public enum Mark {
        public static let iconSize = 12.0
        public static let gap = 8.0
        /// `.clipboard-mark-badge` (Icon view): an 18 pt circle on the picture's corner, 4 pt outside it, with an
        /// 11 pt glyph and a 1 pt edge of the accent at 70%.
        public static let badgeSize = 18.0
        public static let badgeIconSize = 11.0
        public static let badgeOffset = -4.0
        public static let badgeBorderWidth = 1.0
        public static let badgeBorderAlpha = 0.7
        /// `.clipboard-cut`: cut items look taken out already.
        public static let cutLabelAlpha = 0.55
        public static let cutIconAlpha = 0.45
        /// `@keyframes clipboard-flash`: 0.45 at the start, 0.12 at 60%, gone at the end.
        public static let flashKeyTimes = [0.0, 0.6, 1.0]
        public static let flashOpacities = [0.45, 0.12, 0.0]
        /// `CLIPBOARD_FLASH_MS` (`--duration-flash`).
        public static let flashMs = 700.0
    }

    /// `.clipboard-menu` and its rows.
    public enum Menu {
        public static let minWidth = 260.0
        public static let maxWidth = 420.0
        /// `max-width: min(420px, calc(100vw - 16px))`.
        public static let viewportInset = 16.0
        /// `.clipboard-menu-header`: 4 10 padding, 8 between the title and the hint.
        public static let headerPaddingVertical = 4.0
        public static let headerPaddingHorizontal = 10.0
        public static let headerGap = 8.0
        /// `.clipboard-menu-breakdown`: `padding: 0 10px 4px`.
        public static let breakdownPaddingBottom = 4.0
        /// `CLIPBOARD_MENU_ROW_HEIGHT`, `CLIPBOARD_MENU_VISIBLE_ROWS`, `CLIPBOARD_MENU_OVERSCAN_ROWS`.
        public static let rowHeight = 24.0
        public static let visibleRows = 10
        public static let overscanRows = 4
        /// `.clipboard-menu-heading`: `padding: 0 10px`.
        public static let headingPaddingHorizontal = 10.0
        /// `.clipboard-menu-item`: `padding: 0 4px 0 10px`; the icon and the name 6 apart.
        public static let itemPaddingLeading = 10.0
        public static let itemPaddingTrailing = 4.0
        public static let itemIconGap = 6.0
        /// `.file-icon.native-file-icon`.
        public static let itemIconSize = 18.0
        /// `.clipboard-menu-item-remove`: 20 square, a 12 pt cross.
        public static let removeSize = 20.0
        public static let removeIconSize = 12.0
        /// `color-mix(in srgb, var(--ft-accent-on-solid) 22%, transparent)` under the pointer.
        public static let removeHoverAlpha = 0.22
        /// `--clipboard-scrollbar-width`, and the thumb's 2 pt clear edge, at 30% (48% under the pointer) of the
        /// menu's text.
        public static let scrollbarWidth = 10.0
        public static let scrollbarThumbInset = 2.0
        public static let scrollbarThumbAlpha = 0.3
        public static let scrollbarThumbActiveAlpha = 0.48
        /// `.clipboard-menu-clear`: `padding-left: 10px`.
        public static let clearPaddingLeading = 10.0
    }

    /// The button's count (`.clipboard-button-count`) is semibold.
    public static let countWeight = 600

    /// `[data-drop-target-state]` on rows, the tree and the pane.
    public enum Drop {
        /// A valid row: the accent's soft fill mixed 96% over the elevated background, a 2 pt halo of the accent
        /// border at 22% (tree rows: 3 pt at 30%), the edge at 90% with white, and a 4 pt bar 5 pt in from the top
        /// and bottom at the leading edge.
        public static let fillMix = 0.96
        public static let rowHaloWidth = 2.0
        public static let rowHaloAlpha = 0.22
        public static let treeHaloWidth = 3.0
        public static let treeHaloAlpha = 0.3
        public static let edgeMix = 0.9
        public static let barWidth = 4.0
        public static let barInset = 5.0
        public static let barMix = 0.88
        /// An invalid one: the danger color at 10% with its edge at 46% (tree rows 48%) and a 1 pt halo at 20%.
        public static let invalidFillAlpha = 0.1
        public static let invalidEdgeAlpha = 0.46
        public static let invalidTreeEdgeAlpha = 0.48
        public static let invalidHaloAlpha = 0.2
        /// An icon (`.icon-item[data-drop-target-state]`): the same fill, with a 2 pt inset edge of the accent border
        /// mixed 90% with white; an invalid one the danger fill with a 1 pt inset edge at 46%.
        public static let iconEdgeWidth = 2.0
        public static let invalidIconEdgeWidth = 1.0
        /// `.content-viewport[data-drop-target-state="valid"]`: a 2 pt inset ring of the accent border mixed 90%
        /// with white.
        public static let paneRingWidth = 2.0
        public static let paneRingMix = 0.9
        /// `spring-warning-wiggle`: ±7° over 250 ms.
        public static let wiggleDegrees = 7.0
        public static let wiggleMs = 250.0
    }
}

/// The timings of drags and drops (`useExplorerDragAndDrop.ts`).
public enum DragTimings {
    /// `SPRING_LOAD_MS`, `SPRING_WARN_MS`, `SPRING_MOVE_PX`, `SPRING_HOLD_GAP_MS`.
    public static let springLoadMs = 700.0
    public static let springWarnMs = 625.0
    public static let springMovePoints = 3.0
    public static let springHoldGapMs = 300.0
    /// `DROP_TARGETS_QUIET_MS`: drop highlights go when drag-overs stop this long.
    public static let dropTargetsQuietMs = 300.0
    /// The tree's hover expand (`TREE_HOVER_EXPAND_MS`) and a tab's hover switch (`TAB_HOVER_SWITCH_MS`).
    public static let treeHoverExpandMs = 700.0
    public static let tabHoverSwitchMs = 700.0
    /// `OWN_DROP_WAIT_MS`, `OWN_DRAG_STALE_AFTER_MS`, `OWN_DRAG_OVER_QUIET_MS`, `DRAG_AWAY_MS`.
    public static let ownDropWaitMs = 1000.0
    public static let ownDragStaleAfterMs = 500.0
    public static let ownDragOverQuietMs = 1000.0
    public static let dragAwayMs = 300.0
    /// `DISK_ANSWER_WAIT_MS`: a drop with no keys held waits this long for the disks.
    public static let diskAnswerWaitMs = 1500.0
    /// `EXTERNAL_DRAG_GONE_MS`, checked every 100 ms.
    public static let externalDragGoneMs = 400.0
    public static let externalDragCheckMs = 100.0
    /// `DRAGGED_AWAY_CHECKS_MS`: after a drag that ended elsewhere with a move or delete, the disk is asked which
    /// items are gone after each of these waits, one after the other (about a minute in all).
    public static let draggedAwayChecksMs: [Double] = [250, 1000, 3000, 6000, 10000, 15000, 25000]
    /// `BRING_TO_FRONT_CHECK_MS`: the window is checked this long after it was asked to come forward.
    public static let bringToFrontCheckMs = 250.0
}
