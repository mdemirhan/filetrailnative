// Port of the workspace grid of apps/desktop/src/renderer/components/ExplorerWorkspace.tsx:1786-1879, the pane widths
// of hooks/useExplorerPaneLayout.ts and the translucent sidebar rules of styles.css:8113-8185
import AppKit
import FTFoundation

/// The explorer window's grid: the folder tree (the full window height, under the traffic lights), an 8 pt resizer,
/// the content, and an 8 pt resizer and the Info panel while it is open. The toolbar covers the content and the Info
/// panel only; the system tab bar (D-001) shows under it. A hidden tree takes no room. The sidebar is translucent
/// (the sidebar material with the sidebar color at 62% over it); everything else is opaque.
final class WorkspaceView: NSView {
    let toolbar = ToolbarView()
    private let sidebarBackdrop = NSVisualEffectView()
    private let sidebarTint = NSView()
    /// `.workspace-sidebar-cell` (the tree pane): the sidebar's views go in it.
    let sidebarCell = WorkspaceCell()
    let treeResizer = PaneResizerView(pane: .tree, identifier: "pane.resizer.tree", label: "Resize folders pane")
    /// `.workspace-main-cell`: the content pane.
    let mainCell = WorkspaceCell()
    let inspectorResizer = PaneResizerView(
        pane: .inspector, identifier: "pane.resizer.inspector", label: "Resize Info Panel pane")
    /// `.workspace-inspector-cell`: the Info panel.
    let inspectorCell = WorkspaceCell()
    private let scrim = WorkspaceScrim()

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
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityIdentifier("window.content")
        sidebarBackdrop.material = .sidebar
        sidebarBackdrop.blendingMode = .behindWindow
        sidebarBackdrop.state = .followsWindowActiveState
        sidebarTint.wantsLayer = true
        sidebarBackdrop.addSubview(sidebarTint)
        sidebarCell.setAccessibilityIdentifier("sidebar")
        mainCell.setAccessibilityIdentifier("workspace.main")
        inspectorCell.setAccessibilityIdentifier("workspace.inspector")
        inspectorCell.wantsLayer = true
        inspectorCell.layer?.masksToBounds = true
        for view in [sidebarBackdrop, sidebarCell, mainCell, inspectorCell, treeResizer, inspectorResizer] as [NSView] {
            addSubview(view)
        }
        addSubview(scrim)
        addSubview(toolbar)
        scrim.isHidden = true
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
        treeResizer.sidebarHalf = true
        treeResizer.toolbarRowHeight = Self.metrics.toolbar.minHeight
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    private var titlebarObserver: (any NSObjectProtocol)?

    /// The title bar's container changes height when the system tab bar shows or goes, and AppKit sets it back on
    /// its own layouts: the band and the panes are laid out again each time.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let titlebarObserver { NotificationCenter.default.removeObserver(titlebarObserver) }
        titlebarObserver = nil
        guard let container = window?.standardWindowButton(.closeButton)?.superview?.superview else { return }
        container.postsFrameChangedNotifications = true
        titlebarObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: container, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.needsLayout = true } }
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
        toolbar.underTrafficLights = !folderTree
        if infoChanged, isReady, window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            startSlide(infoPanel ? .slidingIn : .slidingOut)
        } else if infoChanged {
            slide = nil
        }
        needsLayout = true
    }

    // MARK: Layout

    /// The height of the band the toolbar sits in, and of the system tab bar under it.
    private var bandHeight: Double { Self.metrics.toolbar.minHeight }

    private var tabBarHeight: Double { window.map(WindowChrome.tabBarHeight) ?? 0 }

    override func layout() {
        super.layout()
        if let window { WindowChrome.apply(window, bandHeight: bandHeight) }
        let layout = Self.metrics.explorer
        let width = bounds.width
        let height = bounds.height
        panes.sync(viewportWidth: width, inspectorVisible: infoPanelOpen)
        for view in subviews where view !== scrim { view.isHidden = !isReady }
        guard isReady else { return }
        let tree = folderTreeOpen ? panes.treeWidth : 0
        let resizer = folderTreeOpen ? layout.resizerWidth : 0
        let inspector = infoPanelOpen ? panes.inspectorWidth : 0
        let inspectorColumn = infoPanelOpen ? layout.resizerWidth + inspector : 0
        let panesTop = bandHeight + tabBarHeight
        let contentX = tree + resizer

        sidebarBackdrop.isHidden = !folderTreeOpen
        sidebarCell.isHidden = !folderTreeOpen
        treeResizer.isHidden = !folderTreeOpen
        sidebarBackdrop.frame = NSRect(x: 0, y: 0, width: tree + resizer / 2, height: height)
        sidebarTint.frame = sidebarBackdrop.bounds
        sidebarCell.frame = NSRect(x: 0, y: 0, width: tree, height: height)
        sidebarCell.contentTop = panesTop
        treeResizer.frame = NSRect(x: tree, y: 0, width: resizer, height: height)

        toolbar.frame = NSRect(x: contentX, y: 0, width: width - contentX, height: bandHeight)
        mainCell.frame = NSRect(
            x: contentX, y: panesTop, width: max(0, width - contentX - inspectorColumn), height: height - panesTop)
        inspectorResizer.isHidden = !infoPanelOpen
        inspectorResizer.frame = NSRect(
            x: width - inspectorColumn, y: panesTop, width: layout.resizerWidth, height: height - panesTop)
        // A closing panel stays over the content's right edge, out of reach, while it slides away.
        let showsInspector = infoPanelOpen || slide == .slidingOut
        inspectorCell.isHidden = !showsInspector
        inspectorCell.frame = NSRect(
            x: width - (infoPanelOpen ? inspector : panes.inspectorWidth), y: panesTop,
            width: infoPanelOpen ? inspector : panes.inspectorWidth, height: height - panesTop)
        if slide == nil { inspectorCell.contentOffset = 0 }
        scrim.frame = bounds
        placeCustomizePanel()
        applyColors()
    }

    private func applyColors() {
        let palette = ChromeColors.palette(for: self)
        layer?.backgroundColor = ChromeColors.color(palette.bgBase).cgColor
        sidebarTint.layer?.backgroundColor = ChromeColors.color(palette.sidebarBg, percent: 62).cgColor
        mainCell.layer?.backgroundColor = ChromeColors.color(palette.bgBase).cgColor
        scrim.layer?.backgroundColor =
            ChromeColors.color(palette.scrim, percent: DesignTokens.toolbarScrimAlpha * 100)
            .cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
        for view in [treeResizer, inspectorResizer, toolbar] as [NSView] { view.needsDisplay = true }
    }

    // MARK: The Info panel's slide

    /// 220 ms with the standard easing (`PANE_LAYOUT_CHANGE_MS`).
    static var slideDuration: Double { DesignTokens.motion.slow / 1000 }

    private func startSlide(_ kind: Slide) {
        slide = kind
        layoutSubtreeIfNeeded()
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
                self.needsLayout = true
            }
        }
    }

    // MARK: Customizing

    /// The rest of the window waits under a veil while the toolbar is customized.
    func setCustomizing(_ panel: ToolbarCustomizePanel?) {
        scrim.isHidden = panel == nil
        customizePanel = panel
        if let panel, panel.superview !== self { addSubview(panel) }
        placeCustomizePanel()
    }

    private weak var customizePanel: ToolbarCustomizePanel?

    /// The panel hangs 8 pt under the toolbar (from its line), centered on it, `min(760, toolbar − 32)` wide.
    private func placeCustomizePanel() {
        guard let panel = customizePanel else { return }
        let width = ToolbarCustomizePanel.width(forToolbarWidth: toolbar.frame.width)
        let height = panel.height(forWidth: width)
        let toolbarFrame = toolbar.frame
        panel.frame = NSRect(
            x: toolbarFrame.midX - width / 2, y: toolbarFrame.maxY - 1 + ToolbarCustomizePanel.gapBelowToolbar,
            width: width, height: height)
    }
}

/// A cell of the workspace grid; its one view fills it, below `contentTop` (the sidebar starts under the band).
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

/// `.toolbar-customize-scrim`: the veil over the window while the toolbar is customized; it takes every press.
final class WorkspaceScrim: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityIdentifier("toolbar.customize.scrim")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func mouseDown(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}
}
