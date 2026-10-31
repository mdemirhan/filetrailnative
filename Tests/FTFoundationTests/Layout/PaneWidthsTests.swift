// Ports apps/desktop/src/renderer/hooks/useExplorerPaneLayout.test.tsx and lib/layoutTokens.test.ts
import Testing

@testable import FTFoundation

struct PaneWidthsTests {
    // T-055acb96: a menu past the bottom and right edges goes back inside, 8 from each.
    @Test func keepInViewportMovesAMenuBackInside() {
        let moved = MenuPlacement.keepInViewport(
            left: 900, top: 450, width: 240, height: 300, viewportWidth: 1000, viewportHeight: 600)
        #expect(moved.left == 752 && moved.top == 292)
    }

    let layout = DesignTokens.explorer(density: .comfortable)

    func panes(tree: Double = 280, inspector: Double = 320) -> PaneWidths {
        PaneWidths(treeWidth: tree, inspectorWidth: inspector, layout: layout)
    }

    // T-83343b0d F-701 F-702
    @Test func definesStableExplorerPaneConstraints() {
        #expect(layout.treeMinWidth == 220)
        #expect(layout.treeMaxWidth == 520)
        #expect(layout.inspectorMinWidth == 260)
        #expect(layout.inspectorMaxWidth == 480)
        #expect(layout.resizerWidth == 8)
        #expect(layout.paneResizeStep == 12)
        #expect(layout.paneResizeStepLarge == 24)
        #expect(layout.minContentWidth == 420)
        #expect(layout.defaultTreeWidth == 280)
        #expect(layout.defaultInspectorWidth == 320)
    }

    // T-21dbb5e8 F-703 B-INFO-187
    // B-INFO-026
    @Test func resizesTreeAndInspectorPanesWithinBounds() {
        var widths = panes()
        let tree = widths.dragStart(.tree, x: 100)
        widths.drag(from: tree, to: 180, viewportWidth: 1440, inspectorVisible: true)
        #expect(widths.treeWidth == 360)
        let inspector = widths.dragStart(.inspector, x: 400)
        widths.drag(from: inspector, to: 330, viewportWidth: 1440, inspectorVisible: true)
        #expect(widths.inspectorWidth == 390)
        // Never past the limits.
        widths.drag(from: widths.dragStart(.tree, x: 0), to: 900, viewportWidth: 1440, inspectorVisible: true)
        #expect(widths.treeWidth == 520)
        widths.drag(from: widths.dragStart(.inspector, x: 0), to: 900, viewportWidth: 1440, inspectorVisible: true)
        #expect(widths.inspectorWidth == 260)
    }

    // T-44cf0a5a F-703 B-INFO-188
    @Test func shrinksSidePanesToPreserveCenterContentWhenTheViewportNarrows() {
        var widths = panes(tree: 520, inspector: 480)
        widths.sync(viewportWidth: 1080, inspectorVisible: true)
        #expect(widths.treeWidth == 384)
        #expect(widths.inspectorWidth == 260)
    }

    // T-3d2da726 B-INFO-188 B-INFO-190
    @Test func clampsTheTreePaneAgainstTheViewportWhenTheInspectorIsHidden() {
        var widths = panes(tree: 520)
        widths.sync(viewportWidth: 760, inspectorVisible: false)
        #expect(widths.treeWidth == 332)
        // The panel's width is not touched while it is closed.
        #expect(widths.inspectorWidth == 320)
    }

    // T-f539501b B-INFO-188
    @Test func givesAPaneBackItsWidthWhenTheWindowIsWidenedAgain() {
        var widths = panes(tree: 300)
        widths.sync(viewportWidth: 640, inspectorVisible: false)
        #expect(widths.treeWidth < 300)
        #expect(widths.preferredTreeWidth == 300)
        widths.sync(viewportWidth: 1440, inspectorVisible: false)
        #expect(widths.treeWidth == 300)
    }

    // T-ee035de5 F-704 B-INFO-189
    @Test func widensAPaneFromTheKeyboardAndKeepsThatWidth() {
        var widths = panes(tree: 300)
        widths.nudge(.tree, by: 16)
        #expect(widths.treeWidth == 316)
        #expect(widths.preferredTreeWidth == 316)
        widths.nudge(.inspector, by: -layout.paneResizeStepLarge)
        #expect(widths.inspectorWidth == 296)
        widths.nudge(.inspector, by: -500)
        #expect(widths.inspectorWidth == 260)
    }

    @Test func restoresSavedWidthsAsChosenOnes() {
        var widths = panes()
        widths.restore(treeWidth: 333, inspectorWidth: 444)
        #expect(widths.treeWidth == 333 && widths.preferredTreeWidth == 333)
        #expect(widths.inspectorWidth == 444 && widths.preferredInspectorWidth == 444)
    }

    // T-11f54d0b
    @Test func dropsAMenuFromTheEdgeOfItsButtonThatLeavesTheMostRoom() {
        let left = MenuPlacement.dropdown(
            anchorLeft: 100, anchorRight: 132, anchorBottom: 41, menuWidth: 220, menuHeight: 100, viewportWidth: 1000,
            viewportHeight: 700)
        #expect(left.left == 100 && left.top == 47)
        let right = MenuPlacement.dropdown(
            anchorLeft: 900, anchorRight: 932, anchorBottom: 41, menuWidth: 220, menuHeight: 100,
            viewportWidth: 1000, viewportHeight: 700)
        #expect(right.left == 712)
        // Kept 8 pt inside the window.
        let edge = MenuPlacement.dropdown(
            anchorLeft: 960, anchorRight: 999, anchorBottom: 41, menuWidth: 220, menuHeight: 800,
            viewportWidth: 1000, viewportHeight: 700)
        #expect(edge.left == 772 && edge.top == 8)
    }
}
