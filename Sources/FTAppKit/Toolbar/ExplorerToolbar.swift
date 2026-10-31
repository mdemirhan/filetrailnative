// Port of the window-toolbar of apps/desktop/src/renderer/components/ExplorerWorkspace.tsx (items, enabled states) with
// HistoryButton.tsx, as the window's system toolbar
import AppKit
import FTFoundation

/// The window's system toolbar, in the unified style Finder uses: a sidebar tracking separator, so the items start
/// over the content column, then one `NSToolbarItem` per item of the user's saved order. The system draws the band
/// (52 points), the Liquid Glass, the » menu, the customizing sheet and the tab bar under the band (D-015, D-016).
///
/// `topToolbarItems` stays the source of the order, so a saved layout, an imported one and Reset to Defaults need no
/// other format: the toolbar follows the preference, and what the user changes in the toolbar goes back into it. The
/// system's autosave is off, and each tab's toolbar has an identifier of its own (toolbars that share one share their
/// items): the preference keeps them all the same.
@MainActor
final class ExplorerToolbar: NSObject, NSToolbarDelegate, NSMenuItemValidation {
    /// The title takes all the room there is: a width no band reaches, at a priority that gives way.
    private static let titleFillWidth = 100_000.0

    let toolbar: NSToolbar
    weak var context: ExplorerWindowContext?
    /// The search field, whichever item holds it.
    let searchField = ToolbarSearchField()
    /// Opens the system's customizing sheet; a windowless test stands in for it.
    var runCustomizationPalette: (NSToolbar) -> Void = { $0.runCustomizationPalette(nil) }

    private(set) var savedItems: [ToolbarItemID] = ToolbarItems.defaultTopItems
    /// The views of the items in the toolbar, kept when the item is made again.
    private var views: [ToolbarItemID: NSView] = [:]
    private var clipboardCount = 0
    private var clipboardCut = false
    /// What the clipboard button says (P5-08).
    private var clipboardSummary: FTFoundation.ClipboardSummary?
    private var observation: ExplorerWindowObservation?
    private var identifiersObservation: NSKeyValueObservation?
    private var sheetObservers: [NSObjectProtocol] = []
    /// The toolbar is being set from the preference, not changed by the user.
    private var applying = false
    private var commitPending = false

    // History buttons: a hold opens the menu, and the click that ends that hold does not step.
    var holdTimer: DispatchWorkItem?
    var openedByHold = false
    /// How a press on the magnifier brings a back window forward. A window that is never shown can't become key, so a
    /// windowless test watches this instead.
    var bringForward: @MainActor (NSWindow) -> Void = { $0.makeKeyAndOrderFront(nil) }

    init(identifier: String) {
        toolbar = NSToolbar(identifier: identifier)
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = false
        if #available(macOS 15, *) {
            toolbar.allowsDisplayModeCustomization = false
            identifiersObservation = toolbar.observe(\.itemIdentifiers) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.toolbarChanged() }
            }
        }
    }

    func attach(_ context: ExplorerWindowContext) {
        self.context = context
        observation = context.observe { [weak self] change in
            switch change {
            case .selection, .focusedPane, .treeRoot, .commands: self?.refreshStates()
            default: self?.reload()
            }
        }
        if let window = context.window {
            WindowEventRouting.add(window, last: true) { [weak self] event in self?.pressSearchOptions(event) ?? false }
            // The sheet comes and goes: the items wait under it, as under any sheet.
            for name in [NSWindow.willBeginSheetNotification, NSWindow.didEndSheetNotification] {
                sheetObservers.append(
                    NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) {
                        [weak self] _ in
                        MainActor.assumeIsolated {
                            self?.applySavedOrder(sheetEnded: name == NSWindow.didEndSheetNotification)
                            self?.refreshStates()
                        }
                    })
            }
        }
        reload()
    }

    // MARK: Identifiers

    /// The system's space is the original's `topSeparator`: it ends one group of items and starts the next.
    static func identifier(_ id: ToolbarItemID) -> NSToolbarItem.Identifier {
        id == .topSeparator ? .space : NSToolbarItem.Identifier("filetrail.toolbar.\(id.rawValue)")
    }

    static func itemID(_ identifier: NSToolbarItem.Identifier) -> ToolbarItemID? {
        if identifier == .space { return .topSeparator }
        let prefix = "filetrail.toolbar."
        guard identifier.rawValue.hasPrefix(prefix) else { return nil }
        return ToolbarItemID(rawValue: String(identifier.rawValue.dropFirst(prefix.count)))
    }

    private static func identifiers(_ items: [ToolbarItemID]) -> [NSToolbarItem.Identifier] {
        [.sidebarTrackingSeparator] + items.map(identifier)
    }

    /// The items a saved order draws, with room for them all: a space that divides nothing isn't one of them
    /// (`selectTopToolbarSlots`). The saved order keeps it, as the original's does.
    private static func row(_ items: [ToolbarItemID]) -> [ToolbarItemID] {
        TopToolbarLayout.select(TopToolbarLayout.slots(items), optionalCount: items.count).map(\.id)
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.identifiers(ToolbarItems.defaultTopItems)
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // The palette's items, then the ones every toolbar holds.
        let required = ToolbarItems.defaultTopItems.filter(ToolbarItems.isRequiredTopItem)
        return Self.identifiers(ToolbarItems.paletteItems(excluding: []) + required)
    }

    func toolbarImmovableItemIdentifiers(_ toolbar: NSToolbar) -> Set<NSToolbarItem.Identifier> {
        [.sidebarTrackingSeparator]
    }

    /// Nothing goes before the sidebar's separator: the items stay over the content column.
    func toolbar(
        _ toolbar: NSToolbar, itemIdentifier: NSToolbarItem.Identifier, canBeInsertedAt index: Int
    ) -> Bool {
        itemIdentifier == .sidebarTrackingSeparator ? index == 0 : index > 0
    }

    // MARK: The order

    /// What the user changed in the toolbar (dragged, added, taken off, the sheet's default set) goes into the
    /// preference, once the toolbar has settled. A required item taken off comes back at the end, as it does when a
    /// saved order lacks it (`sanitizeTopItems`).
    private func toolbarChanged() {
        guard !applying, !commitPending else { return }
        commitPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.commitPending = false
                self.commitToolbarOrder()
            }
        }
    }

    private func commitToolbarOrder() {
        guard !applying, context != nil else { return }
        let held = toolbar.items.compactMap { Self.itemID($0.itemIdentifier) }
        let items = ToolbarItems.sanitizeTopItems(.array(held.map { .string($0.rawValue) }))
        // Against what the saved order draws: a saved idle space the toolbar never held is no change of the user's.
        let changed = Self.row(items) != Self.row(savedItems)
        savedItems = items
        if changed {
            context?.updatePreferences(["topToolbarItems": .array(items.map { .string($0.rawValue) })])
        }
        applySavedOrder()
    }

    func toolbarWillAddItem(_ notification: Notification) {
        toolbarChanged()
    }

    func toolbarDidRemoveItem(_ notification: Notification) {
        toolbarChanged()
    }

    /// The toolbar takes up the saved order, keeping the items it holds already. In the sheet a space stays where the
    /// user put it, with the item meant to go past it still to come; the idle ones go when the sheet ends.
    private func applySavedOrder(sheetEnded: Bool = false) {
        // A sheet that has ended is over, whatever the system's flag says at this moment.
        let wanted = Self.identifiers(isCustomizing && !sheetEnded ? savedItems : Self.row(savedItems))
        guard toolbar.items.map(\.itemIdentifier) != wanted else { return }
        applying = true
        defer { applying = false }
        closeSortMenu()
        if #available(macOS 15, *) {
            toolbar.itemIdentifiers = wanted
        } else {
            for index in toolbar.items.indices.reversed() { toolbar.removeItem(at: index) }
            for (index, identifier) in wanted.enumerated() {
                toolbar.insertItem(withItemIdentifier: identifier, at: index)
            }
        }
    }

    // MARK: State

    var shortcuts: ShortcutDisplay {
        guard let preferences = context?.preferences else { return .defaults }
        return ShortcutDisplay(
            shortcuts: ShortcutCommands.resolve(preferences.shortcutOverrides),
            returnKeyAction: preferences.returnKeyAction)
    }

    var tooltipState: ToolbarTooltipState {
        guard let context else { return ToolbarTooltipState() }
        let panels = context.panels
        let view = context.viewState
        return ToolbarTooltipState(
            foldersFirst: view.foldersFirst, hiddenFilesShown: view.includeHidden,
            folderTreeOpen: panels.folderTreeOpen, infoPanelOpen: panels.propertiesOpen,
            infoRowOpen: panels.detailRowOpen, textEditorName: context.preferences.defaultTextEditor.appName)
    }

    /// Reads the order, the clipboard and every item's state from the window.
    func reload() {
        guard let context else { return }
        savedItems = ToolbarItems.sanitizeTopItems(
            .array(context.preferences.topToolbarItems.map { .string($0.rawValue) }))
        clipboardSummary = ClipboardRules.describe(context.services.clipboard.contents)
        clipboardCount = clipboardSummary?.count ?? 0
        clipboardCut = clipboardSummary?.mode == .cut
        applySavedOrder()
        refreshStates()
    }

    /// Every item's look: on or off, enabled, its tooltip, and what the » menu says for it.
    func refreshStates() {
        guard let context else { return }
        toolbar.allowsUserCustomization = isCustomizing || context.canPerform(.customizeToolbar)
        for item in toolbar.items {
            if let id = Self.itemID(item.itemIdentifier), id != .topSeparator { refresh(item, id) }
        }
    }

    /// The system's customizing sheet is up.
    var isCustomizing: Bool { toolbar.customizationPaletteIsRunning }

    private func refresh(_ item: NSToolbarItem, _ id: ToolbarItemID) {
        guard let context else { return }
        let view = context.viewState
        let panels = context.panels
        if let button = views[id] as? ToolbarButton {
            button.tooltip = Tooltips.toolbarItemTooltip(itemID: id, state: tooltipState, shortcuts: shortcuts)
            switch id {
            case .back: button.isEnabled = context.canGoBack
            case .forward: button.isEnabled = context.canGoForward
            case .up: button.isEnabled = ExplorerTabs.parentDirectoryPath(context.shownFolderPath) != nil
            case .foldersFirst: button.isOn = view.foldersFirst
            case .hidden:
                button.isOn = view.includeHidden
                button.iconName = view.includeHidden ? .hiddenShown : .hidden
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
                    // The title is the label ("notes.md copied", "3 items copied"); the name says how many.
                    button.tooltip = clipboardSummary?.label ?? ""
                    if let summary = clipboardSummary { button.setAccessibilityLabel(summary.accessibilityLabel) }
                }
                // Only while something is copied. The sheet still offers it, so it can be moved.
                if clipboardCount == 0 { button.letKeyboardGo() }
                if #available(macOS 15, *) {
                    item.isHidden = clipboardCount == 0
                } else {
                    button.isHidden = clipboardCount == 0
                }
            default:
                if let command = ToolbarItems.definition(id).commandType {
                    button.isEnabled = context.canPerform(command)
                }
            }
        } else if let switcher = views[id] as? ToolbarViewSwitch {
            // Search results show in a view of their own (`searchViewMode`).
            switcher.selected = context.searchRootPath != nil ? view.searchViewMode : view.viewMode
            switcher.isEnabled = context.canPerform(.viewAsIcons)
            switcher.setTooltips(shortcuts)
        } else if let title = views[id] as? ToolbarTitleView {
            title.field.stringValue = Self.title(of: context)
            title.field.toolTip = context.shownFolderPath
        } else if id == .search {
            searchField.isEnabled = !isCustomizing
            searchField.takeClearButton()
        }
        if id != .search { item.menuFormRepresentation = overflowEntry(id) }
    }

    /// `ExplorerTabs.folderDisplayName`: "Macintosh HD" for `/`; while searching, "Searching “…”" with the folder the
    /// search runs from (`toolbarTitle`).
    static func title(of context: ExplorerWindowContext) -> String {
        if let root = context.searchRootPath {
            return "Searching “\(ExplorerTabs.folderDisplayName(root))”"
        }
        return ExplorerTabs.folderDisplayName(context.shownFolderPath)
    }

    static func sortLabel(_ sortBy: SortByPreference) -> String {
        switch sortBy {
        case .size: "Size"
        case .modified: "Date Modified"
        case .kind: "Kind"
        case .name: "Name"
        }
    }

    // MARK: Looking at the items

    /// The item in the toolbar for `id`.
    func item(_ id: ToolbarItemID) -> NSToolbarItem? {
        toolbar.items.first { $0.itemIdentifier == Self.identifier(id) }
    }

    /// The button of `id`, while the toolbar holds it.
    func button(_ id: ToolbarItemID) -> ToolbarButton? {
        item(id) == nil ? nil : views[id] as? ToolbarButton
    }

    var viewSwitch: ToolbarViewSwitch? { item(.view) == nil ? nil : views[.view] as? ToolbarViewSwitch }
    var titleView: ToolbarTitleView? { views[.title] as? ToolbarTitleView }
    var clipboardButton: ToolbarClipboardButton? { views[.clipboard] as? ToolbarClipboardButton }
    var searchItem: NSSearchToolbarItem? { item(.search) as? NSSearchToolbarItem }

    /// The keys of the items on the toolbar, in order: the clipboard button only while it shows.
    var rowKeys: [String] {
        toolbar.items.compactMap { item in
            guard let id = Self.itemID(item.itemIdentifier) else { return nil }
            if id == .clipboard, clipboardCount == 0 { return nil }
            return id.rawValue
        }
    }

    /// Whether `location` (window coordinates) is on something in the band that takes presses: any control, the system's
    /// » button and a folded search's magnifier as well as the items' own. Not the title, which drags the window as the
    /// band's empty room does.
    func hasPressableItem(at location: NSPoint) -> Bool {
        guard let band = context?.window?.standardWindowButton(.closeButton)?.superview else { return false }
        return Self.hasControl(in: band, at: location)
    }

    private static func hasControl(in view: NSView, at location: NSPoint) -> Bool {
        if view.isHidden || view is ToolbarTitleView { return false }
        if view is NSControl, view.convert(view.bounds, to: nil).contains(location) { return true }
        return view.subviews.contains { hasControl(in: $0, at: location) }
    }

    // MARK: Search

    /// A press on the magnifier is the options button's. It has to be taken before the window sends it on: the button is
    /// the view under the mouse, but the system's search field has a gesture recognizer that holds the press back from
    /// the views in it and only starts editing. Whatever is over the magnifier, a dialog's scrim or a folded item, keeps it,
    /// and a sheet or a modal window keeps the press, as AppKit does. Taken here, it skips the step of AppKit that brings
    /// a window forward on a press, so that happens here: typing after the menu goes to this window's field.
    private func pressSearchOptions(_ event: NSEvent) -> Bool {
        let button = searchField.optionsButton
        guard event.type == .leftMouseDown, item(.search) != nil, searchField.isEnabled,
            let window = context?.window, window.attachedSheet == nil,
            NSApp.modalWindow == nil || NSApp.modalWindow === window,
            let frame = window.contentView?.superview,
            frame.hitTest(frame.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow)
                === button
        else { return false }
        if !window.isKeyWindow, window.canBecomeKey { bringForward(window) }
        button.mouseDown(with: event)
        return true
    }

    /// `focusFileSearch`: the field takes the keyboard, the system's item opening up first if it is folded.
    func beginSearch() {
        searchItem?.beginSearchInteraction()
        if !searchField.isActive { searchField.window?.makeFirstResponder(searchField) }
    }

    /// The field lets go of the keyboard: the system's item folds again if it has no room.
    func endSearch() {
        searchItem?.endSearchInteraction()
    }

    // MARK: Customizing

    func beginCustomizing() {
        guard !isCustomizing else { return }
        runCustomizationPalette(toolbar)
    }

    // MARK: Items

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard let id = Self.itemID(itemIdentifier) else { return nil }
        let definition = ToolbarItems.definition(id)
        let item: NSToolbarItem
        if id == .search {
            let search = NSSearchToolbarItem(itemIdentifier: itemIdentifier)
            if flag {
                search.searchField = searchField
                // A field while there is room at all, as the original's (`searchWidth`, `searchMinWidth`): the title
                // gives way first.
                searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: DesignTokens.toolbar.searchMinWidth)
                    .isActive = true
                let preferred = searchField.widthAnchor.constraint(equalToConstant: DesignTokens.toolbar.searchWidth)
                preferred.priority = .defaultHigh
                preferred.isActive = true
                // The ✕ keeps the keyboard in the field (TabSearch).
                search.resignsFirstResponderWithCancel = false
            }
            search.preferredWidthForSearchField = DesignTokens.toolbar.searchWidth
            item = search
        } else {
            item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.view = flag ? liveView(id) : makeView(id, wired: false)
            // The title is plain text in the band, not on the glass the system puts behind the other items.
            if id == .title { item.isBordered = false }
        }
        item.label = definition.label
        item.paletteLabel = definition.label
        item.autovalidates = false
        // The removable items go to the » menu first; the required ones last.
        item.visibilityPriority = definition.topRequired ? .high : .standard
        if flag, context != nil { refresh(item, id) }
        return item
    }

    private func liveView(_ id: ToolbarItemID) -> NSView {
        if let view = views[id] { return view }
        let view = makeView(id, wired: true)
        views[id] = view
        return view
    }

    /// An item's view; `wired` is false for the copy the system shows in its sheet, which does nothing.
    private func makeView(_ id: ToolbarItemID, wired: Bool) -> NSView {
        let definition = ToolbarItems.definition(id)
        switch id {
        case .title:
            let title = ToolbarTitleView()
            title.translatesAutoresizingMaskIntoConstraints = false
            title.heightAnchor.constraint(equalToConstant: ToolbarTitleView.height).isActive = true
            let minWidth = DesignTokens.toolbar.titleMinWidth
            if wired {
                title.widthAnchor.constraint(greaterThanOrEqualToConstant: minWidth).isActive = true
                // As wide as the band lets it be, below every priority the toolbar lays its items out with.
                let fill = title.widthAnchor.constraint(equalToConstant: Self.titleFillWidth)
                fill.priority = NSLayoutConstraint.Priority(1)
                fill.isActive = true
            } else {
                title.widthAnchor.constraint(equalToConstant: minWidth).isActive = true
                title.field.stringValue = definition.label
            }
            return title
        case .view:
            let switcher = ToolbarViewSwitch()
            if wired {
                switcher.onChoose = { [weak self] mode in
                    self?.context?.perform(Self.viewCommand(mode))
                    // A choice that did nothing puts the segment back.
                    self?.refreshStates()
                }
            }
            return switcher
        case .clipboard:
            let button = ToolbarClipboardButton()
            if wired {
                button.onClick = { [weak self, weak button] in
                    guard let button, let tab = self?.context as? MainWindowController else { return }
                    tab.clipboardUI.toggle(from: button)
                }
            } else {
                button.setAccessibilityIdentifier("")
            }
            return button
        default:
            break
        }
        let identifier = wired ? "toolbar.\(id.rawValue)" : ""
        let button = ToolbarButton(icon: definition.icon, label: Self.accessibilityLabel(id), identifier: identifier)
        if wired { wire(button, id) }
        return button
    }

    private func wire(_ button: ToolbarButton, _ id: ToolbarItemID) {
        switch id {
        case .back, .forward:
            let back = id == .back
            button.onPress = { [weak self, weak button] in
                guard let self, let button else { return }
                self.openedByHold = false
                self.holdTimer?.cancel()
                let timer = DispatchWorkItem { [weak self, weak button] in
                    guard let self, let button else { return }
                    MainActor.assumeIsolated {
                        self.holdTimer = nil
                        self.openedByHold = true
                        self.showHistoryMenu(back: back, from: button)
                    }
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
        case .up: button.onClick = { [weak self] in self?.context?.goToParentFolder() }
        case .foldersFirst: button.onClick = { [weak self] in self?.context?.perform(.toggleFoldersFirst) }
        case .hidden: button.onClick = { [weak self] in self?.context?.perform(.toggleHiddenFiles) }
        case .folderTree: button.onClick = { [weak self] in self?.context?.perform(.toggleFolderTree) }
        case .infoPanel: button.onClick = { [weak self] in self?.context?.perform(.toggleInfoPanel) }
        case .infoRow: button.onClick = { [weak self] in self?.context?.perform(.toggleInfoRow) }
        default:
            if let command = ToolbarItems.definition(id).commandType {
                button.onClick = { [weak self] in self?.context?.perform(command) }
            }
        }
    }

    static func viewCommand(_ mode: ExplorerViewMode) -> RendererCommand {
        switch mode {
        case .icons: .viewAsIcons
        case .details: .viewAsDetails
        case .list: .viewAsList
        }
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

    // MARK: The » menu's entries

    /// What an entry of the » menu runs, and whether it can.
    final class OverflowAction: NSObject {
        let enabled: Bool
        let run: () -> Void

        init(enabled: Bool, run: @escaping () -> Void) {
            self.enabled = enabled
            self.run = run
        }
    }

    func overflowItem(
        _ title: String, checked: Bool = false, enabled: Bool = true, run: @escaping () -> Void
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(runOverflowItem(_:)), keyEquivalent: "")
        item.target = self
        item.state = checked ? .on : .off
        item.representedObject = OverflowAction(enabled: enabled, run: run)
        return item
    }

    @objc private func runOverflowItem(_ sender: NSMenuItem) {
        (sender.representedObject as? OverflowAction)?.run()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        // A dialog's scrim covers the » button: nothing in its menu runs, whatever got the menu open.
        if let window = context?.window, DialogScrim.front(in: window) != nil { return false }
        return (menuItem.representedObject as? OverflowAction)?.enabled ?? true
    }
}
