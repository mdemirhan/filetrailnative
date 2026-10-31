// Port of the toolbar menus of apps/desktop/src/renderer/components/ExplorerWorkspace.tsx, HistoryButton.tsx,
// ThemeMenuButton.tsx, ToolbarOverflowButton.tsx, PullDownMenu.tsx and MenuCheck.tsx, shown as system menus (D-022)
import AppKit
import FTFoundation

/// One row of an app's menu.
struct AppMenuItem {
    enum Kind {
        /// `heading`: a small title over the items that follow (`.toolbar-menu-heading`).
        case item, separator, heading
    }

    var kind: Kind = .item
    var title = ""
    /// A second, smaller text after the title (the history menu's folder).
    var detail: String?
    var key: MenuKeyEquivalent?
    /// Nil: no check column state (a plain action); true/false: a checkbox or radio item.
    var checked: Bool?
    var enabled = true
    var tooltip: String?
    /// The app whose icon the row shows before its label (`AppIcon`).
    var appPath: String?
    /// What the capture calls this row, when it isn't the menu's name for its rows (a note in the folder menu).
    var rowIdentifier: String?
    var action: () -> Void = {}

    static var separator: AppMenuItem { AppMenuItem(kind: .separator) }

    static func heading(_ title: String) -> AppMenuItem { AppMenuItem(kind: .heading, title: title) }
}

/// A menu of the app as an `NSMenu`, one `NSMenuItem` for each of `items`.
@MainActor
final class AppMenu: NSObject, NSMenuDelegate {
    let identifier: String
    let rowIdentifier: String
    let nsMenu = NSMenu()
    private(set) var items: [AppMenuItem] = []
    /// The item the keyboard starts on (`HistoryButton`'s first row, the folder menu's ticked one), by its index in
    /// `items`. Nil: none, and the first ↓ goes to the first row.
    var markedIndex: Int?
    private let maxWidth: Double?
    private let nameMaxWidth: Double?
    /// What was chosen, by its index in `items`.
    var onChoose: (Int) -> Void = { _ in }
    /// The system closed the menu: a choice, Escape or a press elsewhere.
    var onSystemClose: () -> Void = {}
    /// Tells a stand-in for the menu that the rows changed (the capture's).
    var onItemsChange: () -> Void = {}
    /// The rows for Option up or down, for a menu that changes with it (Open With).
    private(set) var itemsForOption: ((Bool) -> [AppMenuItem])?
    private var optionHeld = false
    private(set) var isTracking = false

    init(
        items: [AppMenuItem], identifier: String, rowIdentifier: String,
        minWidth: Double = DesignTokens.menu.minWidth, maxWidth: Double? = nil, nameMaxWidth: Double? = nil
    ) {
        self.identifier = identifier
        self.rowIdentifier = rowIdentifier
        self.maxWidth = maxWidth
        self.nameMaxWidth = nameMaxWidth
        super.init()
        nsMenu.delegate = self
        nsMenu.autoenablesItems = false
        nsMenu.minimumWidth = minWidth
        setItems(items)
    }

    /// The rows that can be chosen or read, without separators and headings.
    var rows: [AppMenuItem] { items.filter { $0.kind == .item } }

    /// The system's size for it now.
    var size: NSSize { nsMenu.size }

    /// Shows `items`, also while the menu is open (the folders once they are read, Option going down).
    func setItems(_ items: [AppMenuItem]) {
        self.items = items
        nsMenu.removeAllItems()
        for (index, item) in items.enumerated() { nsMenu.addItem(makeItem(item, index: index)) }
        onItemsChange()
        if isTracking { showMark() }
    }

    private func makeItem(_ item: AppMenuItem, index: Int) -> NSMenuItem {
        switch item.kind {
        case .separator:
            return .separator()
        case .heading:
            return .sectionHeader(title: item.title)
        case .item:
            let entry = NSMenuItem(title: item.title, action: #selector(chosen(_:)), keyEquivalent: "")
            entry.target = self
            entry.tag = index
            entry.isEnabled = item.enabled
            entry.toolTip = item.tooltip
            entry.state = item.checked == true ? .on : .off
            if let key = item.key {
                entry.keyEquivalent = key.key
                entry.keyEquivalentModifierMask = key.modifiers
            }
            if let path = item.appPath { entry.showApplicationIcon(path) }
            applyText(of: item, to: entry)
            return entry
        }
    }

    /// A menu has no width of its own to cut text at: a long name or folder is cut here, as the original's row cuts it.
    private func applyText(of item: AppMenuItem, to entry: NSMenuItem) {
        let font = NSFont.menuFont(ofSize: 0)
        let small = NSFont.menuFont(ofSize: NSFont.smallSystemFontSize)
        let name = Self.cut(item.title, font: font, width: nameMaxWidth ?? maxWidth)
        guard let detail = item.detail else {
            if name != item.title { entry.title = name }
            return
        }
        let room = maxWidth.map { $0 - Self.textWidth(name, font) - Self.rowChrome }
        let title = NSMutableAttributedString(string: name, attributes: [.font: font])
        title.append(
            NSAttributedString(
                string: "  " + Self.cut(detail, font: small, width: room), attributes: [.font: small]))
        entry.attributedTitle = title
    }

    /// What a system menu's row takes beside its text: the check column and its padding.
    private static let rowChrome = 40.0

    private static func textWidth(_ text: String, _ font: NSFont) -> Double {
        (text as NSString).size(withAttributes: [.font: font]).width
    }

    static func cut(_ text: String, font: NSFont, width: Double?) -> String {
        guard let width, textWidth(text, font) > width else { return text }
        let characters = Array(text)
        var low = 0
        var high = characters.count
        while low < high {
            let middle = (low + high + 1) / 2
            if textWidth(String(characters[..<middle]) + "…", font) <= width { low = middle } else { high = middle - 1 }
        }
        return String(characters[..<low]) + "…"
    }

    @objc private func chosen(_ entry: NSMenuItem) {
        onChoose(entry.tag)
    }

    /// Option went up or down: the rows follow.
    func watchOption(held: Bool, items: @escaping (Bool) -> [AppMenuItem]) {
        optionHeld = held
        itemsForOption = items
    }

    func optionChanged(held: Bool) { optionChanged(held: held, highlighted: nsMenu.highlightedItem) }

    /// New rows take the highlighted one away with the old: the mark goes to the same row of the new ones, counted
    /// without headings and separators, or nowhere when nothing was highlighted.
    func optionChanged(held: Bool, highlighted: NSMenuItem?) {
        guard held != optionHeld, let itemsForOption else { return }
        optionHeld = held
        let new = itemsForOption(held)
        let row = highlighted.flatMap { nsMenu.items.firstIndex(of: $0) }.map { index in
            items[..<index].filter { $0.kind == .item }.count
        }
        let rows = new.indices.filter { new[$0].kind == .item }
        markedIndex = row.flatMap { rows.indices.contains($0) ? rows[$0] : nil }
        setItems(new)
    }

    fileprivate func trackingBegan() {
        isTracking = true
    }

    fileprivate func trackingEnded() {
        isTracking = false
    }

    /// Puts the system's highlight on the marked item. AppKit has no public way to do this for an open menu; without
    /// the method the menu simply opens with nothing marked.
    fileprivate func showMark() {
        let highlight = Selector(("highlightItem:"))
        guard let markedIndex, nsMenu.items.indices.contains(markedIndex), nsMenu.responds(to: highlight) else {
            return
        }
        nsMenu.perform(highlight, with: nsMenu.items[markedIndex])
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === nsMenu else { return }
        onSystemClose()
    }
}

/// Shows one of the app's menus at a time, as a system menu: the system closes it on a choice, Escape, a press anywhere
/// else and the app going to the back. The system's menu runs the keyboard while it is open.
@MainActor
final class AppMenuPresenter {
    private(set) var menu: AppMenu?
    /// Where it goes in `host`, from its top left, and the item that stands at that place when it isn't the first.
    struct MenuPlace: Equatable {
        var left: Double
        var top: Double
        var positioning: Int?
        /// The top that keeps the whole menu in the window, which a positioned menu doesn't use.
        var fittedTop: Double
    }
    private(set) var place: MenuPlace?
    private weak var host: NSView?
    /// The system's menu is closing to come up at `place`.
    private var isMoving = false
    /// The button that opened it.
    private weak var owner: NSView?
    private var onClose: (() -> Void)?
    /// The last menu shown: the system sends the chosen item's action to it after it has closed.
    private var lastClosed: AppMenu?
    private var optionTimer: Timer?
    #if DEBUG
        /// A test of the system's menu itself: elsewhere in a test or a scenario run, where the menu's tracking loop
        /// would hold up the run, the menu is `AppMenuStandIn`'s, whose rows a scenario finds and clicks.
        var forcesTracking = false
        private var tracks: Bool { forcesTracking || Self.tracksByDefault }
        private var standIn: AppMenuStandIn?
    #endif

    /// The app's presenter; a test's own while it runs in `withOwn` (test seam: windowless tests run side by side).
    static var shared: AppMenuPresenter { scoped ?? app }

    private static let app = AppMenuPresenter()
    @TaskLocal private static var scoped: AppMenuPresenter?

    /// Runs `body` with a presenter of its own as `shared` (test seam).
    nonisolated(nonsending) static func withOwn<T>(
        _ presenter: AppMenuPresenter, _ body: nonisolated(nonsending) () async throws -> T
    ) async rethrows -> T {
        try await $scoped.withValue(presenter, operation: body)
    }

    var isOpen: Bool { menu != nil }

    func isOpen(from view: NSView) -> Bool { menu != nil && owner === view }

    /// Where a window's tooltips go: its top layer, over the title bar and the toolbar band, in an explorer window;
    /// else its content. Both are the window's content area, so places in them are the same.
    static func overlayHost(of window: NSWindow) -> NSView? {
        WindowOverlayView.host(of: window) ?? window.contentView
    }

    /// Shows `menu` in `window` with its top left corner at `origin` (window content, from the top left). `positioning`
    /// (an index in its items) puts that item at `origin` instead, for a menu too tall to fit where it would go.
    func show(
        _ menu: AppMenu, in window: NSWindow, at origin: NSPoint, owner: NSView?, positioning: Int? = nil,
        onClose: (() -> Void)? = nil
    ) {
        close()
        guard let host = Self.overlayHost(of: window) else { return }
        self.menu = menu
        lastClosed = menu
        self.owner = owner
        self.onClose = onClose
        menu.onChoose = { [weak self, weak menu] index in
            guard let item = menu?.items[index] else { return }
            self?.close()
            item.action()
        }
        menu.onSystemClose = { [weak self, weak menu] in
            guard let menu, self?.menu === menu, self?.isMoving == false else { return }
            self?.close()
        }
        TooltipController.of(window).scheduler.dismiss()
        let place = place(of: menu, at: origin, positioning: positioning, in: host)
        self.host = host
        self.place = place
        #if DEBUG
            guard tracks else {
                standIn = AppMenuStandIn(menu: menu, host: host, left: place.left, top: place.fittedTop)
                return
            }
        #endif
        track(menu)
    }

    private func place(of menu: AppMenu, at origin: NSPoint, positioning: Int?, in host: NSView) -> MenuPlace {
        let size = menu.size
        let fitted = MenuPlacement.keepInViewport(
            left: origin.x, top: origin.y, width: size.width, height: size.height,
            viewportWidth: host.bounds.width, viewportHeight: host.bounds.height)
        return MenuPlace(
            left: fitted.left, top: positioning == nil ? fitted.top : origin.y, positioning: positioning,
            fittedTop: fitted.top)
    }

    /// The open menu's rows changed its height: it goes to `origin`, still open. The system's menu has no way to move,
    /// so it closes and comes up again there.
    func move(to origin: NSPoint, positioning: Int? = nil) {
        guard let menu, let host else { return }
        let new = place(of: menu, at: origin, positioning: positioning, in: host)
        guard new != place else { return }
        place = new
        #if DEBUG
            guard tracks else {
                standIn?.remove()
                standIn = AppMenuStandIn(menu: menu, host: host, left: new.left, top: new.fittedTop)
                return
            }
        #endif
        // One that isn't up yet comes up at the new place anyway.
        if menu.isTracking {
            isMoving = true
            menu.nsMenu.cancelTracking()
        }
    }

    /// Below `anchor`, from the edge of it that leaves the most room (`placeDropdownMenu`).
    func drop(_ menu: AppMenu, from anchor: NSView, owner: NSView? = nil, onClose: (() -> Void)? = nil) {
        guard let window = anchor.window, let host = Self.overlayHost(of: window) else { return }
        let rect = anchor.convert(anchor.bounds, to: host)
        let top = host.isFlipped ? rect.minY : host.bounds.height - rect.maxY
        let size = menu.size
        let place = MenuPlacement.dropdown(
            anchorLeft: rect.minX, anchorRight: rect.maxX, anchorBottom: top + rect.height, menuWidth: size.width,
            menuHeight: size.height, viewportWidth: host.bounds.width, viewportHeight: host.bounds.height)
        show(menu, in: window, at: NSPoint(x: place.left, y: place.top), owner: owner ?? anchor, onClose: onClose)
    }

    /// Runs the system's menu from the run loop, not from the caller, which may be a block of the main queue (a timer,
    /// an answer that came in): nothing else on the main queue would run until the menu closes.
    private func track(_ menu: AppMenu) {
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.menu === menu, let place = self.place, let host = self.host else { return }
                self.startOptionWatch(menu)
                self.scheduleMark(menu)
                let item = place.positioning.flatMap {
                    menu.nsMenu.items.indices.contains($0) ? menu.nsMenu.items[$0] : nil
                }
                let point = NSPoint(x: place.left, y: host.isFlipped ? place.top : host.bounds.height - place.top)
                menu.trackingBegan()
                _ = menu.nsMenu.popUp(positioning: item, at: point, in: host)
                menu.trackingEnded()
                self.optionTimer?.invalidate()
                self.optionTimer = nil
                if self.isMoving {
                    self.isMoving = false
                    self.track(menu)
                }
            }
        }
    }

    /// Shows the mark in the tracking loop, as soon as the menu is up.
    private func scheduleMark(_ menu: AppMenu) {
        let mark = Timer(timeInterval: 0, repeats: false) { [weak menu] _ in
            MainActor.assumeIsolated { menu?.showMark() }
        }
        RunLoop.main.add(mark, forMode: .common)
    }

    /// A menu that changes with Option: no key events reach the app while the system's menu is open, so the key's state
    /// is read while it is.
    private func startOptionWatch(_ menu: AppMenu) {
        guard menu.itemsForOption != nil else { return }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak menu] _ in
            MainActor.assumeIsolated { menu?.optionChanged(held: NSEvent.modifierFlags.contains(.option)) }
        }
        RunLoop.main.add(timer, forMode: .common)
        optionTimer = timer
    }

    func close() {
        guard let menu else { return }
        self.menu = nil
        owner = nil
        isMoving = false
        if menu.isTracking { menu.nsMenu.cancelTracking() }
        #if DEBUG
            standIn?.remove()
            standIn = nil
        #endif
        let done = onClose
        onClose = nil
        done?()
    }

    /// An event on its way to `window`: true when the open menu took it. The system's menu sees its own events, so only
    /// its stand-in has any to take: Escape closes it, and a press elsewhere closes it and goes on.
    func intercept(_ event: NSEvent, in window: NSWindow) -> Bool {
        #if DEBUG
            guard let standIn, standIn.window === window else { return false }
            switch event.type {
            case .leftMouseDown, .rightMouseDown:
                if standIn.contains(event.locationInWindow) { return false }
                if let owner, owner.bounds.contains(owner.convert(event.locationInWindow, from: nil)) { return false }
                close()
                return false
            case .keyDown where event.keyCode == 53:
                close()
                return true
            default:
                return false
            }
        #else
            return false
        #endif
    }
}
