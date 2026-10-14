// Port of apps/desktop/src/renderer/components/PathbarFolderMenu.tsx with .pathbar-folder-menu (styles.css:2106-2125) and
// the .toolbar-menu rules
import AppKit
import FTFoundation

/// The menu's panel: the same look as the toolbar's menus, its rows in a scroll view so a long list stays within 440 pt.
final class PathFolderMenuView: NSView {
    static let padding = AppMenuView.padding
    private let scroll = NSScrollView()
    private let document = InfoFlippedView()
    private(set) var rows: [AppMenuRow] = []
    /// The row of each folder (the notes have none), in order.
    private(set) var folderRows: [AppMenuRow] = []
    var activeIndex: Int? {
        didSet { for (index, row) in folderRows.enumerated() { row.isActive = index == activeIndex } }
    }
    var onChoose: (Int) -> Void = { _ in }
    private var checkedRow: AppMenuRow?
    private var markers: [(row: AppMenuRow, marker: RowValueBox)] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.menu)
        setAccessibilityIdentifier("pathBarMenu")
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        scroll.documentView = document
        addSubview(scroll)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    /// Notes ("Loading…", "3 more folders above") and folders; `checkedPath` is the ticked folder.
    func build(topNote: String?, folders: [PathbarFolder], checkedPath: String, bottomNote: String?, note: String?) {
        for row in rows { row.removeFromSuperview() }
        rows = []
        folderRows = []
        checkedRow = nil
        markers = []
        func noteRow(_ text: String) {
            let row = AppMenuRow(item: AppMenuItem(title: text, enabled: false), keyboard: true)
            row.setAccessibilityIdentifier("pathBarMenu.note")
            rows.append(row)
            document.addSubview(row)
        }
        if let note { noteRow(note) }
        if let topNote { noteRow(topNote) }
        for (index, folder) in folders.enumerated() {
            let checked = folder.path == checkedPath
            let item = AppMenuItem(title: folder.name, checked: checked ? true : nil, tooltip: folder.path)
            let row = AppMenuRow(item: item, keyboard: true)
            row.setAccessibilityIdentifier("pathBarMenu.item")
            if checked {
                // The tick carries no text; this marker names the ticked row for the capture.
                let marker = RowValueBox()
                marker.setAccessibilityIdentifier("pathBarMenu.item.checked")
                marker.sample.stringValue = folder.name
                row.addSubview(marker)
                markers.append((row, marker))
            }
            row.toolTip = folder.path
            row.onHover = { [weak self] in self?.activeIndex = index }
            row.onClick = { [weak self] in self?.onChoose(index) }
            if checked { checkedRow = row }
            rows.append(row)
            folderRows.append(row)
            document.addSubview(row)
        }
        if let bottomNote { noteRow(bottomNote) }
        needsLayout = true
    }

    /// The panel's size: as wide as its widest row (200 to 360), at most 440 tall.
    func fittingSize(maxWidth: Double, maxHeight: Double) -> NSSize {
        var width = InfoMetrics.folderMenuMinWidth
        for row in rows { width = max(width, row.naturalWidth + 2 * Self.padding + 1) }
        width = min(width, min(InfoMetrics.folderMenuMaxWidth, maxWidth))
        let height = 2 * Self.padding + 1 + Double(rows.count) * AppMenuView.rowHeight
        return NSSize(width: width, height: min(height, min(InfoMetrics.folderMenuMaxHeight, maxHeight)))
    }

    override func layout() {
        super.layout()
        scroll.frame = bounds.insetBy(dx: 0.5, dy: 0.5)
        let rowWidth = bounds.width - 2 * Self.padding - 1
        var y = Self.padding
        for row in rows {
            row.frame = NSRect(x: Self.padding, y: y, width: rowWidth, height: AppMenuView.rowHeight)
            y += AppMenuView.rowHeight
        }
        document.frame = NSRect(x: 0, y: 0, width: scroll.bounds.width, height: y + Self.padding)
        for (row, marker) in markers {
            row.layoutSubtreeIfNeeded()
            marker.frame = row.checkMark?.frame ?? .zero
        }
    }

    /// The ticked folder in view, in the middle.
    func scrollToChecked() {
        layoutSubtreeIfNeeded()
        guard let row = checkedRow else { return }
        let visible = scroll.contentView.bounds.height
        let target = max(0, min(document.frame.height - visible, row.frame.midY - visible / 2))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: target))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    func scrollToActive() {
        guard let index = activeIndex, folderRows.indices.contains(index) else { return }
        document.scrollToVisible(folderRows[index].frame)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyLook()
    }

    private func applyLook() {
        let palette = infoTheme.palette
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

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyLook()
    }
}

final class InfoFlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// The folder menu of one separator, while it is open: it asks for the folders, opens above the button and takes the keyboard.
@MainActor
final class PathFolderMenuController {
    private var menu: PathFolderMenuView?
    private weak var button: PathSeparatorView?
    private var requestID = 0
    private var folders: [PathbarFolder]?
    private var failed = false
    private var activePath = ""
    private var limited = PathbarFolderMenuModel.Limited(shown: [], hiddenBefore: 0, hiddenAfter: 0)
    private var interceptor: Int?
    private weak var window: NSWindow?
    private var observers: [any NSObjectProtocol] = []
    private var loadingTimer: DispatchWorkItem?
    private var showsLoading = false
    var onNavigate: (String) -> Void = { _ in }
    var onChange: (Bool) -> Void = { _ in }

    var isOpen: Bool { button != nil }

    func isOpen(from view: PathSeparatorView) -> Bool { button === view }

    func toggle(
        from separator: PathSeparatorView, parent: String, active: String,
        request: @escaping @MainActor (String) async throws -> [PathbarFolder]
    ) {
        if button === separator {
            close()
            return
        }
        close()
        guard let window = separator.window else { return }
        AppMenuPresenter.shared.close()
        self.window = window
        button = separator
        activePath = active
        folders = nil
        failed = false
        showsLoading = false
        separator.setMenuOpen(true)
        onChange(true)
        requestID += 1
        let id = requestID
        // A moment's wait shows nothing; a slow folder shows "Loading…".
        let timer = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.requestID == id, self.folders == nil, !self.failed else { return }
                self.showsLoading = true
                self.present()
            }
        }
        loadingTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + InfoMetrics.folderMenuLoadingDelay, execute: timer)
        Task { @MainActor [weak self] in
            let result = await Result { try await request(parent) }
            guard let self, self.requestID == id, self.button != nil else { return }
            switch result {
            case .success(let list):
                self.folders = list
                self.failed = false
            case .failure:
                self.folders = []
                self.failed = true
            }
            self.present()
        }
        install(window)
    }

    private func present() {
        guard let button, let window, let host = window.contentView else { return }
        let fresh = menu == nil
        let view = menu ?? PathFolderMenuView()
        menu = view
        var note: String?
        var shown: [PathbarFolder] = []
        var before: String?
        var after: String?
        if let folders {
            if failed {
                note = "Can’t Read This Folder"
            } else if folders.isEmpty {
                note = "No Folders"
            } else {
                limited = PathbarFolderMenuModel.limit(folders, activePath: activePath)
                shown = limited.shown
                if limited.hiddenBefore > 0 {
                    before = PathbarFolderMenuModel.hiddenLabel(limited.hiddenBefore) + " above"
                }
                if limited.hiddenAfter > 0 {
                    after = PathbarFolderMenuModel.hiddenLabel(limited.hiddenAfter) + " below"
                }
            }
        } else {
            note = "Loading…"
        }
        view.build(topNote: before, folders: shown, checkedPath: activePath, bottomNote: after, note: note)
        view.onChoose = { [weak self] index in self?.choose(index) }
        let size = view.fittingSize(maxWidth: host.bounds.width - 16, maxHeight: host.bounds.height - 16)
        // Above the button: its bottom edge 6 pt over the button, its left edge 6 pt left of it.
        let rect = button.convert(button.bounds, to: host)
        let buttonTop = host.isFlipped ? rect.minY : host.bounds.height - rect.maxY
        let place = MenuPlacement.keepInViewport(
            left: rect.minX - InfoMetrics.folderMenuGap, top: buttonTop - InfoMetrics.folderMenuGap - size.height,
            width: size.width, height: size.height, viewportWidth: host.bounds.width, viewportHeight: host.bounds.height
        )
        let y = host.isFlipped ? place.top : host.bounds.height - place.top - size.height
        view.frame = NSRect(x: place.left, y: y, width: size.width, height: size.height)
        if view.superview !== host { host.addSubview(view) }
        view.layoutSubtreeIfNeeded()
        if folders != nil, !failed {
            let index = shown.firstIndex { $0.path == activePath } ?? 0
            view.activeIndex = shown.isEmpty ? nil : index
            view.scrollToChecked()
        }
        if fresh { TooltipController.of(window).scheduler.dismiss() }
    }

    private func choose(_ index: Int) {
        guard limited.shown.indices.contains(index) else { return }
        let folder = limited.shown[index]
        close()
        if folder.path != activePath { onNavigate(folder.path) }
    }

    func close() {
        requestID += 1
        loadingTimer?.cancel()
        loadingTimer = nil
        menu?.removeFromSuperview()
        menu = nil
        if let interceptor, let window { WindowEventRouting.remove(interceptor, from: window) }
        interceptor = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        let was = button
        button = nil
        was?.setMenuOpen(false)
        if was != nil { onChange(false) }
    }

    private func install(_ window: NSWindow) {
        interceptor = WindowEventRouting.add(window) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) ?? false }
        }
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification, object: window, queue: .main
            ) {
                [weak self] _ in MainActor.assumeIsolated { self?.close() }
            })
        if NSApp.isActive {
            observers.append(
                NotificationCenter.default.addObserver(
                    forName: NSWindow.didResignKeyNotification, object: window, queue: .main
                ) {
                    [weak self] _ in MainActor.assumeIsolated { self?.close() }
                })
        }
    }

    /// While the menu is open the keyboard belongs to it: the keys are taken here, before the file list's shortcuts.
    private func handle(_ event: NSEvent) -> Bool {
        guard let menu else {
            return false
        }
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            let point = menu.convert(event.locationInWindow, from: nil)
            if menu.bounds.contains(point) { return false }
            if let button, button.bounds.contains(button.convert(event.locationInWindow, from: nil)) { return false }
            close()
            return false
        case .keyDown:
            if !event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
                close()
                return false
            }
            let count = limited.shown.count
            let current = menu.activeIndex ?? 0
            switch Int(event.keyCode) {
            case 53, 48: close()
            case 125, 126:
                guard count > 0 else { return true }
                menu.activeIndex = max(0, min(count - 1, current + (event.keyCode == 125 ? 1 : -1)))
                menu.scrollToActive()
            case 115, 119:
                guard count > 0 else { return true }
                menu.activeIndex = event.keyCode == 115 ? 0 : count - 1
                menu.scrollToActive()
            case 36, 76, 49:
                if count > 0, menu.activeIndex != nil { choose(current) }
            default:
                if let characters = event.characters, characters.count == 1, count > 0,
                    let next = PathbarFolderMenuModel.jump(letter: characters, from: current, in: limited.shown)
                {
                    menu.activeIndex = next
                    menu.scrollToActive()
                }
            }
            return true
        default:
            return false
        }
    }
}
