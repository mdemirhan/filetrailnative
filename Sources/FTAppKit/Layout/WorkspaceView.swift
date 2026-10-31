// Port of the workspace grid of apps/desktop/src/renderer/components/ExplorerWorkspace.tsx:1786-1879, the pane widths
// of hooks/useExplorerPaneLayout.ts and the translucent sidebar rules of styles.css:8113-8185
import AppKit
import FTFoundation

/// The explorer window's content: a sidebar split, as Finder's. The sidebar item holds the folder tree and its 8 pt
/// resizer, the full height of the window, under the traffic lights; the content item holds the content and, while it
/// is open, an 8 pt resizer and the Info panel. Because the system knows where the sidebar is, it puts the toolbar's
/// row (`ExplorerToolbar`, over the content column) and the tab bar (D-001, under the band) over the content column
/// only. A hidden tree collapses the sidebar item and takes no room. The Info panel is the system's inspector item
/// (D-020), which the toolbar's row and the tab bar reach over; it still slides as the original's. The sidebar is the
/// sidebar item's own material, its edge one straight line where the item ends (D-017); the content's color runs from
/// the window's top, so the band has no edge of its own, and a line shows under it only while the pointer is over it
/// (D-015), as Finder's.
final class WorkspaceView: NSView {
    let split = NSSplitViewController()
    let sidebarItem: NSSplitViewItem
    let contentItem: NSSplitViewItem
    let inspectorItem: NSSplitViewItem
    /// The sidebar item's view: the tree pane and its resizer.
    let sidebarColumn = WorkspaceSidebarColumn()
    /// The content item's view: the content pane.
    let contentColumn = WorkspaceContentColumn()
    /// The inspector item's view: the Info panel's resizer and the Info panel.
    let inspectorColumn = WorkspaceInspectorColumn()
    private var pointerOverBand = (content: false, inspector: false)
    /// `.workspace-sidebar-cell` (the tree pane): the sidebar's views go in it.
    var sidebarCell: WorkspaceCell { sidebarColumn.cell }
    var treeResizer: PaneResizerView { sidebarColumn.resizer }
    /// `.workspace-main-cell`: the content pane.
    var mainCell: WorkspaceCell { contentColumn.mainCell }
    var inspectorResizer: PaneResizerView { inspectorColumn.resizer }
    /// `.workspace-inspector-cell`: the Info panel.
    var inspectorCell: WorkspaceCell { inspectorColumn.cell }

    private(set) var panes: PaneWidths
    private(set) var folderTreeOpen = true
    private(set) var infoPanelOpen = false
    /// Not drawn until the preferences and the pane widths are in (`workspaceReady`).
    private(set) var isReady = false
    private var dragStart: PaneWidths.DragStart?
    /// The Info panel sliding: in over the room it takes, or out over the content.
    private(set) var slide: Slide?
    /// Told when a pane's chosen width changes (a drag ends, a key step), for the window's session.
    var onWidthsChosen: (PaneWidths) -> Void = { _ in }

    enum Slide: Equatable {
        case slidingIn, slidingOut
    }

    static var metrics: Metrics { WindowMetrics.standard }

    init(panes: PaneWidths) {
        self.panes = panes
        let sidebarController = NSViewController()
        sidebarController.view = sidebarColumn
        let contentController = NSViewController()
        contentController.view = contentColumn
        let inspectorController = NSViewController()
        inspectorController.view = inspectorColumn
        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarController)
        contentItem = NSSplitViewItem(viewController: contentController)
        inspectorItem = NSSplitViewItem(inspectorWithViewController: inspectorController)
        // The sidebar's own resizer is its edge: no divider of the split's between it and the content.
        split.splitView = WorkspaceSplitView()
        split.splitView.isVertical = true
        split.splitView.dividerStyle = .thin
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityIdentifier("window.content")
        // The tree's width is the panes' (PaneWidths): the split never sizes, collapses or drags it on its own.
        sidebarItem.canCollapse = true
        sidebarItem.canCollapseFromWindowResize = false
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(contentItem)
        // The panel's width is the panes' too: the resizer moves it, within its limits, and the window's width never
        // collapses it.
        inspectorItem.canCollapse = true
        inspectorItem.canCollapseFromWindowResize = false
        inspectorItem.isCollapsed = true
        split.addSplitViewItem(inspectorItem)
        setSidebarWidth(panes.treeWidth + Self.metrics.explorer.resizerWidth)
        setInspectorWidth(panes.inspectorWidth + Self.metrics.explorer.resizerWidth)
        split.view.frame = bounds
        split.view.autoresizingMask = [.width, .height]
        addSubview(split.view)
        sidebarColumn.workspace = self
        contentColumn.workspace = self
        inspectorColumn.workspace = self
        contentColumn.band.onHover = { [weak self] inside in
            self?.pointerOverBand.content = inside
            self?.showBandLine()
        }
        inspectorColumn.band.onHover = { [weak self] inside in
            self?.pointerOverBand.inspector = inside
            self?.showBandLine()
        }
        for resizer in [treeResizer, inspectorResizer] {
            resizer.onDragStart = { [weak self, weak resizer] x in
                guard let self, let resizer else { return }
                self.dragStart = self.panes.dragStart(resizer.pane, x: x)
            }
            resizer.onDrag = { [weak self] x in
                guard let self, let start = self.dragStart else { return }
                self.panes.drag(
                    from: start, to: x, viewportWidth: self.bounds.width, inspectorVisible: self.infoPanelOpen)
                self.needsLayout = true
            }
            resizer.onDragEnd = { [weak self] in
                guard let self else { return }
                self.dragStart = nil
                self.onWidthsChosen(self.panes)
            }
            resizer.onNudge = { [weak self, weak resizer] delta in
                guard let self, let resizer else { return }
                self.panes.nudge(resizer.pane, by: delta)
                self.panes.sync(viewportWidth: self.bounds.width, inspectorVisible: self.infoPanelOpen)
                self.needsLayout = true
                self.onWidthsChosen(self.panes)
            }
        }
        treeResizer.isSidebarEdge = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    private var titlebarObserver: (any NSObjectProtocol)?

    /// The title bar's container changes height when the system tab bar shows or goes: the content column's panes
    /// start under it, and are laid out again each time.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let titlebarObserver { NotificationCenter.default.removeObserver(titlebarObserver) }
        titlebarObserver = nil
        guard let container = window?.standardWindowButton(.closeButton)?.superview?.superview else { return }
        container.postsFrameChangedNotifications = true
        titlebarObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: container, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.needsLayout = true
                self?.contentColumn.needsLayout = true
                self?.inspectorColumn.needsLayout = true
                self?.sidebarColumn.needsLayout = true
            }
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    /// Puts the panes in place once the preferences and the saved widths are in.
    func becomeReady() {
        isReady = true
        needsLayout = true
    }

    /// The saved widths (`restoreWidths`).
    func restore(treeWidth: Double, inspectorWidth: Double) {
        panes.restore(treeWidth: treeWidth, inspectorWidth: inspectorWidth)
        needsLayout = true
    }

    /// Which panels are open. Opening or closing the Info panel slides it, unless the window is not ready yet.
    func show(folderTree: Bool, infoPanel: Bool) {
        let infoChanged = infoPanel != infoPanelOpen
        folderTreeOpen = folderTree
        infoPanelOpen = infoPanel
        if infoChanged, isReady, window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            startSlide(infoPanel ? .slidingIn : .slidingOut)
        } else if infoChanged {
            slide = nil
            rehomeInspectorCell(in: inspectorColumn)
        }
        needsLayout = true
    }

    // MARK: Layout

    /// The panes of the content column start under the toolbar band and, while it shows, the system tab bar.
    var panesTop: Double {
        guard let window else { return Self.metrics.toolbar.minHeight }
        return WindowChrome.panesTop(window)
    }

    /// A view's frame in this view's coordinates (from the top left).
    func frame(of view: NSView) -> NSRect {
        convert(view.bounds, from: view)
    }

    /// The content pane still tells where its rows' lines are; no hairline is left for them to reach (D-017).
    func setPaneRowLines(_ lines: [Double]) {}

    private func setSidebarWidth(_ width: Double) { Self.setWidth(width, of: sidebarItem) }
    private func setInspectorWidth(_ width: Double) { Self.setWidth(width, of: inspectorItem) }

    private static func setWidth(_ width: Double, of item: NSSplitViewItem) {
        guard item.minimumThickness != width || item.maximumThickness != width else { return }
        // Widening: the maximum first, so the two never cross.
        if width > item.maximumThickness {
            item.maximumThickness = width
            item.minimumThickness = width
        } else {
            item.minimumThickness = width
            item.maximumThickness = width
        }
    }

    override func layout() {
        panes.sync(viewportWidth: bounds.width, inspectorVisible: infoPanelOpen)
        setSidebarWidth(panes.treeWidth + Self.metrics.explorer.resizerWidth)
        if sidebarItem.isCollapsed == folderTreeOpen { sidebarItem.isCollapsed = !folderTreeOpen }
        setInspectorWidth(panes.inspectorWidth + Self.metrics.explorer.resizerWidth)
        if inspectorItem.isCollapsed == infoPanelOpen { inspectorItem.isCollapsed = !infoPanelOpen }
        super.layout()
        split.view.frame = bounds
        sidebarColumn.needsLayout = true
        contentColumn.needsLayout = true
        inspectorColumn.needsLayout = true
        applyColors()
        // A tab bar coming or going may put the title bar back over the window's top layer.
        if let window { WindowOverlayView.host(of: window) }
    }

    /// The line under the band, across the content and the Info panel, while the pointer is over the band of either.
    private func showBandLine() {
        let hidden = !pointerOverBand.content && !pointerOverBand.inspector
        contentColumn.bandLine.isHidden = hidden
        inspectorColumn.bandLine.isHidden = hidden
    }

    private func applyColors() {
        let background = ChromeColors.contentBackground(for: self).cgColor
        mainCell.layer?.backgroundColor = background
        contentColumn.backdrop.layer?.backgroundColor = background
        inspectorColumn.backdrop.layer?.backgroundColor = background
        effectiveAppearance.performAsCurrentDrawingAppearance {
            contentColumn.bandLine.layer?.backgroundColor = WorkspaceBandLine.color.cgColor
            inspectorColumn.bandLine.layer?.backgroundColor = WorkspaceBandLine.color.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
        for view in [treeResizer, inspectorResizer] as [NSView] { view.needsDisplay = true }
    }

    /// The content column's panes, in its own coordinates.
    fileprivate func layoutContent(_ column: WorkspaceContentColumn) {
        let width = column.bounds.width
        let height = column.bounds.height
        for view in column.subviews where view !== column.backdrop && view !== column.bandLine {
            view.isHidden = !isReady
        }
        column.backdrop.frame = column.bounds
        guard isReady else { return }
        let top = panesTop
        // The toolbar's band runs over the inspector item too, as the original's over its panel.
        let inspectorRoom = inspectorItem.isCollapsed ? 0 : inspectorColumn.frame.width
        column.band.frame = NSRect(
            x: 0, y: 0, width: width + inspectorRoom, height: Self.metrics.toolbar.minHeight)
        column.bandLine.frame = NSRect(x: 0, y: top, width: width, height: WorkspaceBandLine.height(in: window))
        column.mainCell.frame = NSRect(x: 0, y: top, width: width, height: max(0, height - top))
        // A closing panel stays over the content's right edge, out of reach, while it slides away.
        if inspectorCell.superview === column {
            inspectorCell.frame = NSRect(
                x: width - panes.inspectorWidth, y: top, width: panes.inspectorWidth, height: max(0, height - top))
        }
    }

    /// The inspector column: the resizer on its leading edge and the panel, both from under the title bar down.
    fileprivate func layoutInspector(_ column: WorkspaceInspectorColumn) {
        let resizer = Self.metrics.explorer.resizerWidth
        let height = column.bounds.height
        let top = panesTop
        let shown = isReady && infoPanelOpen
        column.resizer.isHidden = !shown
        // From the window's top, as the content's: the band has one color over both.
        column.backdrop.frame = column.bounds
        column.resizer.frame = NSRect(x: 0, y: top, width: resizer, height: max(0, height - top))
        column.band.frame = NSRect(x: 0, y: 0, width: column.bounds.width, height: Self.metrics.toolbar.minHeight)
        column.bandLine.frame = NSRect(
            x: 0, y: top, width: column.bounds.width, height: WorkspaceBandLine.height(in: window))
        guard column.cell.superview === column else { return }
        column.cell.isHidden = !shown
        column.cell.frame = NSRect(x: resizer, y: top, width: panes.inspectorWidth, height: max(0, height - top))
        if slide == nil { column.cell.contentOffset = 0 }
    }

    /// The sidebar column: the tree from the window's top, its resizer on its trailing edge. The column's own material
    /// is the sidebar, up to the column's edge all the way down: nothing lies over it (D-017).
    fileprivate func layoutSidebar(_ column: WorkspaceSidebarColumn) {
        let resizer = Self.metrics.explorer.resizerWidth
        let height = column.bounds.height
        let tree = max(0, column.bounds.width - resizer)
        for view in column.subviews { view.isHidden = !isReady }
        guard isReady else { return }
        column.cell.frame = NSRect(x: 0, y: 0, width: tree, height: height)
        column.resizer.frame = NSRect(x: tree, y: 0, width: resizer, height: height)
        column.resizer.panesTop = panesTop
    }

    // MARK: The Info panel's slide

    /// 220 ms with the standard easing (`PANE_LAYOUT_CHANGE_MS`).
    static var slideDuration: Double { DesignTokens.motion.slow / 1000 }

    private func startSlide(_ kind: Slide) {
        slide = kind
        // The item opens or closes at once, so the content has its new width from the start. A closing item takes its
        // view with it: for the slide the panel lies in the content column, over the content's right edge.
        rehomeInspectorCell(in: kind == .slidingOut ? contentColumn : inspectorColumn)
        layoutSubtreeIfNeeded()
        contentColumn.layoutSubtreeIfNeeded()
        inspectorColumn.layoutSubtreeIfNeeded()
        let width = panes.inspectorWidth
        let easing = DesignTokens.motion.easing
        inspectorCell.contentOffset = kind == .slidingIn ? width : 0
        inspectorCell.layoutSubtreeIfNeeded()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.slideDuration
            context.timingFunction = CAMediaTimingFunction(
                controlPoints: Float(easing.x1), Float(easing.y1), Float(easing.x2), Float(easing.y2))
            context.allowsImplicitAnimation = true
            inspectorCell.contentOffset = kind == .slidingIn ? 0 : width
            inspectorCell.layoutSubtreeIfNeeded()
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.slide == kind else { return }
                self.slide = nil
                self.rehomeInspectorCell(in: self.inspectorColumn)
                self.needsLayout = true
            }
        }
    }

    private func rehomeInspectorCell(in column: NSView) {
        guard inspectorCell.superview !== column else { return }
        if column === inspectorColumn {
            // Under the resizer, as the column first places them.
            column.addSubview(inspectorCell, positioned: .below, relativeTo: inspectorResizer)
        } else {
            column.addSubview(inspectorCell)
        }
        column.needsLayout = true
    }
}

/// The sidebar item's view.
final class WorkspaceSidebarColumn: NSView {
    fileprivate weak var workspace: WorkspaceView?
    let cell = WorkspaceCell()
    let resizer = PaneResizerView(pane: .tree, identifier: "pane.resizer.tree", label: "Resize folders pane")

    override init(frame: NSRect) {
        super.init(frame: frame)
        cell.setAccessibilityIdentifier("sidebar")
        for view in [cell, resizer] as [NSView] { addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        workspace?.layoutSidebar(self)
    }
}

/// The split of the window: the sidebar's resizer is the edge between its items, so the split draws no divider and
/// keeps no room for one (the content column starts at the sidebar's width, as the original's grid column does).
final class WorkspaceSplitView: NSSplitView {
    override var dividerThickness: CGFloat { 0 }
    override func drawDivider(in rect: NSRect) {}
}

/// The inspector item's view: its background from the window's top, as the content's, the resizer and the Info panel.
final class WorkspaceInspectorColumn: NSView {
    fileprivate weak var workspace: WorkspaceView?
    let backdrop = NSView()
    let resizer = PaneResizerView(
        pane: .inspector, identifier: "pane.resizer.inspector", label: "Resize Info Panel pane")
    let cell = WorkspaceCell()
    /// The band over this column: Finder's line goes across the panel too, and the pointer over either shows it.
    let band = WorkspaceBandPlace()
    let bandLine = WorkspaceBandLine()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        cell.setAccessibilityIdentifier("workspace.inspector")
        cell.layer?.masksToBounds = true
        backdrop.wantsLayer = true
        for view in [backdrop, band, cell, resizer, bandLine] as [NSView] { addSubview(view) }
        bandLine.isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        workspace?.layoutInspector(self)
    }
}

/// The content item's view.
final class WorkspaceContentColumn: NSView {
    fileprivate weak var workspace: WorkspaceView?
    /// The panes' color, from the window's top: the band is the content's color with nothing between them, as under
    /// Finder's toolbar, in every appearance.
    let backdrop = NSView()
    /// Where the original's `header.window-toolbar` is: the place of the system's band over the content column.
    let band = WorkspaceBandPlace()
    /// Finder's line under the band: only while the pointer is over the band.
    let bandLine = WorkspaceBandLine()
    let mainCell = WorkspaceCell()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        mainCell.setAccessibilityIdentifier("workspace.main")
        // The rows that reached the old hairline stop at the sidebar's edge.
        mainCell.layer?.masksToBounds = true
        backdrop.wantsLayer = true
        for view in [backdrop, band, mainCell, bandLine] as [NSView] { addSubview(view) }
        band.setAccessibilityIdentifier("toolbar.band")
        bandLine.isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        workspace?.layoutContent(self)
    }
}

/// A cell of the workspace grid; its one view fills it, below `contentTop`.
final class WorkspaceCell: NSView {
    var content: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let content { addSubview(content) }
            needsLayout = true
        }
    }
    var contentTop = 0.0 {
        didSet { needsLayout = true }
    }
    /// How far the content is moved to the right (the Info panel sliding).
    var contentOffset = 0.0 {
        didSet { needsLayout = true }
    }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        content?.frame = NSRect(
            x: contentOffset, y: contentTop, width: bounds.width, height: max(0, bounds.height - contentTop))
    }
}

/// The capture's "toolbar" (`header.window-toolbar`) and what a dialog's title bar veil lines up with: the place of the
/// system's band over the content column, from the window's top. It draws nothing and takes no presses, and tells when
/// the pointer is over it: a tracking area goes by the pointer alone, whatever of the title bar lies over this view.
final class WorkspaceBandPlace: NSView {
    var onHover: (Bool) -> Void = { _ in }

    override init(frame: NSRect) {
        super.init(frame: frame)
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func mouseEntered(with event: NSEvent) { onHover(true) }
    override func mouseExited(with event: NSEvent) { onHover(false) }
}

/// The line Finder shows under its toolbar while the pointer is over it: one device pixel across the content column, just
/// under the title bar. Drawn because the system's own (its scroll pocket's) comes with a scroll view reaching under the
/// toolbar, which the panes' rows don't (D-015).
final class WorkspaceBandLine: NSView {
    /// The system's separator, which is Finder's line: stored as 229 over white in its screenshot.
    static var color: NSColor { NSColor.separatorColor }

    static func height(in window: NSWindow?) -> Double { 1 / (window?.backingScaleFactor ?? 2) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
