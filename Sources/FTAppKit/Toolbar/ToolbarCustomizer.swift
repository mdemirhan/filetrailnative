// Port of the customizing part of apps/desktop/src/renderer/components/ExplorerWorkspace.tsx:521-948 (handles,
// drags, keys, the drag ghost) and its rules in styles.css (.toolbar-edit-layer, .toolbar-drag-ghost)
import AppKit
import FTFoundation

/// Customize Toolbar, edited in place as in Finder: the items stay where they are drawn but do nothing, a handle
/// over each one moves it, and the panel under the toolbar holds what can be added. An item dragged along the row
/// opens a gap where it will land; one dragged away is taken off when let go. Every change is saved at once; Done or
/// Escape ends customizing.
@MainActor
final class ToolbarCustomizer {
    /// An item being dragged: its place in the saved order (nil for one from the panel), and where it would land
    /// among the other items (nil while it is away from the toolbar).
    struct Drag: Equatable {
        var itemID: ToolbarItemID
        var fromIndex: Int?
        var targetIndex: Int?
    }

    /// How far the pointer moves before a press becomes a drag.
    static let dragThreshold = 4.0
    /// How far below the toolbar a dragged item still counts as over it.
    static let dropReachBelow = 28.0

    unowned let toolbar: ToolbarView
    let panel: ToolbarCustomizePanel
    let editLayer = ToolbarEditLayer()
    private let ghost = ToolbarDragGhost()
    /// Saves a new order.
    var onCommit: ([ToolbarItemID]) -> Void = { _ in }
    /// Done or Escape.
    var onFinish: () -> Void = {}

    private(set) var drag: Drag?
    private var pending: (itemID: ToolbarItemID, fromIndex: Int?, start: NSPoint)?
    /// The item pressed in the toolbar, until its gap is drawn: it is not one of the others.
    private var pressedKey: String?
    /// A drag from the panel ends in a click on the item; that click must not add it.
    private var suppressPaletteClick = false
    /// The key to give the keyboard to once the handles are laid out again.
    private var focusKey: String?
    private var flashKey: String?
    var animatesNextLayout = false
    private var interceptor: Int?

    init(toolbar: ToolbarView) {
        self.toolbar = toolbar
        panel = ToolbarCustomizePanel()
        panel.onAdd = { [weak self] id in self?.paletteClicked(id) }
        panel.onPress = { [weak self] id, point in self?.press(itemID: id, fromIndex: nil, key: nil, at: point) }
        panel.onDrag = { [weak self] point in self?.pointerMoved(to: point) }
        panel.onRelease = { [weak self] in self?.pointerUp() }
        panel.onRestoreDefaults = { [weak self] in self?.commit(ToolbarItems.defaultTopItems) }
        panel.onDone = { [weak self] in self?.onFinish() }
        editLayer.customizer = self
    }

    /// Starts: the handles go over the toolbar, the panel under it, and the window's keys come here first.
    func begin() {
        toolbar.addSubview(editLayer)
        editLayer.frame = toolbar.bounds
        editLayer.autoresizingMask = [.width, .height]
        toolbar.customizer = self
        refreshPanel()
        if let window = toolbar.window {
            interceptor = WindowEventRouting.add(window) { [weak self] event in self?.intercept(event) ?? false }
            window.makeFirstResponder(panel)
        }
    }

    func end() {
        cancelDrag()
        if let interceptor, let window = toolbar.window { WindowEventRouting.remove(interceptor, from: window) }
        interceptor = nil
        editLayer.removeFromSuperview()
        panel.removeFromSuperview()
        ghost.removeFromSuperview()
        toolbar.customizer = nil
    }

    // MARK: What the row shows

    var saved: [ToolbarItemID] { toolbar.savedItems }

    /// The saved order, with the dragged item where it would land.
    var previewItems: [ToolbarItemID] {
        guard let drag else { return saved }
        var others = saved
        if let from = drag.fromIndex, others.indices.contains(from) { others.remove(at: from) }
        guard let target = drag.targetIndex else { return others }
        return ToolbarItems.insertTopItem(others, drag.itemID, at: target)
    }

    var editSlots: [TopToolbarSlot] { TopToolbarLayout.slots(previewItems) }

    var placeholderIndex: Int? { drag?.targetIndex }

    /// Letting go now would take the dragged item off.
    var removing: Bool { drag != nil && drag?.fromIndex != nil && drag?.targetIndex == nil }

    /// The buttons the window has no room for, hidden while it is used: drawn faint, the last ones first.
    var overflowKeys: Set<String> {
        let optional = toolbar.topSlots.filter { !ToolbarItems.isRequiredTopItem($0.id) }
        let hidden = max(0, optional.count - toolbar.visibleOptionalCount)
        let editOptional = editSlots.filter { !ToolbarItems.isRequiredTopItem($0.id) }
        return Set(editOptional.suffix(hidden).map(\.key))
    }

    var isDefault: Bool { saved == ToolbarItems.defaultTopItems }

    func refreshPanel() {
        panel.items = ToolbarItems.paletteItems(excluding: saved)
        panel.draggedItem = drag?.fromIndex == nil ? drag?.itemID : nil
        panel.removing = removing
        panel.restoreEnabled = !isDefault
        panel.needsLayout = true
        panel.superview?.needsLayout = true
    }

    /// The toolbar laid its row out: a handle over each item.
    func toolbarDidLayout() {
        editLayer.frame = toolbar.bounds
        let frames = toolbar.rowFrames()
        editLayer.setHandles(
            frames.map { entry in
                let slot = editSlots.first { $0.key == entry.key }
                let id = slot?.id ?? .title
                return (entry.key, id, entry.frame, toolbar.customizer?.overflowKeys.contains(entry.key) ?? false)
            })
        if let focusKey, let handle = editLayer.handle(for: focusKey) {
            self.focusKey = nil
            toolbar.window?.makeFirstResponder(handle)
        }
        if let flashKey {
            self.flashKey = nil
            toolbar.slotViews[flashKey]?.flash(duration: DesignTokens.motion.flashSlow)
        }
    }

    // MARK: Saving

    func commit(_ next: [ToolbarItemID]) {
        guard next != saved else { return }
        onCommit(next)
        refreshPanel()
    }

    private func paletteClicked(_ id: ToolbarItemID) {
        if suppressPaletteClick {
            suppressPaletteClick = false
            return
        }
        let next = ToolbarItems.addTopItem(saved, id)
        flashKey = TopToolbarLayout.slots(next).last?.key
        commit(next)
    }

    // MARK: Dragging

    func press(itemID: ToolbarItemID, fromIndex: Int?, key: String?, at point: NSPoint) {
        guard drag == nil else { return }
        pending = (itemID, fromIndex, point)
        pressedKey = key
    }

    /// The pointer moved (window coordinates, bottom left).
    func pointerMoved(to point: NSPoint) {
        var current = drag
        if current == nil {
            guard let pending, hypot(point.x - pending.start.x, point.y - pending.start.y) >= Self.dragThreshold
            else { return }
            current = Drag(itemID: pending.itemID, fromIndex: pending.fromIndex, targetIndex: pending.fromIndex)
            if pending.fromIndex == nil { suppressPaletteClick = true }
        }
        guard var next = current else { return }
        next.targetIndex = target(for: next, at: point)
        if next != drag {
            drag = next
            pressedKey = nil
            changed()
        }
        placeGhost(at: point)
    }

    func pointerUp() {
        endDrag(commit: true)
        // The click that may follow a palette drag comes right after the pointer is let go.
        DispatchQueue.main.async { [weak self] in self?.suppressPaletteClick = false }
    }

    func cancelDrag() {
        endDrag(commit: false)
    }

    private func endDrag(commit save: Bool) {
        pending = nil
        pressedKey = nil
        guard let drag else { return }
        self.drag = nil
        ghost.removeFromSuperview()
        if save {
            if drag.fromIndex == nil {
                if let target = drag.targetIndex { commit(ToolbarItems.insertTopItem(saved, drag.itemID, at: target)) }
            } else if let from = drag.fromIndex {
                if let target = drag.targetIndex {
                    commit(ToolbarItems.moveTopItem(saved, from: from, to: target))
                } else {
                    commit(ToolbarItems.removeTopItem(saved, at: from))
                }
            }
        }
        changed()
    }

    private func changed() {
        animatesNextLayout = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        refreshPanel()
        toolbar.reload()
    }

    /// Where the dragged item would land for a pointer at `point`: its index among the other items while the
    /// pointer is over the toolbar (or just below it); otherwise nowhere, except that an item that always stays
    /// keeps its last place.
    private func target(for drag: Drag, at point: NSPoint) -> Int? {
        let bounds = toolbar.convert(toolbar.bounds, to: nil)
        // Window coordinates grow upward: "below" is a smaller y.
        let over =
            point.y <= bounds.maxY && point.y >= bounds.minY - Self.dropReachBelow && point.x >= bounds.minX
            && point.x <= bounds.maxX
        guard over else {
            return drag.fromIndex != nil && ToolbarItems.isRequiredTopItem(drag.itemID) ? drag.targetIndex : nil
        }
        let placeholder = drag.targetIndex
        let centers = toolbar.rowFrames().enumerated().compactMap { index, entry -> Double? in
            if index == placeholder && self.drag != nil { return nil }
            if entry.key == pressedKey { return nil }
            return toolbar.convert(entry.frame, to: nil).midX
        }
        return TopToolbarLayout.dropIndex(centers: centers, pointerX: point.x)
    }

    private func placeGhost(at point: NSPoint) {
        guard let drag, let host = toolbar.window?.contentView else { return }
        if ghost.superview !== host { host.addSubview(ghost) }
        ghost.configure(drag.itemID, title: toolbar.context.map(ToolbarView.title(of:)) ?? "", removing: removing)
        let size = ghost.fittingGhostSize
        let local = host.convert(point, from: nil)
        ghost.frame = NSRect(x: local.x - size.width / 2, y: local.y - size.height / 2, width: size.width, height: size.height)
    }

    // MARK: Keys

    private func intercept(_ event: NSEvent) -> Bool {
        switch event.type {
        case .keyDown where event.keyCode == 53:
            if drag != nil {
                cancelDrag()
            } else {
                onFinish()
            }
            return true
        case .rightMouseDown:
            // Right-clicks on the toolbar are swallowed while it is customized.
            return toolbar.bounds.contains(toolbar.convert(event.locationInWindow, from: nil))
        default:
            return false
        }
    }

    /// A handle's keys: ←/→ go from item to item; ⌥←/⌥→ move the item; Delete or ⌫ takes it off.
    func handleKey(_ event: NSEvent, key: String) -> Bool {
        let slots = editSlots
        guard drag == nil, let index = slots.firstIndex(where: { $0.key == key }) else { return false }
        switch event.keyCode {
        case 123, 124:
            let step = event.keyCode == 123 ? -1 : 1
            if event.modifierFlags.contains(.option) {
                let to = index + step
                guard to >= 0, to < saved.count else { return true }
                let next = ToolbarItems.moveTopItem(saved, from: index, to: to)
                focusKey = TopToolbarLayout.slots(next)[to].key
                commit(next)
                return true
            }
            if slots.indices.contains(index + step), let handle = editLayer.handle(for: slots[index + step].key) {
                toolbar.window?.makeFirstResponder(handle)
            }
            return true
        case 51, 117:
            guard !ToolbarItems.isRequiredTopItem(slots[index].id) else { return false }
            let next = ToolbarItems.removeTopItem(saved, at: index)
            let nextSlots = TopToolbarLayout.slots(next)
            focusKey = nextSlots.isEmpty ? nil : nextSlots[min(index, nextSlots.count - 1)].key
            commit(next)
            return true
        default:
            return false
        }
    }

    /// A press on a handle.
    func pressHandle(_ key: String, at point: NSPoint) {
        let slots = editSlots
        guard let index = slots.firstIndex(where: { $0.key == key }) else { return }
        press(itemID: slots[index].id, fromIndex: index, key: key, at: point)
    }
}

/// `.toolbar-edit-layer`: a handle over each item of the toolbar.
final class ToolbarEditLayer: NSView {
    weak var customizer: ToolbarCustomizer?
    private var handles: [String: ToolbarHandleView] = [:]

    override var isFlipped: Bool { true }

    func handle(for key: String) -> ToolbarHandleView? { handles[key] }

    func setHandles(_ entries: [(key: String, id: ToolbarItemID, frame: NSRect, overflow: Bool)]) {
        var keep = Set<String>()
        for entry in entries {
            keep.insert(entry.key)
            let handle = handles[entry.key] ?? {
                let made = ToolbarHandleView(key: entry.key)
                made.owner = self
                addSubview(made)
                handles[entry.key] = made
                return made
            }()
            let label = ToolbarItems.definition(entry.id).label
            handle.frame = entry.frame
            handle.label = label
            handle.tooltip =
                "\(label): "
                + (ToolbarItems.isRequiredTopItem(entry.id)
                    ? "drag to move. It is always in the toolbar." : "drag to move, or out of the toolbar to remove.")
                + (entry.overflow ? " Hidden while the window is too narrow for it." : "")
        }
        for (key, handle) in handles where !keep.contains(key) {
            handle.removeFromSuperview()
            handles.removeValue(forKey: key)
        }
    }
}

/// `.toolbar-edit-handle`: a focusable button over an item, the same size, to press and drag.
final class ToolbarHandleView: NSView, TooltipAnchor {
    let key: String
    weak var owner: ToolbarEditLayer?
    var label = "" {
        didSet { setAccessibilityLabel(label) }
    }
    var tooltip = ""
    private var hovered = false {
        didSet { needsDisplay = true }
    }

    init(key: String) {
        self.key = key
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityIdentifier("toolbar.customize.handle")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override var acceptsFirstResponder: Bool { true }
    var tooltipText: String { tooltip }
    var tooltipIsQuiet: Bool { false }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(
            NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        if let window { TooltipController.of(window).hover(self) }
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        if let window { TooltipController.of(window).hover(nil) }
    }

    override func mouseDown(with event: NSEvent) {
        owner?.customizer?.pressHandle(key, at: event.locationInWindow)
    }

    override func mouseDragged(with event: NSEvent) {
        owner?.customizer?.pointerMoved(to: event.locationInWindow)
    }

    override func mouseUp(with event: NSEvent) {
        owner?.customizer?.pointerUp()
    }

    override func keyDown(with event: NSEvent) {
        if owner?.customizer?.handleKey(event, key: key) != true { super.keyDown(with: event) }
    }

    override func draw(_ dirtyRect: NSRect) {
        let accent = ChromeColors.accent(for: self)
        let radius = bounds.height / 2
        if window?.firstResponder === self {
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: radius, yRadius: radius)
            ring.lineWidth = DesignTokens.focusRingWidth
            ChromeColors.color(accent.solid.withAlpha(0.5)).setStroke()
            ring.stroke()
        } else if hovered, owner?.customizer?.drag == nil {
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
            ring.lineWidth = 1
            ChromeColors.color(accent.solid.withAlpha(0.45)).setStroke()
            ring.stroke()
        }
    }
}

/// `.toolbar-drag-ghost`: what follows the pointer while an item is dragged.
final class ToolbarDragGhost: NSView {
    private var icons: [ToolbarIconView] = []
    private let text = NSTextField(labelWithString: "")
    private var removing = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        text.font = ChromeColors.font(size: DesignTokens.typeScale.body)
        addSubview(text)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(_ id: ToolbarItemID, title: String, removing: Bool) {
        self.removing = removing
        for icon in icons { icon.removeFromSuperview() }
        icons = []
        text.stringValue = ""
        let palette = ChromeColors.palette(for: self)
        switch id {
        case .title:
            text.stringValue = title.isEmpty ? "Title" : title
            text.font = ChromeColors.font(size: DesignTokens.typeScale.body, weight: 600)
            text.textColor = ChromeColors.color(palette.textPrimary)
        case .search:
            icons = [ToolbarIconView(.search)]
            text.stringValue = "Search"
            text.font = ChromeColors.font(size: DesignTokens.typeScale.body)
            text.textColor = ChromeColors.color(palette.textSecondary)
        case .view:
            icons = [ToolbarIconView(.icons), ToolbarIconView(.list), ToolbarIconView(.details)]
        default:
            icons = [ToolbarIconView(ToolbarItems.definition(id).icon)]
        }
        for icon in icons {
            icon.color = ChromeColors.color(palette.textPrimary)
            addSubview(icon)
        }
        alphaValue = removing ? 0.6 : 1
        layer?.backgroundColor = ChromeColors.color(palette.bgElevated).cgColor
        layer?.cornerRadius = DesignTokens.toolbar.controlHeight / 2
        layer?.shadowOpacity = 0.2
        layer?.shadowRadius = 12
        layer?.shadowOffset = CGSize(width: 0, height: -6)
        layer?.masksToBounds = false
        needsLayout = true
    }

    var fittingGhostSize: NSSize {
        let iconSize = DesignTokens.toolbar.iconSize
        var width = 16.0 + Double(icons.count) * iconSize + Double(max(0, icons.count - 1)) * 4
        if !text.stringValue.isEmpty {
            width += min(180, text.intrinsicContentSize.width) + (icons.isEmpty ? 0 : 4)
        }
        return NSSize(width: max(DesignTokens.toolbar.buttonWidth, width), height: DesignTokens.toolbar.controlHeight)
    }

    override func layout() {
        super.layout()
        let iconSize = DesignTokens.toolbar.iconSize
        var x = 8.0
        for icon in icons {
            icon.frame = NSRect(x: x, y: (bounds.height - iconSize) / 2, width: iconSize, height: iconSize)
            x += iconSize + 4
        }
        let size = text.intrinsicContentSize
        text.frame = NSRect(
            x: x, y: (bounds.height - size.height) / 2, width: min(180, bounds.width - x - 8), height: size.height)
    }
}
