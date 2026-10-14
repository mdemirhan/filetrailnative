// Port of the toolbar of apps/desktop/src/renderer/components/ExplorerWorkspace.tsx (window-toolbar: items, fitting,
// overflow, menus, right-click) with HistoryButton.tsx, ThemeMenuButton.tsx and ToolbarOverflowButton.tsx
import AppKit
import FTFoundation

/// The toolbar over the content and the Info panel: the items in their saved order, buttons side by side on round
/// capsules, the title taking the room the others leave; the removable items nearest the end go to the » menu when
/// the window is too narrow. It is 52 tall with a line under it, and drags the window from its empty room.
final class ToolbarView: NSView {
    weak var context: ExplorerWindowContext?
    /// Starts customizing the toolbar (View Options, the right-click menu).
    var onCustomize: () -> Void = {}
    /// With the folder tree hidden the toolbar reaches the window's corner, under the traffic lights.
    var underTrafficLights = false {
        didSet { needsLayout = true }
    }
    /// While the toolbar is customized: what is drawn in the row.
    weak var customizer: ToolbarCustomizer? {
        didSet { reload() }
    }
    var customizing: Bool { customizer != nil }

    private(set) var savedItems: [ToolbarItemID] = ToolbarItems.defaultTopItems
    private(set) var slotViews: [String: ToolbarSlotView] = [:]
    private let overflowButton = ToolbarButton(icon: .overflow, label: "More Toolbar Items", identifier: "toolbar.overflow")
    private let overflowSlot: ToolbarSlotView
    /// The keys of the items in the row now, in order.
    private(set) var rowKeys: [String] = []
    private(set) var overflowSlots: [TopToolbarSlot] = []
    private(set) var visibleOptionalCount = Int.max
    private var clipboardCount = 0
    private var clipboardCut = false
    private var observation: ExplorerWindowObservation?

    // History buttons: a hold opens the menu, and the click that ends that hold does not step.
    private var holdTimer: DispatchWorkItem?
    private var openedByHold = false

    override init(frame: NSRect) {
        overflowSlot = ToolbarSlotView(
            slot: TopToolbarSlot(id: .viewOptions, key: TopToolbarRow.overflowKey), content: overflowButton)
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.toolbar)
        setAccessibilityIdentifier("toolbar")
        overflowButton.tooltip = "More Toolbar Items"
        overflowButton.onClick = { [weak self] in self?.toggleOverflowMenu() }
        addSubview(overflowSlot)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override var mouseDownCanMoveWindow: Bool { true }

    func attach(_ context: ExplorerWindowContext) {
        self.context = context
        observation = context.observe { [weak self] change in
            switch change {
            case .selection, .focusedPane, .treeRoot: self?.refreshStates()
            default: self?.reload()
            }
        }
        reload()
    }

    // MARK: State

    var metrics: ToolbarLayout { WindowMetrics.standard.toolbar }

    private var shortcuts: ShortcutDisplay {
        guard let preferences = context?.preferences else { return .defaults }
        return ShortcutDisplay(
            shortcuts: ShortcutCommands.resolve(preferences.shortcutOverrides),
            returnKeyAction: preferences.returnKeyAction)
    }

    private var tooltipState: ToolbarTooltipState {
        guard let context else { return ToolbarTooltipState() }
        let panels = context.panels
        let view = context.viewState
        return ToolbarTooltipState(
            foldersFirst: view.foldersFirst, hiddenFilesShown: view.includeHidden,
            folderTreeOpen: panels.folderTreeOpen, infoPanelOpen: panels.propertiesOpen,
            infoRowOpen: panels.detailRowOpen, textEditorName: context.preferences.defaultTextEditor.appName)
    }

    /// The items in their saved order; the clipboard button only while something is copied, or while customizing.
    var topSlots: [TopToolbarSlot] {
        TopToolbarLayout.slots(savedItems).filter { $0.id != .clipboard || clipboardCount > 0 || customizing }
    }

    /// Reads the order, the clipboard and every button's state from the window.
    func reload() {
        if let context {
            savedItems = ToolbarItems.sanitizeTopItems(
                .array(context.preferences.topToolbarItems.map { .string($0.rawValue) }))
            if case .ready(let mode, let paths, _, _) = context.services.clipboard.contents {
                clipboardCount = paths.count
                clipboardCut = mode == .cut
            } else {
                clipboardCount = 0
            }
        }
        let wanted = customizer?.editSlots ?? topSlots
        for slot in wanted where slotViews[slot.key] == nil {
            let view = ToolbarSlotView(slot: slot, content: makeItem(slot))
            slotViews[slot.key] = view
            addSubview(view, positioned: .below, relativeTo: overflowSlot)
        }
        refreshStates()
        needsLayout = true
    }

    /// Every item's look: on or off, enabled, its tooltip.
    func refreshStates() {
        guard let context else { return }
        let state = tooltipState
        let shortcuts = shortcuts
        let view = context.viewState
        let panels = context.panels
        let inert = customizing
        for (_, slotView) in slotViews {
            let id = slotView.slot.id
            if let button = slotView.content as? ToolbarButton {
                button.isInert = inert
                button.tooltip = Tooltips.toolbarItemTooltip(itemID: id, state: state, shortcuts: shortcuts)
                switch id {
                case .back: button.isEnabled = context.canGoBack
                case .forward: button.isEnabled = context.canGoForward
                case .foldersFirst: button.isOn = view.foldersFirst
                case .hidden:
                    button.isOn = view.includeHidden
                    button.icon.name = view.includeHidden ? .hiddenShown : .hidden
                case .folderTree: button.isOn = panels.folderTreeOpen
                case .infoPanel: button.isOn = panels.propertiesOpen
                case .infoRow: button.isOn = panels.detailRowOpen
                case .sort:
                    button.isEnabled = context.canPerform(.sortByName)
                    button.tooltip =
                        "Sort By: \(Self.sortLabel(view.sortBy)), \(view.sortDirection == .asc ? "Ascending" : "Descending")"
                case .viewOptions: button.tooltip = "View Options"
                case .theme:
                    let theme = context.preferences.theme
                    let label = AppPreferenceLimits.themeOptions.first { $0.value == theme }?.label ?? theme.rawValue
                    button.tooltip = "Theme: \(label)"
                case .clipboard:
                    if let clipboard = button as? ToolbarClipboardButton {
                        clipboard.set(count: clipboardCount, cut: clipboardCut)
                        button.tooltip = clipboardCount == 0 ? "" : "Clipboard"
                    }
                default:
                    if let command = ToolbarItems.definition(id).commandType {
                        button.isEnabled = context.canPerform(command)
                    }
                }
            } else if let switcher = slotView.content as? ToolbarViewSwitch {
                switcher.selected = view.viewMode
                switcher.isEnabled = context.canPerform(.viewAsIcons)
                switcher.setTooltips(shortcuts)
                for segment in switcher.segments { segment.isInert = inert }
            } else if let title = slotView.content as? ToolbarTitleView {
                title.field.stringValue = Self.title(of: context)
                title.field.toolTip = context.currentFolder.path
                title.isInert = inert
            } else if let separator = slotView.content as? ToolbarSeparatorView {
                separator.customizing = inert
            } else if let search = slotView.content as? ToolbarSearchField {
                search.isEnabled = !inert
            }
        }
        overflowButton.isInert = inert
    }

    /// `ExplorerTabs.folderDisplayName`: "Macintosh HD" for `/`.
    static func title(of context: ExplorerWindowContext) -> String {
        ExplorerTabs.folderDisplayName(context.currentFolder.path)
    }

    static func sortLabel(_ sortBy: SortByPreference) -> String {
        switch sortBy {
        case .size: "Size"
        case .modified: "Date Modified"
        case .kind: "Kind"
        case .name: "Name"
        }
    }

    // MARK: Items

    private func makeItem(_ slot: TopToolbarSlot) -> NSView {
        let id = slot.id
        let definition = ToolbarItems.definition(id)
        switch id {
        case .topSeparator:
            return ToolbarSeparatorView()
        case .title:
            let title = ToolbarTitleView()
            title.onRightClick = { [weak self] event in self?.showCustomizeMenu(event) }
            return title
        case .view:
            let switcher = ToolbarViewSwitch()
            switcher.onChoose = { [weak self] mode in
                switch mode {
                case .icons: self?.context?.perform(.viewAsIcons)
                case .details: self?.context?.perform(.viewAsDetails)
                case .list: self?.context?.perform(.viewAsList)
                }
            }
            return switcher
        case .search:
            return ToolbarSearchField()
        case .clipboard:
            return ToolbarClipboardButton()
        default:
            break
        }
        let label = Self.accessibilityLabel(id)
        let button = ToolbarButton(icon: definition.icon, label: label, identifier: "toolbar.\(id.rawValue)")
        switch id {
        case .back, .forward:
            let back = id == .back
            button.onPress = { [weak self, weak button] in
                guard let self, let button else { return }
                self.openedByHold = false
                self.holdTimer?.cancel()
                let timer = DispatchWorkItem { [weak self, weak button] in
                    guard let self, let button else { return }
                    self.holdTimer = nil
                    self.openedByHold = true
                    self.showHistoryMenu(back: back, from: button)
                }
                self.holdTimer = timer
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.historyHoldSeconds, execute: timer)
            }
            button.onRelease = { [weak self] _ in self?.cancelHold() }
            button.onClick = { [weak self, weak button] in
                guard let self, let button else { return }
                if self.openedByHold {
                    self.openedByHold = false
                    return
                }
                if AppMenuPresenter.shared.isOpen(from: button) {
                    AppMenuPresenter.shared.close()
                    return
                }
                self.context?.perform(back ? .goBack : .goForward)
            }
            button.onRightClick = { [weak self, weak button] in
                guard let self, let button else { return }
                self.cancelHold()
                self.showHistoryMenu(back: back, from: button)
            }
        case .sort:
            button.onClick = { [weak self, weak button] in
                guard let self, let button else { return }
                self.toggleMenu(from: button) { self.sortMenu(anchor: button) }
            }
        case .viewOptions:
            button.onClick = { [weak self, weak button] in
                guard let self, let button else { return }
                self.toggleMenu(from: button) { self.viewOptionsMenu(anchor: button) }
            }
        case .theme:
            button.onClick = { [weak self, weak button] in
                guard let self, let button else { return }
                self.toggleMenu(from: button) { self.themeMenu(anchor: button) }
            }
        case .foldersFirst: button.onClick = { [weak self] in self?.context?.perform(.toggleFoldersFirst) }
        case .hidden: button.onClick = { [weak self] in self?.context?.perform(.toggleHiddenFiles) }
        case .folderTree: button.onClick = { [weak self] in self?.context?.perform(.toggleFolderTree) }
        case .infoPanel: button.onClick = { [weak self] in self?.context?.perform(.toggleInfoPanel) }
        case .infoRow: button.onClick = { [weak self] in self?.context?.perform(.toggleInfoRow) }
        default:
            if let command = definition.commandType {
                button.onClick = { [weak self] in self?.context?.perform(command) }
            }
        }
        return button
    }

    /// The buttons' `aria-label`s (`ExplorerWorkspace.tsx`), which the capture names them by.
    static func accessibilityLabel(_ id: ToolbarItemID) -> String {
        switch id {
        case .back: "Back"
        case .forward: "Forward"
        case .up: "Enclosing Folder"
        case .sort: "Sort By"
        case .viewOptions: "View Options"
        case .foldersFirst: "Folders First"
        case .hidden: "Hidden Files"
        case .folderTree: "Folder Tree"
        case .infoPanel: "Info Panel"
        case .infoRow: "Info Row"
        case .theme: "Choose theme"
        default: ToolbarItems.definition(id).label
        }
    }

    // MARK: Layout

    /// How wide an item is when it is not the title or the search field.
    func intrinsicWidth(_ slot: TopToolbarSlot) -> Double {
        switch slot.id {
        case .topSeparator: return customizing ? 10 : 0
        case .view: return ToolbarViewSwitch.width
        case .clipboard:
            return (slotViews[slot.key]?.content as? ToolbarClipboardButton)?.naturalWidth ?? metrics.buttonWidth
        default: return metrics.buttonWidth
        }
    }

    private func height(of slot: TopToolbarSlot) -> Double {
        switch slot.id {
        case .title: ToolbarTitleView.height
        case .topSeparator: customizing ? 22 : 0
        default: metrics.controlHeight
        }
    }

    /// The row's leading edge: past the traffic lights with the tree hidden.
    var rowOrigin: Double {
        underTrafficLights ? WindowMetrics.standard.explorer.toolbarInsetWithoutTree : metrics.paddingLeading
    }

    var rowWidth: Double { (bounds.width - rowOrigin - metrics.paddingTrailing).rounded(.down) }

    /// The widths the fitting counts with, by key.
    func measuredWidths(_ slots: [TopToolbarSlot]) -> [String: Double] {
        var widths: [String: Double] = [:]
        for slot in slots where slot.id != .title && slot.id != .search {
            widths[slot.key] = intrinsicWidth(slot).rounded(.up)
        }
        return widths
    }

    /// How many removable items the toolbar has room for (`resolveVisibleOptionalCount`).
    func fittingCount() -> Int {
        let slots = topSlots
        return TopToolbarLayout.visibleOptionalCount(
            slots: slots, widths: measuredWidths(slots), availableWidth: rowWidth, layout: metrics)
    }

    override func layout() {
        super.layout()
        let all = topSlots
        visibleOptionalCount = fittingCount()
        let rowSlots: [TopToolbarSlot]
        if let customizer {
            rowSlots = customizer.editSlots
            overflowSlots = []
        } else {
            rowSlots = TopToolbarLayout.select(all, optionalCount: visibleOptionalCount)
            let visible = Set(rowSlots.map(\.key))
            overflowSlots = all.filter {
                !visible.contains($0.key) && $0.id != .topSeparator && !ToolbarItems.isRequiredTopItem($0.id)
            }
        }
        for slot in rowSlots where slotViews[slot.key] == nil {
            let view = ToolbarSlotView(slot: slot, content: makeItem(slot))
            slotViews[slot.key] = view
            addSubview(view, positioned: .below, relativeTo: overflowSlot)
            refreshStates()
        }
        let capsules = TopToolbarLayout.capsules(rowSlots) {
            self.customizing || $0.id != .clipboard || self.clipboardCount > 0
        }
        let placed = TopToolbarRow.place(
            rowSlots, widths: measuredWidths(rowSlots), capsules: capsules, overflow: !overflowSlots.isEmpty,
            rowWidth: rowWidth, titleMinWidth: customizing ? 40 : metrics.titleMinWidth, layout: metrics)
        let band = bounds.height - 1
        let shown = Set(rowSlots.map(\.key))
        let animate = customizer?.animatesNextLayout == true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animate ? DesignTokens.motion.base / 1000 : 0
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
            for (index, slot) in rowSlots.enumerated() {
                guard let view = slotViews[slot.key], let place = placed.places[slot.key] else { continue }
                view.isHidden = false
                view.edges = capsules[slot.key]
                let height = height(of: slot)
                let frame = NSRect(x: rowOrigin + place.x, y: (band - height) / 2, width: place.width, height: height)
                if animate, view.frame.width > 0, view.frame != frame {
                    view.animator().frame = frame
                } else {
                    view.frame = frame
                }
                view.faint = customizer?.overflowKeys.contains(slot.key) ?? false
                view.placeholder = customizer?.placeholderIndex == index
                // A separator has nothing on screen to compare outside customizing.
                view.setAccessibilityIdentifier(
                    slot.id == .topSeparator && !customizing ? "" : view.edges != nil ? "toolbar.capsuleItem" : "toolbar.slot")
            }
        }
        customizer?.animatesNextLayout = false
        for (key, view) in slotViews where !shown.contains(key) { view.isHidden = true }
        if let place = placed.places[TopToolbarRow.overflowKey] {
            overflowSlot.isHidden = false
            overflowSlot.edges = ToolbarCapsuleEdges(start: true, end: true)
            overflowSlot.frame = NSRect(
                x: rowOrigin + place.x, y: (band - metrics.controlHeight) / 2, width: place.width,
                height: metrics.controlHeight)
        } else {
            overflowSlot.isHidden = true
        }
        rowKeys = rowSlots.map(\.key)
        needsDisplay = true
        customizer?.toolbarDidLayout()
    }

    /// The frame of each item in the row, in the toolbar's coordinates, by key.
    func rowFrames() -> [(key: String, frame: NSRect)] {
        rowKeys.compactMap { key in slotViews[key].map { (key, $0.frame) } }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let palette = ChromeColors.palette(for: self)
        ChromeColors.color(palette.bgBase).setFill()
        bounds.fill()
        ChromeColors.color(palette.border).setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        // The capsules behind the buttons: from `capsulePadding` before the first to as far after the last.
        let fill = ChromeColors.color(palette.toolbarToggleBg)
        fill.setFill()
        var start: NSRect?
        let views = rowKeys.compactMap { slotViews[$0] } + (overflowSlot.isHidden ? [] : [overflowSlot])
        for view in views {
            guard let edges = view.edges else { continue }
            let frame = view.layer?.presentation()?.frame ?? view.frame
            if edges.start { start = frame }
            if edges.end, let first = start {
                let rect = NSRect(
                    x: first.minX - metrics.capsulePadding, y: frame.minY,
                    width: frame.maxX - first.minX + 2 * metrics.capsulePadding, height: frame.height)
                NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
                start = nil
            }
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        for view in slotViews.values { view.content.needsDisplay = true }
    }

    // MARK: The window's drag region and right-click

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            window?.performZoom(nil)
            return
        }
        window?.performDrag(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        if customizing { return }
        showCustomizeMenu(event)
    }

    /// The one-item menu a right-click on the toolbar's empty room or its title offers.
    func showCustomizeMenu(_ event: NSEvent) {
        guard !customizing, let window, let host = window.contentView else { return }
        let point = host.convert(event.locationInWindow, from: nil)
        let menu = AppMenuView(
            items: [AppMenuItem(title: "Customize Toolbar…", checked: false, action: { [weak self] in self?.onCustomize() })],
            style: .standard, identifier: "toolbarMenu", rowIdentifier: "toolbarMenu.item")
        AppMenuPresenter.shared.show(menu, in: window, at: point, owner: nil)
    }

    // MARK: Menus

    static let historyHoldSeconds = 0.35

    private func cancelHold() {
        holdTimer?.cancel()
        holdTimer = nil
    }

    private func toggleMenu(from button: ToolbarButton, make: () -> Void) {
        if AppMenuPresenter.shared.isOpen(from: button) {
            AppMenuPresenter.shared.close()
            return
        }
        make()
    }

    private func present(_ menu: AppMenuView, from button: ToolbarButton, at origin: NSPoint? = nil) {
        button.menuOpen = true
        let close = { [weak button] () -> Void in button?.menuOpen = false }
        if let origin, let window {
            AppMenuPresenter.shared.show(menu, in: window, at: origin, owner: button, onClose: close)
        } else {
            AppMenuPresenter.shared.drop(menu, from: button, onClose: close)
        }
    }

    /// The anchor's frame in the window's content, from the top left.
    private func frameInContent(_ view: NSView) -> NSRect? {
        guard let host = window?.contentView else { return nil }
        let rect = view.convert(view.bounds, to: host)
        return host.isFlipped ? rect : NSRect(x: rect.minX, y: host.bounds.height - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Back's or Forward's menu: the folders that way, nearest first, under the button's left edge.
    func showHistoryMenu(back: Bool, from button: ToolbarButton) {
        guard let context, button.isEnabled else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let entries =
            back
            ? HistoryMenu.backEntries(historyPaths: context.historyPaths, historyIndex: context.historyIndex, homePath: home)
            : HistoryMenu.forwardEntries(
                historyPaths: context.historyPaths, historyIndex: context.historyIndex, homePath: home)
        guard !entries.isEmpty, let rect = frameInContent(button), let host = window?.contentView else { return }
        let items = entries.map { entry in
            AppMenuItem(
                title: entry.label, detail: entry.detail, tooltip: entry.path,
                action: { [weak self] in self?.context?.goToHistoryIndex(entry.index) })
        }
        let menu = AppMenuView(
            items: items, style: .keyboard, identifier: "historyMenu", rowIdentifier: "historyMenu.item",
            maxWidth: min(420, host.bounds.width - 16))
        present(menu, from: button, at: NSPoint(x: rect.minX, y: rect.maxY + MenuPlacement.dropGap))
    }

    private func sortMenu(anchor: ToolbarButton) {
        guard let context, let rect = frameInContent(anchor), let host = window?.contentView else { return }
        let view = context.viewState
        var items = SortByPreference.menuOrder.map { value in
            AppMenuItem(
                title: Self.sortLabel(value), checked: view.sortBy == value,
                action: { [weak self] in
                    if value != view.sortBy { self?.context?.perform(Self.sortCommand(value)) }
                })
        }
        items.append(.separator)
        for direction in [SortDirectionPreference.asc, .desc] {
            items.append(
                AppMenuItem(
                    title: direction == .asc ? "Ascending" : "Descending", checked: view.sortDirection == direction,
                    action: { [weak self] in
                        if direction != view.sortDirection { self?.context?.perform(Self.sortCommand(view.sortBy)) }
                    }))
        }
        let width = 200.0
        let menu = AppMenuView(
            items: items, style: .standard, identifier: "toolbarMenu", rowIdentifier: "toolbarMenu.item",
            minWidth: width)
        // 8 below the button, its left edge kept 12 inside the window.
        let left = max(12, min(rect.minX, host.bounds.width - width - 12))
        present(menu, from: anchor, at: NSPoint(x: left, y: rect.maxY + 8))
    }

    static func sortCommand(_ value: SortByPreference) -> RendererCommand {
        switch value {
        case .name: .sortByName
        case .kind: .sortByKind
        case .modified: .sortByModified
        case .size: .sortBySize
        }
    }

    private func viewOptionsMenu(anchor: ToolbarButton) {
        guard let context else { return }
        let view = context.viewState
        let panels = context.panels
        let shortcuts = shortcuts
        func toggle(_ title: String, _ shortcut: ShortcutCommandID, _ on: Bool, _ command: RendererCommand)
            -> AppMenuItem
        {
            AppMenuItem(
                title: title, shortcut: shortcuts.label(shortcut), checked: on,
                action: { [weak self] in self?.context?.perform(command) })
        }
        let items: [AppMenuItem] = [
            toggle("Folders First", .toggleFoldersFirst, view.foldersFirst, .toggleFoldersFirst),
            toggle("Hidden Files", .toggleHiddenFiles, view.includeHidden, .toggleHiddenFiles),
            .separator,
            toggle("Info Panel", .toggleInfoPanel, panels.propertiesOpen, .toggleInfoPanel),
            toggle("Info Row", .toggleInfoRow, panels.detailRowOpen, .toggleInfoRow),
            .separator,
            AppMenuItem(
                title: "Customize Toolbar…", shortcut: shortcuts.label(.customizeToolbar),
                action: { [weak self] in self?.onCustomize() }),
        ]
        present(
            AppMenuView(items: items, style: .standard, identifier: "toolbarMenu", rowIdentifier: "toolbarMenu.item"),
            from: anchor)
    }

    private func themeMenu(anchor: ToolbarButton) {
        guard let context else { return }
        let theme = context.preferences.theme
        let items = AppPreferenceLimits.themeOptions.map { option in
            AppMenuItem(
                title: option.label, checked: theme == option.value,
                action: { [weak self] in self?.context?.updatePreferences(["theme": .string(option.value.rawValue)]) })
        }
        present(
            AppMenuView(items: items, style: .standard, identifier: "toolbarMenu", rowIdentifier: "toolbarMenu.item"),
            from: anchor)
    }

    private func toggleOverflowMenu() {
        toggleMenu(from: overflowButton) { self.overflowMenu() }
    }

    /// The items there is no room for, one group each, worded as in the menu bar (`getOverflowEntries`).
    private func overflowMenu() {
        guard let context else { return }
        let view = context.viewState
        let panels = context.panels
        let state = tooltipState
        var items: [AppMenuItem] = []
        func run(_ command: RendererCommand) -> () -> Void { { [weak self] in self?.context?.perform(command) } }
        for (index, slot) in overflowSlots.enumerated() {
            if index > 0 { items.append(.separator) }
            switch slot.id {
            case .back:
                items.append(AppMenuItem(title: "Back", enabled: context.canGoBack, action: run(.goBack)))
            case .forward:
                items.append(AppMenuItem(title: "Forward", enabled: context.canGoForward, action: run(.goForward)))
            case .up:
                items.append(
                    AppMenuItem(
                        title: "Enclosing Folder", enabled: context.canPerform(.goEnclosingFolder),
                        action: run(.goEnclosingFolder)))
            case .view:
                for mode in ExplorerViewMode.menuOrder {
                    let command: RendererCommand =
                        mode == .icons ? .viewAsIcons : mode == .details ? .viewAsDetails : .viewAsList
                    items.append(
                        AppMenuItem(title: "as \(mode.menuName)", checked: view.viewMode == mode, action: run(command)))
                }
            case .sort:
                for value in SortByPreference.menuOrder {
                    items.append(
                        AppMenuItem(
                            title: "Sort by \(Self.sortLabel(value))", checked: view.sortBy == value,
                            action: { [weak self] in
                                if value != view.sortBy { self?.context?.perform(Self.sortCommand(value)) }
                            }))
                }
            case .foldersFirst:
                items.append(AppMenuItem(title: "Folders First", checked: view.foldersFirst, action: run(.toggleFoldersFirst)))
            case .hidden:
                items.append(AppMenuItem(title: "Hidden Files", checked: view.includeHidden, action: run(.toggleHiddenFiles)))
            case .folderTree:
                items.append(AppMenuItem(title: "Folder Tree", checked: panels.folderTreeOpen, action: run(.toggleFolderTree)))
            case .infoPanel:
                items.append(AppMenuItem(title: "Info Panel", checked: panels.propertiesOpen, action: run(.toggleInfoPanel)))
            case .infoRow:
                items.append(AppMenuItem(title: "Info Row", checked: panels.detailRowOpen, action: run(.toggleInfoRow)))
            case .theme:
                let theme = context.preferences.theme
                for option in AppPreferenceLimits.themeOptions {
                    items.append(
                        AppMenuItem(
                            title: option.label, checked: theme == option.value,
                            action: { [weak self] in
                                self?.context?.updatePreferences(["theme": .string(option.value.rawValue)])
                            }))
                }
            default:
                guard let command = ToolbarItems.definition(slot.id).commandType else { continue }
                items.append(
                    AppMenuItem(
                        title: Tooltips.toolbarItemLabel(itemID: slot.id, state: state),
                        enabled: context.canPerform(command), action: run(command)))
            }
        }
        present(
            AppMenuView(items: items, style: .standard, identifier: "toolbarMenu", rowIdentifier: "toolbarMenu.item"),
            from: overflowButton)
    }
}
