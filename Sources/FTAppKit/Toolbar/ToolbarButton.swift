// Port of the toolbar buttons ExplorerWorkspace.tsx draws with ToolbarIcon, as system toolbar buttons
import AppKit
import FTFoundation

/// An icon-only toolbar button: the system's toolbar button, which draws its own Liquid Glass, with the original's
/// stroke icon as a template image. A toggle that is on, and a menu button with its menu open, show the system's pressed
/// look, a gray pill as on Finder's selected view: the button's real on state fills it with the accent color, whatever
/// its `tintProminence`, `bezelColor` or `contentTintColor`, so the button's `state` stays off. The presses are its own,
/// for the buttons that do more than click (Back's and Forward's hold and right-click). Tab reaches it from the search
/// field and from the buttons beside it (`ToolbarKeyboard`), where Return or Space presses it; a click leaves the
/// keyboard where it is.
class ToolbarButton: NSButton, TooltipAnchor {
    var iconName: ToolbarIconName {
        didSet {
            if iconName != oldValue { image = ToolbarGlyph.image(iconName) }
        }
    }
    /// A click: a press released over the button.
    var onClick: (() -> Void)?
    /// What a press, its end and a right-click do, for buttons that do more than click (Back, Forward). A press ends with
    /// its release, or as soon as the pointer slides off the button (`onPointerLeave`), where `inside` is false.
    var onPress: (() -> Void)?
    var onRelease: ((_ inside: Bool) -> Void)?
    var onRightClick: (() -> Void)?

    var isOn = false {
        didSet { syncState() }
    }
    /// The menu it opens is open: drawn "on", and its tooltip stays quiet.
    var menuOpen = false {
        didSet {
            // The system's menu took the release of a press that opened it (a hold on Back).
            if !menuOpen { pressed = false }
            syncState()
            setAccessibilityExpanded(menuOpen)
        }
    }
    /// The tooltip (`title`); an icon button has no visible label.
    var tooltip = "" {
        didSet {
            setAccessibilityHelp(tooltip)
            TooltipController.refreshIfShowing(self)
        }
    }
    /// `aria-haspopup="menu"` of the buttons that open a menu, which a dimmed history button doesn't say.
    private let opensMenu: Bool
    private var takingKeyboard = false
    private var pressed = false
    private var pressLeft = false
    private var hoverArea: NSTrackingArea?
    /// Finder's icon button. The toolbar's control size gives the system's height of 36, but its width grows with the
    /// image, and the glyph's box has room to spare.
    static let iconOnlyWidth = 36.0

    /// The buttons that open a menu (HistoryButton, ThemeMenuButton, ClipboardButton and the two menus of
    /// ExplorerWorkspace.tsx).
    private static let menuIdentifiers: Set<String> = [
        "toolbar.back", "toolbar.forward", "toolbar.sort", "toolbar.viewOptions", "toolbar.theme", "toolbar.clipboard",
    ]

    init(icon name: ToolbarIconName, label: String, identifier: String) {
        iconName = name
        opensMenu = Self.menuIdentifiers.contains(identifier)
        super.init(frame: .zero)
        title = ""
        image = ToolbarGlyph.image(name)
        imagePosition = .imageOnly
        bezelStyle = .toolbar
        isBordered = true
        setButtonType(.pushOnPushOff)
        setAccessibilityLabel(label)
        setAccessibilityIdentifier(identifier)
        syncRole()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isEnabled: Bool {
        willSet {
            if !newValue { letKeyboardGo() }
        }
        didSet { syncRole() }
    }

    /// The button is about to stop taking the keyboard: if it has it, it goes back to the pane.
    func letKeyboardGo() {
        guard let window, window.firstResponder === self else { return }
        (window.windowController as? MainWindowController)?.keyboardBackToPane()
    }

    private func syncRole() {
        setAccessibilityRole(opensMenu && isEnabled ? .menuButton : .button)
    }

    private var showsOn: Bool { isOn || menuOpen }

    private func syncState() {
        isHighlighted = showsOn || pressed
        setAccessibilityValue(isOn)
    }

    override var intrinsicContentSize: NSSize {
        let size = super.intrinsicContentSize
        return imagePosition == .imageOnly ? NSSize(width: Self.iconOnlyWidth, height: size.height) : size
    }

    var tooltipText: String { isEnabled ? tooltip : "" }
    var tooltipIsQuiet: Bool { menuOpen }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        if let window { TooltipController.of(window).hover(self) }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if let window { TooltipController.of(window).hover(nil) }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    // A press on a button is the button's, not a drag of the window.
    override var mouseDownCanMoveWindow: Bool { false }

    // MARK: Keyboard

    /// Only Tab gives it the keyboard: a press never does.
    override var acceptsFirstResponder: Bool { takingKeyboard && isEnabled }
    override var canBecomeKeyView: Bool { false }

    /// Gives the button the keyboard; false when the window would not.
    @discardableResult
    func takeKeyboard() -> Bool {
        guard let window else { return false }
        takingKeyboard = true
        defer { takingKeyboard = false }
        return window.makeFirstResponder(self)
    }

    override func drawFocusRingMask() {
        let radius = bounds.height / 2
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
    }

    override var focusRingMaskBounds: NSRect { bounds }

    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
            super.keyDown(with: event)
            return
        }
        switch event.keyCode {
        case 36, 76, 49:
            // Return, Enter or Space: a keyboard click.
            if isEnabled { onClick?() }
        case 48:
            ToolbarKeyboard.move(from: self, backward: event.modifierFlags.contains(.shift))
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        // No click follows a Mac control-click: it is the right-click (`onContextMenu`).
        if event.modifierFlags.contains(.control) {
            rightMouseDown(with: Self.rightPress(for: event) ?? event)
            return
        }
        guard isEnabled else { return }
        pressed = true
        pressLeft = false
        syncState()
        onPress?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard pressed else { return }
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        isHighlighted = showsOn || inside
        if !inside, !pressLeft {
            pressLeft = true
            onRelease?(false)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard pressed else { return }
        pressed = false
        syncState()
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        onRelease?(inside)
        if inside { onClick?() }
    }

    /// Back's and Forward's history, and nothing from one that is dimmed; on the other buttons the toolbar's own menu
    /// (Customize Toolbar…).
    override func rightMouseDown(with event: NSEvent) {
        guard let onRightClick else {
            super.rightMouseDown(with: event)
            return
        }
        if isEnabled { onRightClick() }
    }

    /// The button with a right-click of its own (Back, Forward) under a right press. AppKit can send a press on the
    /// toolbar past the button to the toolbar's own menu (`NSView.rightMouseDown`), and the history would never open.
    static func takingRightPress(at point: NSPoint, in window: NSWindow) -> ToolbarButton? {
        var view = window.contentView?.superview?.hitTest(point)
        while let current = view {
            if let button = current as? ToolbarButton { return button.onRightClick == nil ? nil : button }
            view = current.superview
        }
        return nil
    }

    /// The right press a control-click stands for, which is what the toolbar's own menu looks for.
    private static func rightPress(for event: NSEvent) -> NSEvent? {
        NSEvent.mouseEvent(
            with: .rightMouseDown, location: event.locationInWindow, modifierFlags: event.modifierFlags,
            timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
            eventNumber: event.eventNumber, clickCount: event.clickCount, pressure: event.pressure)
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        onClick?()
        return true
    }
}

/// A place Tab stops at over a press target the system or a field draws (a field's ✕): it takes the keys and has the
/// focus ring, and presses go through it.
final class KeyboardStopView: NSView {
    var onPress: () -> Void = {}
    var onTab: (_ backward: Bool) -> Void = { _ in }
    private var takingKeyboard = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        focusRingType = .exterior
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var acceptsFirstResponder: Bool { takingKeyboard }
    override var canBecomeKeyView: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    @discardableResult
    func takeKeyboard() -> Bool {
        guard let window else { return false }
        takingKeyboard = true
        defer { takingKeyboard = false }
        return window.makeFirstResponder(self)
    }

    override func drawFocusRingMask() {
        NSBezierPath(ovalIn: bounds).fill()
    }

    override var focusRingMaskBounds: NSRect { bounds }

    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
            super.keyDown(with: event)
            return
        }
        switch event.keyCode {
        case 36, 76, 49: onPress()
        case 48: onTab(event.modifierFlags.contains(.shift))
        default: super.keyDown(with: event)
        }
    }
}

/// Tab through the toolbar, in the order of its items on screen, as the browser's Tab goes through the original's plain
/// buttons: the search field's parts are the options button, the field and the ✕ while it shows, and the view switch
/// walks its segments itself. `paneTabSwitch` only matches the panes, so the row is the browser's to walk. Before the row
/// is the tree's resizer, with the tree open (ExplorerWorkspace.tsx:1813-1833), and after it the results bar in search
/// mode; otherwise the content has the keyboard.
@MainActor
enum ToolbarKeyboard {
    /// What Tab stops at now.
    static func stops(in window: NSWindow) -> [NSView] {
        guard let toolbar = window.toolbar else { return [] }
        // A window not on screen yet has no visible items.
        let items = toolbar.visibleItems ?? toolbar.items
        return items.flatMap { item -> [NSView] in
            if let field = (item as? NSSearchToolbarItem)?.searchField as? ToolbarSearchField {
                guard !field.isHidden else { return [] }
                return [field.optionsButton, field] + (field.clearStop.isHidden ? [] : [field.clearStop])
            }
            if let viewSwitch = item.view as? ToolbarViewSwitch {
                return viewSwitch.isEnabled && !viewSwitch.isHidden ? [viewSwitch] : []
            }
            guard let button = item.view as? ToolbarButton, button.isEnabled, !button.isHidden else { return [] }
            return [button]
        }
    }

    /// Tab or Shift-Tab from `view`, one of the stops.
    static func move(from view: NSView, backward: Bool) {
        guard let window = view.window else { return }
        let all = stops(in: window)
        guard let index = all.firstIndex(where: { $0 === view }) else { return }
        let next = backward ? index - 1 : index + 1
        guard all.indices.contains(next) else {
            leaveRow(of: window, backward: backward)
            return
        }
        take(all[next], in: window, backward: backward)
    }

    private static func leaveRow(of window: NSWindow, backward: Bool) {
        guard let tab = window.windowController as? MainWindowController else { return }
        if backward, tab.panels.folderTreeOpen {
            window.makeFirstResponder(tab.workspace.treeResizer)
        } else if !backward, let header = tab.content.contentShell.searchHeader as? SearchHeaderView {
            header.enterFromStart()
        } else {
            tab.content.focusList()
        }
    }

    /// The keyboard goes to the toolbar's first stop: Tab from what comes before the row.
    static func enterFromStart(of window: NSWindow) {
        if let first = stops(in: window).first {
            take(first, in: window, backward: false)
        } else {
            leaveRow(of: window, backward: false)
        }
    }

    /// The keyboard goes to the toolbar's last stop: Shift-Tab from what comes after the row.
    static func enterFromEnd(of window: NSWindow) {
        if let last = stops(in: window).last { take(last, in: window, backward: true) }
    }

    private static func take(_ stop: NSView, in window: NSWindow, backward: Bool) {
        switch stop {
        case let button as ToolbarButton: button.takeKeyboard()
        case let viewSwitch as ToolbarViewSwitch: viewSwitch.takeKeyboard(backward: backward)
        case let options as ToolbarSearchOptionsButton: _ = options.takeKeyboard()
        case let clear as KeyboardStopView: clear.takeKeyboard()
        default: window.makeFirstResponder(stop)
        }
    }
}

extension TooltipController {
    /// A tooltip showing for `anchor` takes up its new text (`mousemove` in the original).
    static func refreshIfShowing(_ anchor: TooltipAnchor & NSView) {
        guard let window = anchor.window else { return }
        let controller = of(window)
        if controller.scheduler.anchor === anchor { controller.scheduler.refresh() }
    }
}
