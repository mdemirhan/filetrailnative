// Port of .modal-scrim and .go-to-folder-backdrop (apps/desktop/src/renderer/styles.css:1229-1243, 3440-3449) and of the
// focus trap of apps/desktop/src/renderer/components/useDialogFocus.ts
import AppKit
import FTFoundation

/// What a dialog drawn in the window does with the keyboard.
@MainActor
protocol DialogPanel: NSView {
    /// The view the keyboard starts in, and comes back to when it falls out of the panel.
    var initialResponder: NSView? { get }
    /// A key pressed while the dialog is in front; true when the dialog took it.
    func handleKey(_ event: NSEvent) -> Bool
    /// The panel's size for a window content of `size`.
    func panelSize(in size: NSSize) -> NSSize
    /// Whether the folder pane keeps its focused look under the panel. A dialog that takes the focus blurs the pane, and
    /// with the dialog up nothing gives `focusedPane` back, so the selection goes gray.
    var keepsPaneFocus: Bool { get }
}

extension DialogPanel {
    var keepsPaneFocus: Bool { false }
}

/// A dialog drawn in the window, the way the original draws its alerts and boxes: a scrim (`--scrim`) over the whole
/// window, the panel centred on it or dropped 60 below the window's top. The window behind takes no mouse and no key
/// while it is up. It needs no screen: a window that is never shown draws and answers it the same way.
@MainActor
final class DialogScrim: NSView {
    enum Placement {
        /// An alert: in the middle.
        case centered
        /// The Go To box: below the toolbar, as a sheet drops in.
        case sheet
    }

    let panel: any DialogPanel
    let placement: Placement
    /// A press on the scrim itself (not on the panel); nil leaves it doing nothing, as for an alert.
    var onScrimPress: (() -> Void)?
    /// Told once the dialog is taken away.
    var onDismiss: () -> Void = {}
    /// Told when the window closes with the dialog still up; the dialog goes without a word.
    var onWindowClose: (() -> Void)?
    private var interceptor: Int?
    private var themeObservation: AppearanceModel.Observation?
    /// The scrim's part over the toolbar band, which the system's title bar draws over the window's content.
    private(set) var titlebarVeil: DialogTitlebarVeil?
    private weak var previousResponder: NSResponder?
    private(set) var isDismissed = false

    init(panel: any DialogPanel, placement: Placement) {
        self.panel = panel
        self.placement = placement
        super.init(frame: .zero)
        setAccessibilityIdentifier(placement == .sheet ? "goToFolder.scrim" : "alert.scrim")
        addSubview(panel)
        themeObservation = AppearanceModel.shared.observe { [weak self] theme in
            guard let self else { return }
            self.needsDisplay = true
            self.titlebarVeil?.needsDisplay = true
            self.applyTheme(theme, throughSubviews: true)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    /// The dialogs drawn in `window`, the one in front last.
    static func all(in window: NSWindow?) -> [DialogScrim] {
        window?.contentView?.subviews.compactMap { $0 as? DialogScrim }.filter { !$0.isDismissed } ?? []
    }

    /// The dialog in front in `window`.
    static func front(in window: NSWindow?) -> DialogScrim? { all(in: window).last }

    /// Shows the dialog over `window`'s content, the keyboard in it.
    func present(in window: NSWindow) {
        guard let host = window.contentView else { return }
        previousResponder = window.firstResponder
        // A field being typed in has its field editor as the responder, which leaves the window with the editing.
        if let editor = window.firstResponder as? NSTextView, editor.isFieldEditor,
            let field = editor.delegate as? NSView
        {
            previousField = (field, editor.selectedRange())
        }
        frame = host.bounds
        autoresizingMask = [.width, .height]
        host.addSubview(self, positioned: .above, relativeTo: nil)
        installTitlebarVeil(in: window)
        layoutSubtreeIfNeeded()
        interceptor = WindowEventRouting.add(window) { [weak self] event in self?.intercept(event) ?? false }
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowWillClose(_:)), name: NSWindow.willCloseNotification, object: window)
        if let responder = panel.initialResponder { window.makeFirstResponder(responder) }
        if panel.keepsPaneFocus { holdPaneFocus(in: window) }
        refreshToolbar(of: window)
    }

    /// The toolbar's items ask `canPerform`, whose answer the dialog just changed: they dim under it at once, as the
    /// original's `disabled` follows its state, not only at the next change of selection.
    private func refreshToolbar(of window: NSWindow?) {
        (window as? ExplorerTabWindow)?.explorerTab?.explorerToolbar.refreshStates()
    }

    /// The folder pane that had the keyboard when a panel that `keepsPaneFocus` opened: the selection stays in the accent
    /// while the keyboard is in the panel.
    private weak var heldPane: (any FolderPane)?

    private func holdPaneFocus(in window: NSWindow) {
        guard let tab = window.windowController as? MainWindowController, let pane = tab.content.pane,
            let previous = previousResponder as? NSView,
            previous === pane.focusView || previous.isDescendant(of: pane.focusView)
        else { return }
        heldPane = pane
        Self.setKeyboard(of: pane, true)
    }

    private static func setKeyboard(of pane: any FolderPane, _ has: Bool) {
        if let list = pane as? ListViewController {
            list.keyboardChanged(has)
        } else if let grid = pane as? ItemGridPane {
            grid.keyboardChanged(has)
        }
    }

    /// The field that was being typed in when the dialog opened, and what was selected in it.
    private var previousField: (view: NSView, selected: NSRange)?

    /// Takes the dialog away; the keyboard goes back where it was (`useDialogFocus`).
    func dismiss(restoringFocus: Bool = true) {
        guard !isDismissed else { return }
        isDismissed = true
        let window = window
        if let interceptor, let window { WindowEventRouting.remove(interceptor, from: window) }
        interceptor = nil
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: nil)
        titlebarVeil?.removeFromSuperview()
        titlebarVeil = nil
        removeFromSuperview()
        if restoringFocus, let window { restoreKeyboard(in: window) }
        if let pane = heldPane {
            heldPane = nil
            Self.setKeyboard(of: pane, pane.focusView.window?.firstResponder === pane.focusView)
        }
        onDismiss()
        refreshToolbar(of: window)
    }

    /// To the field that was being typed in, with what was selected in it; else to what had the keyboard. When neither
    /// is there any more (the opening took the field away) a pane takes it, unless a dialog is still up (B-NAV-223).
    private func restoreKeyboard(in window: NSWindow) {
        if let (field, selected) = previousField, field.window === window, !field.isHiddenOrHasHiddenAncestor {
            window.makeFirstResponder(field)
            (field as? NSControl)?.currentEditor()?.selectedRange = selected
        } else if previousField == nil, let previous = previousResponder,
            (previous as? NSView)?.window === window || previous === window
        {
            window.makeFirstResponder(previous)
        } else if DialogScrim.front(in: window) == nil {
            (window.windowController as? MainWindowController)?.keyboardBackToPane()
        }
    }

    @objc private func windowWillClose(_ notification: Notification) {
        guard !isDismissed else { return }
        let told = onWindowClose
        dismiss(restoringFocus: false)
        told?()
    }

    override func layout() {
        super.layout()
        let room = placement == .sheet ? tabBarRoom : 0
        let size = panel.panelSize(in: NSSize(width: bounds.width, height: bounds.height - room))
        let x = ((bounds.width - size.width) / 2).rounded()
        let y: CGFloat =
            switch placement {
            case .centered: max(0, ((bounds.height - size.height) / 2).rounded())
            case .sheet: CGFloat(DialogLayout.sheetTop) + room
            }
        panel.frame = NSRect(x: x, y: y, width: size.width, height: size.height)
        placeTitlebarVeil()
        needsDisplay = true
    }

    /// The system tab bar lies over the content, under the band: a sheet starts that much lower, or the bar hides its top.
    private var tabBarRoom: CGFloat {
        guard let window, window.contentView is WorkspaceView else { return 0 }
        return max(0, WindowChrome.panesTop(window) - WorkspaceView.metrics.toolbar.minHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(AppearanceModel.shared.theme.palette.scrim).setFill()
        for rect in dimmedRects { rect.fill() }
        // The original's sidebar reads darker under its scrim than the content does (its page there is clear over the
        // window's material); the sidebar item's own material takes a little more to match.
        if let sidebar = sidebarRect, !sidebar.isEmpty {
            NSColor.black.withAlphaComponent(CGFloat(Self.sidebarExtraAlpha)).setFill()
            sidebar.fill(using: .sourceOver)
        }
        drawPanelShadow()
    }

    /// The soft drops of `--elevation-dialog` under the panel, largest first as CSS paints them. They are drawn here,
    /// not by the panel's layer: a layer's `shadowOffset` went upward under the sheets (17, 218) though down under the
    /// alert with the same value, and a layer takes only one of the two drops. A context's shadow goes the same way.
    private func drawPanelShadow() {
        let palette = AppearanceModel.shared.theme.palette
        let radius = panel.layer?.cornerRadius ?? CGFloat(DesignTokens.radii.dialog)
        let shape = NSBezierPath(roundedRect: panel.frame, xRadius: radius, yRadius: radius)
        NSColor(palette.bgElevated).setFill()
        for drop in palette.elevationDialog.filter({ $0.blur > 0 }).reversed() {
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor(drop.color)
            shadow.shadowBlurRadius = CGFloat(drop.blur)
            shadow.shadowOffset = NSSize(width: drop.x, height: -drop.y)
            shadow.set()
            shape.fill()
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    /// Where the scrim itself dims: everywhere but under the title bar veil. The title bar is clear, so the part under
    /// the veil would dim twice.
    var dimmedRects: [NSRect] {
        guard let veil = titlebarVeil, veil.superview != nil else { return [bounds] }
        let clear = convert(veil.bounds, from: veil).intersection(bounds)
        guard !clear.isEmpty else { return [bounds] }
        let left = NSRect(x: bounds.minX, y: clear.minY, width: clear.minX - bounds.minX, height: clear.height)
        let right = NSRect(x: clear.maxX, y: clear.minY, width: bounds.maxX - clear.maxX, height: clear.height)
        let above = NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: clear.minY - bounds.minY)
        let below = NSRect(x: bounds.minX, y: clear.maxY, width: bounds.width, height: bounds.maxY - clear.maxY)
        return [above, left, right, below].filter { !$0.isEmpty }
    }

    /// The black laid over the sidebar on top of the scrim (measured against the original's captures: its sidebar
    /// dims to 80% under the light scrim, the content to 88%).
    static let sidebarExtraAlpha = 0.075

    /// The sidebar, up to its edge, in the scrim's coordinates; nil in a window without one or with the tree hidden.
    var sidebarRect: NSRect? {
        guard let workspace = window?.contentView as? WorkspaceView, workspace.folderTreeOpen else { return nil }
        let column = workspace.sidebarColumn
        guard !column.isHidden, column.window != nil, column.bounds.width > 0 else { return nil }
        return convert(column.bounds, from: column).intersection(bounds)
    }

    // MARK: Title bar

    /// The system's title bar (the toolbar's items, and the tab bar) is drawn over the window's content, so the scrim
    /// in the content can't reach it: a veil laid into the title bar under the window's buttons dims the band over
    /// the content column, as the original's scrim covers its toolbar; the band's items' presses are the scrim's.
    private func installTitlebarVeil(in window: NSWindow) {
        guard let close = window.standardWindowButton(.closeButton), let titlebar = close.superview else { return }
        let veil = DialogTitlebarVeil(scrim: self)
        titlebar.addSubview(veil, positioned: .below, relativeTo: close)
        titlebarVeil = veil
        placeTitlebarVeil()
    }

    private func placeTitlebarVeil() {
        guard let veil = titlebarVeil, let titlebar = veil.superview, let window else { return }
        var left: CGFloat = 0
        if let workspace = window.contentView as? WorkspaceView {
            let band = workspace.contentColumn.band
            if band.window != nil {
                left = titlebar.convert(band.convert(band.bounds, to: nil), from: nil).minX
            }
        }
        left = min(max(0, left), titlebar.bounds.width)
        veil.frame = NSRect(x: left, y: 0, width: titlebar.bounds.width - left, height: titlebar.bounds.height)
        veil.autoresizingMask = [.width, .height]
        needsDisplay = true
    }

    /// What a press in the band does while the dialog is up.
    enum TitlebarPress: Equatable {
        /// The press is on one of the band's no-drag items (a toolbar button, the search field, the view switch),
        /// which the scrim covers: it is a press on the scrim.
        case scrim
        /// The press is on the band's empty room (`.window-toolbar` is `-webkit-app-region: drag`, and the scrim sets
        /// no `no-drag`): macOS takes it to move the window, and the page, scrim and all, never sees it.
        case dragWindow
    }

    /// What a press at `location` (window coordinates) under the title bar veil does; nil outside the veil or on the
    /// window's buttons, which keep their presses.
    func titlebarPress(at location: NSPoint) -> TitlebarPress? {
        guard let veil = titlebarVeil, let window, veil.window === window, !veil.isHiddenOrHasHiddenAncestor,
            veil.convert(veil.bounds, to: nil).contains(location)
        else { return nil }
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window.standardWindowButton(type), !button.isHiddenOrHasHiddenAncestor else { continue }
            if button.convert(button.bounds, to: nil).contains(location) { return nil }
        }
        let toolbar = (window as? ExplorerTabWindow)?.explorerTab?.explorerToolbar
        return toolbar?.hasPressableItem(at: location) == true ? .scrim : .dragWindow
    }

    /// A press in the band while this dialog is in front: on an item it is the scrim's (a left press is a press on
    /// the scrim; the others do nothing), and true keeps it from the item. A press on the empty room goes on, to the
    /// system's toolbar, which drags the window.
    private func interceptTitlebarPress(_ event: NSEvent) -> Bool {
        let presses: [NSEvent.EventType] = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        guard presses.contains(event.type), let window, event.window == nil || event.window === window,
            DialogScrim.front(in: window) === self, titlebarPress(at: event.locationInWindow) == .scrim
        else { return false }
        if event.type == .leftMouseDown { onScrimPress?() }
        return true
    }

    // MARK: Mouse

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, frame.contains(point) else { return nil }
        // The panel's own views take theirs; anywhere else the scrim does, so nothing behind it is reached.
        return super.hitTest(point) ?? self
    }

    /// A press on the panel's plain views (its padding, labels, the field's frame, the footer) comes up the responder
    /// chain to here; only one on the scrim itself counts (`event.target === event.currentTarget`).
    override func mouseDown(with event: NSEvent) {
        guard !panel.frame.contains(convert(event.locationInWindow, from: nil)) else { return }
        onScrimPress?()
    }
    override func rightMouseDown(with event: NSEvent) {}
    override func otherMouseDown(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    // MARK: Keys

    /// A key with ⌘ reaches the window's views before the menu bar: the dialog's own (⌘⌫, ⌘.) are its. The rest go
    /// on to the menu, whose commands wait while a dialog is up (only a field's editing commands still act).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, let window, DialogScrim.front(in: window) === self else { return false }
        return panel.handleKey(event)
    }

    /// The window's key events while the dialog is in front: the dialog's keys, Tab kept inside the panel, and the
    /// keyboard brought back into the panel when it fell out of it. A press on one of the band's items is the scrim's.
    private func intercept(_ event: NSEvent) -> Bool {
        if interceptTitlebarPress(event) { return true }
        guard event.type == .keyDown, let window, DialogScrim.front(in: window) === self else { return false }
        if !holdsKeyboard(window), let responder = panel.initialResponder {
            window.makeFirstResponder(responder)
        }
        if panel.handleKey(event) { return true }
        if event.keyCode == KeyCode.tab {
            cycleFocus(backward: event.modifierFlags.contains(.shift))
            return true
        }
        return false
    }

    func holdsKeyboard(_ window: NSWindow) -> Bool {
        guard let responder = window.firstResponder else { return false }
        if let editor = responder as? NSTextView, editor.isFieldEditor, let field = editor.delegate as? NSView {
            return field.isDescendant(of: panel)
        }
        return (responder as? NSView)?.isDescendant(of: panel) == true
    }

    /// Tab and ⇧Tab go round the panel's fields and enabled buttons, wrapping at either end.
    func cycleFocus(backward: Bool) {
        guard let window else { return }
        let focusable = Self.focusable(in: panel)
        guard !focusable.isEmpty else { return }
        let current = focusable.firstIndex { view in
            if let editor = window.firstResponder as? NSTextView, editor.isFieldEditor {
                return editor.delegate as? NSView === view
            }
            return window.firstResponder === view
        }
        let next: Int =
            if backward {
                current.map { $0 <= 0 ? focusable.count - 1 : $0 - 1 } ?? focusable.count - 1
            } else {
                current.map { $0 >= focusable.count - 1 ? 0 : $0 + 1 } ?? 0
            }
        window.makeFirstResponder(focusable[next])
    }

    /// `getFocusableElements`: the panel's editable fields and enabled buttons, in the order they are drawn.
    static func focusable(in root: NSView) -> [NSView] {
        var found: [NSView] = []
        func visit(_ view: NSView) {
            guard !view.isHidden else { return }
            if let field = view as? NSTextField, field.isEditable, field.isEnabled {
                found.append(field)
            } else if let button = view as? NSButton {
                if button.isEnabled { found.append(button) }
            } else if view !== root, view.acceptsFirstResponder, view is GoToRowView || view is ClearButton {
                found.append(view)
            }
            for child in view.subviews { visit(child) }
        }
        visit(root)
        return found.sorted { a, b in
            let ra = a.convert(a.bounds, to: root)
            let rb = b.convert(b.bounds, to: root)
            if abs(ra.minY - rb.minY) > 1 { return root.isFlipped ? ra.minY < rb.minY : ra.minY > rb.minY }
            return ra.minX < rb.minX
        }
    }
}

/// The scrim's part over the toolbar band (`.modal-scrim` covers the whole window): the scrim's color, laid into the
/// system's title bar under the window's buttons. The band stays the window's drag region: a press on its empty room
/// moves the window, and only a press on one of its items is a press on the scrim.
@MainActor
final class DialogTitlebarVeil: NSView {
    private weak var scrim: DialogScrim?

    init(scrim: DialogScrim) {
        self.scrim = scrim
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isOpaque: Bool { false }

    /// The system tab bar lies over the content, under the band: a sheet starts that much lower, or the bar hides its top.
    private var tabBarRoom: CGFloat {
        guard let window, window.contentView is WorkspaceView else { return 0 }
        return max(0, WindowChrome.panesTop(window) - WorkspaceView.metrics.toolbar.minHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(AppearanceModel.shared.theme.palette.scrim).setFill()
        bounds.fill(using: .sourceOver)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, frame.contains(point) else { return nil }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        switch scrim?.titlebarPress(at: event.locationInWindow) {
        case .scrim: scrim?.onScrimPress?()
        case .dragWindow:
            if event.clickCount == 2 {
                window?.performZoom(nil)
            } else {
                window?.performDrag(with: event)
            }
        case nil: break
        }
    }

    override func rightMouseDown(with event: NSEvent) {}
    override func otherMouseDown(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
}

/// The key codes the dialogs read.
enum KeyCode {
    static let returnKey: UInt16 = 36
    static let tab: UInt16 = 48
    static let delete: UInt16 = 51
    static let escape: UInt16 = 53
    static let keypadEnter: UInt16 = 76
    static let down: UInt16 = 125
    static let up: UInt16 = 126
    static let period: UInt16 = 47

    /// Escape, or ⌘. (`isModalCancelKey`).
    static func isCancel(_ event: NSEvent) -> Bool {
        if event.keyCode == escape { return true }
        return event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "."
    }

    static func isReturn(_ event: NSEvent) -> Bool {
        event.keyCode == returnKey || event.keyCode == keypadEnter
    }
}
