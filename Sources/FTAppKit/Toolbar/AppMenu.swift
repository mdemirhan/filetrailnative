// Port of the toolbar menus of apps/desktop/src/renderer/components/ExplorerWorkspace.tsx, HistoryButton.tsx,
// ThemeMenuButton.tsx, ToolbarOverflowButton.tsx, PullDownMenu.tsx and MenuCheck.tsx, drawn as the .toolbar-menu
// rules of styles.css draw them
import AppKit
import FTFoundation

/// A view that shows its text through a text field inside it: the capture compares that field's font and color.
@MainActor
protocol TextStyleSource: AnyObject {
    var styleTextField: NSTextField? { get }
}

/// One row of an app-drawn menu.
struct AppMenuItem {
    enum Kind {
        case item, separator
    }

    var kind: Kind = .item
    var title = ""
    /// A second, smaller text after the title (the history menu's folder).
    var detail: String?
    var shortcut: String?
    /// Nil: no check column state (a plain action); true/false: a checkbox or radio item.
    var checked: Bool?
    var enabled = true
    var tooltip: String?
    var action: () -> Void = {}

    static var separator: AppMenuItem { AppMenuItem(kind: .separator) }
}

/// How a menu is worked.
enum AppMenuStyle {
    /// The pointer highlights a row; Escape closes.
    case standard
    /// The arrow keys move a mark over the rows, the pointer moves it too; Return or Space chooses, Escape or Tab
    /// closes; other keys are kept from the window, and a key with ⌘, ⌃ or ⌥ closes the menu (`HistoryButton`).
    case keyboard
}

/// `.toolbar-menu`: min 220 wide, 5 pt padding, a hairline edge, radius 10, the opaque menu background and its shadow;
/// rows 24 tall with a 16 pt check column, labels 30 pt in, shortcuts grey 14 pt after the label; separators 1 pt with
/// 5/10 margins. The highlighted row is filled with the accent's solid button color.
final class AppMenuView: NSView {
    static let padding = 5.0
    static let rowHeight = 24.0
    static let rowPaddingLeading = 8.0
    static let rowPaddingTrailing = 10.0
    static let checkColumn = 16.0
    static let rowGap = 6.0
    static let shortcutGap = 14.0
    static let separatorMargin = (vertical: 5.0, horizontal: 10.0)

    let items: [AppMenuItem]
    let style: AppMenuStyle
    let minWidth: Double
    let maxWidth: Double?
    private(set) var rows: [AppMenuRow] = []
    /// The row the arrow keys are on (keyboard menus), or the row under the pointer.
    var activeIndex: Int? {
        didSet { for (index, row) in rows.enumerated() { row.isActive = index == activeIndex } }
    }
    var onChoose: (Int) -> Void = { _ in }

    init(items: [AppMenuItem], style: AppMenuStyle, identifier: String, rowIdentifier: String, minWidth: Double = 220,
        maxWidth: Double? = nil)
    {
        self.items = items
        self.style = style
        self.minWidth = minWidth
        self.maxWidth = maxWidth
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.menu)
        setAccessibilityIdentifier(identifier)
        for (index, item) in items.enumerated() where item.kind == .item {
            let row = AppMenuRow(item: item, keyboard: style == .keyboard)
            row.setAccessibilityIdentifier(rowIdentifier)
            // A checked row is found by its tick, which carries the row's title.
            row.checkMark?.setAccessibilityIdentifier(rowIdentifier + ".checked")
            row.onHover = { [weak self] in
                guard let self, item.enabled else { return }
                self.activeIndex = self.rows.firstIndex { $0 === row }
            }
            row.onClick = { [weak self] in
                guard item.enabled else { return }
                self?.onChoose(index)
            }
            rows.append(row)
            addSubview(row)
        }
        if style == .keyboard, !rows.isEmpty { activeIndex = 0 }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    /// The menu's size: as wide as its widest row (at least `minWidth`, at most `maxWidth`).
    var fittingMenuSize: NSSize {
        var width = minWidth
        var height = 2 * Self.padding + 1
        for item in items {
            if item.kind == .separator {
                height += 1 + 2 * Self.separatorMargin.vertical
            } else {
                height += Self.rowHeight
            }
        }
        for row in rows { width = max(width, row.naturalWidth + 2 * Self.padding + 1) }
        if let maxWidth { width = min(width, maxWidth) }
        return NSSize(width: width.rounded(.up), height: height)
    }

    override func layout() {
        super.layout()
        var y = Self.padding + 0.5
        var rowIndex = 0
        for item in items {
            if item.kind == .separator {
                y += 1 + 2 * Self.separatorMargin.vertical
                continue
            }
            rows[rowIndex].frame = NSRect(
                x: Self.padding + 0.5, y: y, width: bounds.width - 2 * Self.padding - 1, height: Self.rowHeight)
            rowIndex += 1
            y += Self.rowHeight
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let palette = ChromeColors.palette(for: self)
        var y = Self.padding + 0.5
        for item in items {
            if item.kind == .separator {
                ChromeColors.color(palette.contextMenuSeparator).setFill()
                NSRect(
                    x: Self.padding + 0.5 + Self.separatorMargin.horizontal, y: y + Self.separatorMargin.vertical,
                    width: bounds.width - 2 * Self.padding - 1 - 2 * Self.separatorMargin.horizontal, height: 1
                ).fill()
                y += 1 + 2 * Self.separatorMargin.vertical
            } else {
                y += Self.rowHeight
            }
        }
    }

    override var wantsUpdateLayer: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let palette = ChromeColors.palette(for: self)
        layer?.backgroundColor = ChromeColors.color(palette.contextMenuBg).cgColor
        layer?.borderColor = ChromeColors.color(palette.contextMenuBorder).cgColor
        layer?.borderWidth = 0.5
        layer?.cornerRadius = DesignTokens.radii.menu
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = ChromeColors.appearance(of: self) == .dark ? 0.45 : 0.12
        layer?.shadowRadius = 16
        layer?.shadowOffset = CGSize(width: 0, height: -8)
    }

    /// The enabled rows, for the arrow keys.
    var enabledIndices: [Int] { rows.indices.filter { rows[$0].item.enabled } }

    /// Moves the mark one row (wrapping), as ↑ ↓ do.
    func step(_ delta: Int) {
        let count = rows.count
        guard count > 0 else { return }
        activeIndex = ((activeIndex ?? (delta > 0 ? -1 : 0)) + delta + count) % count
    }

    /// The item behind row `rowIndex`.
    func itemIndex(ofRow rowIndex: Int) -> Int? {
        var seen = -1
        for (index, item) in items.enumerated() where item.kind == .item {
            seen += 1
            if seen == rowIndex { return index }
        }
        return nil
    }
}

/// A row of an app-drawn menu: the check column, the label (and a detail), and the shortcut.
final class AppMenuRow: NSView, TextStyleSource {
    let item: AppMenuItem
    let label = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let shortcut = NSTextField(labelWithString: "")
    private let keyboard: Bool
    /// The tick of an item that is on.
    private(set) var checkMark: MenuCheckView?
    var onHover: () -> Void = {}
    var onClick: () -> Void = {}
    var isActive = false {
        didSet { applyColors() }
    }
    private var isHovered = false {
        didSet { applyColors() }
    }

    var styleTextField: NSTextField? { label }

    init(item: AppMenuItem, keyboard: Bool) {
        self.item = item
        self.keyboard = keyboard
        super.init(frame: .zero)
        let body = DesignTokens.typeScale.body
        label.stringValue = item.title
        label.font = ChromeColors.font(size: body)
        label.lineBreakMode = .byTruncatingTail
        detail.stringValue = item.detail ?? ""
        detail.font = ChromeColors.font(size: DesignTokens.typeScale.small)
        detail.lineBreakMode = .byTruncatingTail
        shortcut.stringValue = item.shortcut ?? ""
        shortcut.font = ChromeColors.font(size: body)
        for field in [label, detail, shortcut] { addSubview(field) }
        if item.checked == true {
            let mark = MenuCheckView()
            mark.setAccessibilityLabel(item.title)
            addSubview(mark)
            checkMark = mark
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.menuItem)
        setAccessibilityLabel(item.title)
        if let tooltip = item.tooltip { toolTip = tooltip }
        applyColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    /// The row's width when nothing is cut short.
    var naturalWidth: Double {
        let titleWidth = label.intrinsicContentSize.width
        if item.detail != nil {
            // `.history-menu-item`: padding 0 10, a gap of 10, the name at most 220 wide.
            return 10 + min(220, titleWidth) + 10 + detail.intrinsicContentSize.width + 10
        }
        var width =
            AppMenuView.rowPaddingLeading + AppMenuView.checkColumn + AppMenuView.rowGap + titleWidth
            + AppMenuView.rowPaddingTrailing
        if item.shortcut != nil { width += AppMenuView.rowGap + AppMenuView.shortcutGap + shortcut.intrinsicContentSize.width }
        return width
    }

    override func layout() {
        super.layout()
        func place(_ field: NSTextField, x: Double, width: Double) {
            let height = field.intrinsicContentSize.height
            field.frame = NSRect(x: x, y: ((bounds.height - height) / 2).rounded(), width: max(0, width), height: height)
        }
        let box = 11.0
        checkMark?.frame = NSRect(
            x: AppMenuView.rowPaddingLeading + (AppMenuView.checkColumn - box) / 2, y: (bounds.height - box) / 2,
            width: box, height: box)
        if item.detail != nil {
            let nameWidth = min(220, label.intrinsicContentSize.width)
            place(label, x: 10, width: nameWidth)
            place(detail, x: 10 + nameWidth + 10, width: bounds.width - nameWidth - 30)
            return
        }
        let start = AppMenuView.rowPaddingLeading + AppMenuView.checkColumn + AppMenuView.rowGap
        let shortcutWidth = item.shortcut == nil ? 0 : shortcut.intrinsicContentSize.width
        let end = bounds.width - AppMenuView.rowPaddingTrailing
        if item.shortcut != nil { place(shortcut, x: end - shortcutWidth, width: shortcutWidth) }
        let labelEnd = item.shortcut == nil ? end : end - shortcutWidth - AppMenuView.shortcutGap - AppMenuView.rowGap
        place(label, x: start, width: labelEnd - start)
    }

    private var highlighted: Bool { item.enabled && (isActive || (!keyboard && isHovered)) }

    private func applyColors() {
        let palette = ChromeColors.palette(for: self)
        let accent = ChromeColors.accent(for: self)
        let text =
            !item.enabled
            ? palette.contextMenuDisabled : highlighted ? accent.onSolid : palette.contextMenuText
        label.textColor = ChromeColors.color(text)
        checkMark?.color = ChromeColors.color(text)
        detail.textColor = ChromeColors.color(highlighted ? accent.onSolid : palette.textSecondary)
        detail.alphaValue = highlighted ? 0.8 : 1
        shortcut.textColor = ChromeColors.color(
            highlighted ? accent.onSolid.withAlpha(0.85) : item.enabled ? palette.contextMenuShortcut
                : palette.contextMenuDisabled)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if highlighted {
            ChromeColors.color(ChromeColors.accent(for: self).solidButton).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: DesignTokens.radii.control, yRadius: DesignTokens.radii.control)
                .fill()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(
            NSTrackingArea(
                rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        onHover()
    }

    override func mouseMoved(with event: NSEvent) {
        if keyboard { onHover() }
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick() }
    }

    override func accessibilityPerformPress() -> Bool {
        onClick()
        return true
    }
}

/// `MenuCheck`: the tick of a menu item that is on.
final class MenuCheckView: NSView {
    var color: NSColor = .labelColor {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        ToolbarGlyph.drawCheck(in: bounds, color: color, flipped: true)
    }
}

/// Shows one app-drawn menu at a time in a window, over everything else, and closes it as the original's menus close:
/// a press anywhere else (the button that opened it toggles it), Escape, the window going to the back, and for the
/// toolbar's menus a resize.
@MainActor
final class AppMenuPresenter {
    private(set) var menu: AppMenuView?
    /// The button that opened it: a press on it is the button's to handle.
    private weak var owner: NSView?
    private var observers: [any NSObjectProtocol] = []
    private var onClose: (() -> Void)?

    static let shared = AppMenuPresenter()

    var isOpen: Bool { menu != nil }

    func isOpen(from view: NSView) -> Bool { menu != nil && owner === view }

    /// Shows `menu` in `window` with its top left corner at `origin` (window content, from the top left).
    func show(
        _ menu: AppMenuView, in window: NSWindow, at origin: NSPoint, owner: NSView?, closesOnResize: Bool = true,
        onClose: (() -> Void)? = nil
    ) {
        close()
        guard let host = window.contentView else { return }
        self.menu = menu
        self.owner = owner
        self.onClose = onClose
        let size = menu.fittingMenuSize
        let place = MenuPlacement.keepInViewport(
            left: origin.x, top: origin.y, width: size.width, height: size.height,
            viewportWidth: host.bounds.width, viewportHeight: host.bounds.height)
        let y = host.isFlipped ? place.top : host.bounds.height - place.top - size.height
        menu.frame = NSRect(x: place.left, y: y, width: size.width, height: size.height)
        menu.onChoose = { [weak self, weak menu] index in
            guard let item = menu?.items[index] else { return }
            self?.close()
            item.action()
        }
        host.addSubview(menu)
        TooltipController.of(window).scheduler.dismiss()
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification, object: window, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.close() } })
        if closesOnResize {
            observers.append(
                NotificationCenter.default.addObserver(
                    forName: NSWindow.didResizeNotification, object: window, queue: .main
                ) { [weak self] _ in MainActor.assumeIsolated { self?.close() } })
        }
    }

    /// Below `anchor`, from the edge of it that leaves the most room (`placeDropdownMenu`).
    func drop(_ menu: AppMenuView, from anchor: NSView, owner: NSView? = nil, onClose: (() -> Void)? = nil) {
        guard let window = anchor.window, let host = window.contentView else { return }
        let rect = anchor.convert(anchor.bounds, to: host)
        let top = host.isFlipped ? rect.minY : host.bounds.height - rect.maxY
        let size = menu.fittingMenuSize
        let place = MenuPlacement.dropdown(
            anchorLeft: rect.minX, anchorRight: rect.maxX, anchorBottom: top + rect.height, menuWidth: size.width,
            menuHeight: size.height, viewportWidth: host.bounds.width, viewportHeight: host.bounds.height)
        show(menu, in: window, at: NSPoint(x: place.left, y: place.top), owner: owner ?? anchor, onClose: onClose)
    }

    func close() {
        guard let menu else { return }
        self.menu = nil
        owner = nil
        menu.removeFromSuperview()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        let done = onClose
        onClose = nil
        done?()
    }

    /// An event on its way to `window`: true when the open menu took it. A press elsewhere closes the menu and goes
    /// on to where it was pressed.
    func intercept(_ event: NSEvent, in window: NSWindow) -> Bool {
        guard let menu, menu.window === window else { return false }
        switch event.type {
        case .leftMouseDown, .rightMouseDown:
            let point = menu.convert(event.locationInWindow, from: nil)
            if menu.bounds.contains(point) { return false }
            if let owner, owner.bounds.contains(owner.convert(event.locationInWindow, from: nil)) { return false }
            close()
            return false
        case .keyDown:
            return key(event, menu: menu)
        default:
            return false
        }
    }

    /// The keys of an open menu (`HistoryButton`'s and `PullDownMenu`'s): true when the key was the menu's.
    private func key(_ event: NSEvent, menu: AppMenuView) -> Bool {
        let code = Int(event.keyCode)
        let escape = 53
        if menu.style == .standard {
            if code == escape {
                close()
                return true
            }
            return false
        }
        if !event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            close()
            return false
        }
        switch code {
        case 125: menu.step(1)
        case 126: menu.step(-1)
        case 36, 76, 49:
            if let row = menu.activeIndex, let index = menu.itemIndex(ofRow: row) { menu.onChoose(index) }
        case escape, 48: close()
        default: break
        }
        return true
    }
}

/// What an explorer window's events pass through before the window handles them: the open menu, the tooltips and
/// the toolbar's customizing take their keys and presses here, whether the event came from the system or was sent
/// to the window directly.
@MainActor
enum WindowEventRouting {
    private static var interceptors: [ObjectIdentifier: [(id: Int, handle: (NSEvent) -> Bool)]] = [:]
    private static var nextID = 0

    /// Adds a handler for `window`'s events; true from it keeps the event from the window. Returns its id.
    @discardableResult
    static func add(_ window: NSWindow, _ handle: @escaping (NSEvent) -> Bool) -> Int {
        nextID += 1
        interceptors[ObjectIdentifier(window), default: []].append((nextID, handle))
        return nextID
    }

    static func remove(_ id: Int, from window: NSWindow) {
        interceptors[ObjectIdentifier(window)]?.removeAll { $0.id == id }
    }

    static func forget(_ window: NSWindow) {
        interceptors.removeValue(forKey: ObjectIdentifier(window))
        TooltipController.remove(window)
    }

    /// True when something took the event.
    static func intercept(_ event: NSEvent, in window: NSWindow) -> Bool {
        TooltipController.of(window).observe(event)
        if AppMenuPresenter.shared.intercept(event, in: window) { return true }
        for interceptor in interceptors[ObjectIdentifier(window)] ?? [] where interceptor.handle(event) {
            return true
        }
        return false
    }
}
