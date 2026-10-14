// Port of the pane layout of apps/desktop/src/renderer/components/TreePane.tsx (TreePane) around SidebarModel
import AppKit
import FTFileSystem
import FTFoundation

/// The context menu of a sidebar row is the item context menus' to fill (P5-09, B-TREE-141..149); it is asked for with
/// the row clicked.
struct SidebarContextMenuRequest {
    var item: TreePresentationItem
    var subview: SidebarSubview
    var kind: SidebarMenuTarget.Kind
}

/// The sidebar: Favorites, Locations and the folder tree of one tab.
@MainActor
final class SidebarViewController: NSViewController, SidebarListDelegate {
    let model = SidebarModel()

    // MARK: What the window gives

    /// The window's preferences (favorites, layout, density, single-click expand).
    var preferences: () -> AppPreferences = { AppPreferences.defaults() }
    var updatePreferences: ([String: JSONNode]) -> Void = { _ in }
    var directoryService: () -> DirectoryService = { ExplorerServices.current.directoryService }
    /// The folder is opened in a new tab (⌘-click).
    var openInNewTab: (String) -> Void = { _ in }
    /// The keyboard goes to the file list (Tab).
    var focusContent: () -> Void = {}
    /// The sidebar's tree root, selection or sections changed: the tab's state is saved.
    var stateChanged: () -> Void = {}
    /// Told when the selection or the sub-view changed (the menu bar and toolbar follow).
    var selectionChanged: () -> Void = {}
    /// The context menu of a row (nil: none).
    var contextMenuProvider: ((SidebarContextMenuRequest) -> NSMenu?)?
    /// Eject a disk (the Eject button, the row's menu).
    var eject: (String) -> Void = { _ in }
    /// Disks being ejected, whose Eject buttons wait.
    var ejectingPaths: () -> Set<String> = { [] }
    /// Files dragged over a row (P5-08 fills the hook).
    var fileDrops: SidebarFileDrops?

    // MARK: Views

    private let root = SidebarRootView()
    private let titlebar = SidebarPlainView()
    let sections = SidebarListView(subview: .favorites)
    private let foldersTitle = SidebarLabelField()
    private let foldersHeader = SidebarPlainView()
    let tree = SidebarListView(subview: .tree)
    private let pill = SidebarTypeaheadPill()
    private var volumesToken: SidebarVolumes.Token?
    private var themeObservation: AppearanceModel.Observation?
    private var activity: WindowActivity?
    private var density = Density.comfortable
    var isFocused = false
    private var windowActive: Bool { activity?.isActive ?? true }

    // MARK: Scrolling and timing

    private var lastRevealed: TreeItemID?
    private var handToggleTimer: (() -> Void)?
    private var revealSignature = ""
    /// A tab that has just come back keeps the scroll it left.
    var holdsScrollPosition = false
    var clickTimer: (() -> Void)?
    private var loadingTimers: [SidebarModel.ExactKeyBox: () -> Void] = [:]
    private var loadingShown: Set<SidebarModel.ExactKeyBox> = []

    // MARK: Favorites being put in order

    var draggedFavorite: String?
    var dropTarget: (path: String, position: Favorites.DropPosition)?
    /// Rows a drag from another app is over, as P5-08 sets them.
    var dropStates: [String: SidebarDropState] = [:] {
        didSet { refresh() }
    }

    // MARK: Loading

    override func loadView() {
        view = root
        root.controller = self
        root.setAccessibilityIdentifier("sidebar.pane")
        titlebar.setAccessibilityIdentifier("sidebar.titlebar")
        sections.outline.setAccessibilityIdentifier("sidebar.sections.outline")
        sections.setAccessibilityIdentifier("sidebar.sections")
        tree.outline.setAccessibilityIdentifier("sidebar.tree.outline")
        tree.setAccessibilityIdentifier("sidebar.tree")
        foldersHeader.setAccessibilityIdentifier("sidebar.foldersHeader")
        foldersTitle.setAccessibilityIdentifier("sidebar.foldersTitle")
        pill.setAccessibilityIdentifier("sidebar.typeahead")
        foldersHeader.addSubview(foldersTitle)
        for subview in [titlebar, sections, foldersHeader, tree, pill] as [NSView] { root.addSubview(subview) }
        sections.delegate = self
        sections.scroll.gutter = 0
        tree.delegate = self
        tree.fadesTop = true
        pill.isHidden = true

        model.onChange = { [weak self] in self?.refresh() }
        model.onSectionsChanged = { [weak self] in
            guard let self else { return }
            self.syncKeyboardList()
            self.persistSections()
            self.stateChanged()
        }
        model.onHandToggle = { [weak self] in self?.noteHandToggle() }
        model.onFavoritesChanged = { [weak self] favorites in
            guard let self else { return }
            self.updatePreferences(["favorites": .array(favorites.map(Self.json))])
        }
        model.readChildren = { [weak self] path, includeHidden in
            guard let self else { return [] }
            let read = try await self.directoryService().treeChildren(path: path, includeHidden: includeHidden)
            return read.children.map {
                TreePaths.Child(path: $0.path, name: $0.name, isHidden: $0.isHidden, isSymlink: $0.isSymlink)
            }
        }
        applyPreferences()
        volumesToken = SidebarVolumes.shared.observe { [weak self] volumes in self?.model.setVolumes(volumes) }
        themeObservation = AppearanceModel.shared.observe { [weak self] _ in self?.reloadAll() }
        refresh()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        installWindow()
    }

    /// Hooks onto the window: its activity (selections turn gray in the background) and its focus.
    func installWindow() {
        guard let window = view.window, activity == nil else { return }
        let activity = WindowActivity(window: window)
        activity.onChange = { [weak self] _ in
            self?.reloadAll()
            SidebarVolumes.shared.refresh()
        }
        self.activity = activity
        reloadAll()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
    }

    // MARK: Preferences

    /// Reads the window's preferences: the favorites and layout are the app's; the density follows the compact switch.
    func applyPreferences() {
        let prefs = preferences()
        model.homePath = FileManager.default.homeDirectoryForCurrentUser.path
        if !prefs.favoritesInitialized {
            // First launch: the favorites become the defaults, and the section opens.
            let defaults = Favorites.defaults(homePath: model.homePath)
            model.favorites = defaults
            updatePreferences([
                "favorites": .array(defaults.map(Self.json)), "favoritesInitialized": .bool(true),
                "favoritesExpanded": .bool(true),
            ])
            model.setSections(favorites: true, locations: model.locationsExpanded)
        } else {
            model.favorites = prefs.favorites
        }
        model.placement = prefs.favoritesPlacement
        model.singleClickExpand = prefs.singleClickExpandTreeItems
        density = prefs.compactTreeView ? .compact : .comfortable
        refresh()
    }

    private func persistSections() {
        updatePreferences([
            "favoritesExpanded": .bool(model.favoritesExpanded), "locationsExpanded": .bool(model.locationsExpanded),
        ])
    }

    static func json(_ favorite: FavoritePreference) -> JSONNode {
        .object(["path": .string(favorite.path), "icon": .string(favorite.icon.rawValue)])
    }

    // MARK: Drawing the lists

    var layout: SidebarLayout { SidebarLayout(density: density) }

    private var separate: Bool { model.placement == .separate }

    private func state(
        _ item: TreePresentationItem, subview: SidebarSubview, hasDisclosure: Bool
    ) -> SidebarRowState {
        let current = model.currentItemID == item.id
        let selection: SidebarRowState.Selection =
            !current ? .none : (isFocused && windowActive ? .focused : .inactive)
        let key = item.path.map(SidebarModel.ExactKeyBox.init)
        var menuTarget = false
        if let target = model.menuTarget, let path = item.path {
            menuTarget =
                target.path.utf8.elementsEqual(path.utf8) && target.subview == subview
                && target.kind == (item.kind == .favorite || item.kind == .location ? .favorite : .treeFolder)
        }
        return SidebarRowState(
            item: item, subview: subview, selection: selection, menuTarget: menuTarget,
            drop: item.path.flatMap { dropStates[$0] },
            ejecting: item.path.map { ejectingPaths().contains($0) } ?? false,
            dragging: draggedFavorite != nil && item.path == draggedFavorite && item.kind == .favorite,
            dropLine: dropTarget.flatMap { item.kind == .favorite && $0.path == item.path ? $0.position : nil },
            showsLoading: key.map { loadingShown.contains($0) } ?? false, density: density,
            hasDisclosure: hasDisclosure)
    }

    /// The rows of the folder tree (with Favorites and Locations ahead of it when integrated).
    private func treeRows() -> [SidebarListRow] {
        let layout = self.layout
        let presentation = model.treePresentation
        var rows: [SidebarListRow] = [.spacer(id: "top", height: layout.treeListPaddingTop)]
        for item in presentation.visibleItems {
            rows.append(.item(state(item, subview: .tree, hasDisclosure: true)))
        }
        rows.append(.spacer(id: "bottom", height: layout.treeListPaddingBottom))
        return rows
    }

    /// The separate layout's Favorites and Locations sections.
    private func sectionRows() -> [SidebarListRow] {
        var rows: [SidebarListRow] = []
        let favorites = model.favoriteRows
        let locations = model.locationRows
        if !favorites.isEmpty {
            rows.append(
                .header(
                    SidebarHeaderState(
                        section: .favorites, title: "Favorites", expanded: model.favoritesExpanded, first: true,
                        density: density)))
            if model.favoritesExpanded {
                for item in favorites { rows.append(.item(state(item, subview: .favorites, hasDisclosure: false))) }
            }
        }
        if !locations.isEmpty {
            rows.append(
                .header(
                    SidebarHeaderState(
                        section: .locations, title: "Locations", expanded: model.locationsExpanded,
                        first: favorites.isEmpty, density: density)))
            if model.locationsExpanded {
                for item in locations { rows.append(.item(state(item, subview: .favorites, hasDisclosure: false))) }
            }
        }
        return rows
    }

    func refresh() {
        guard isViewLoaded else { return }
        trackLoading()
        let showsSections = separate
        tree.apply(treeRows())
        sections.apply(showsSections ? sectionRows() : [])
        let hadSections = !sections.isHidden
        sections.isHidden = !showsSections || sections.rowCount == 0
        foldersHeader.isHidden = !showsSections
        tree.fadesTop = showsSections
        pill.isHidden = model.typeaheadQuery.isEmpty || !isFocused
        if !pill.isHidden { pill.configure(query: model.typeaheadQuery, theme: SidebarColors.theme(for: view)) }
        if hadSections != sections.isHidden { root.needsLayout = true }
        root.needsLayout = true
        layoutIfNeeded()
        revealSelectionIfNeeded()
        selectionChanged()
    }

    /// Draws every row again (a new theme, the window going to the back).
    func reloadAll() {
        guard isViewLoaded else { return }
        tree.reloadAll()
        sections.reloadAll()
        applyChrome()
    }

    private func layoutIfNeeded() {
        root.layoutSubtreeIfNeeded()
    }

    /// The colors of the parts that are not rows.
    func applyChrome() {
        let theme = SidebarColors.theme(for: view)
        foldersTitle.font = ChromeColors.font(size: layout.headingFontSize, weight: 600)
        foldersTitle.textColor = ChromeColors.color(theme.palette.textSecondary)
        foldersTitle.stringValue = "Folders"
        root.needsLayout = true
    }

    // MARK: Loading lines

    /// "Loading folder…" shows when a read has lasted 400 ms (`useDelayedFlag`).
    private func trackLoading() {
        var loadingNow = Set<SidebarModel.ExactKeyBox>()
        for node in model.nodes.all where node.loading {
            let key = SidebarModel.ExactKeyBox(node.path)
            loadingNow.insert(key)
            if loadingTimers[key] == nil, !loadingShown.contains(key) {
                loadingTimers[key] = model.schedule(SidebarLayout.loadingDelayMilliseconds) { [weak self] in
                    guard let self else { return }
                    self.loadingTimers[key] = nil
                    self.loadingShown.insert(key)
                    self.refresh()
                }
            }
        }
        for key in loadingTimers.keys where !loadingNow.contains(key) {
            loadingTimers[key]?()
            loadingTimers[key] = nil
        }
        loadingShown = loadingShown.intersection(loadingNow)
    }

    // MARK: Scrolling to the selection

    /// A folder or section opened by hand: for a moment the sidebar does not scroll to the selection.
    private func noteHandToggle() {
        handToggleTimer?()
        handToggleTimer = model.schedule(SidebarLayout.handToggleSettleMilliseconds) { [weak self] in
            self?.handToggleTimer = nil
        }
    }

    /// `scrollIntoView({ block: "nearest" })` for the selected row when the selection changes or the rows do.
    private func revealSelectionIfNeeded() {
        let signature = [
            model.placement.rawValue, model.favoritesExpanded ? "f" : "-", model.locationsExpanded ? "l" : "-",
            model.includeHidden ? "h" : "-", model.treePresentation.visibleItemIDs.map(\.rawValue).joined(separator: "\0"),
            model.selected?.rawValue ?? "",
        ].joined(separator: "|")
        guard signature != revealSignature else { return }
        revealSignature = signature
        guard let selected = model.selected else { return }
        if holdsScrollPosition {
            lastRevealed = selected
            return
        }
        if handToggleTimer != nil, lastRevealed == selected { return }
        lastRevealed = selected
        for list in [tree, sections] where !list.isHidden {
            if let index = list.index(ofItem: selected) {
                list.reveal(index)
                return
            }
        }
    }

    // MARK: Which list has the keyboard

    func outline(for subview: SidebarSubview) -> SidebarOutlineView {
        if separate, subview == .favorites, !sections.isHidden { return sections.outline }
        return tree.outline
    }

    /// The keyboard follows the sub-view the keys move in.
    private func syncKeyboardList() {
        guard isFocused, let window = view.window else { return }
        let target = outline(for: model.subview)
        if window.firstResponder !== target { window.makeFirstResponder(target) }
    }

    // MARK: Layout

    /// Lays the parts out: the title bar strip, the sections (at most 60% of the rest), the "Folders" label and the tree.
    fileprivate func layoutParts() {
        let layout = self.layout
        let width = root.bounds.width
        let height = root.bounds.height
        titlebar.frame = NSRect(x: 0, y: 0, width: width, height: layout.titlebarHeight)
        var y = layout.titlebarHeight
        let available = height - y
        if !sections.isHidden {
            let maximum = (available * layout.sectionsMaxHeightShare).rounded(.down)
            let sectionHeight = min(sections.contentHeight, maximum)
            sections.frame = NSRect(x: 0, y: y, width: width, height: sectionHeight)
            y += sectionHeight
        }
        if !foldersHeader.isHidden {
            let font = foldersTitle.font ?? ChromeColors.font(size: layout.headingFontSize, weight: 600)
            let line = SidebarText.lineHeight(font)
            let padding = layout.foldersTitlePadding
            // With a tree that overflows, the original's label box is squeezed to 0.7 pt under its 14 pt of padding
            // (a flex column shrinking it); the text, centered in it, spills over the first rows of the tree.
            let full = padding.top + line + padding.bottom
            let overflows = tree.contentHeight > height - y - full
            let content = overflows ? layout.foldersTitleContentHeight : line
            let headerHeight = padding.top + content + padding.bottom
            foldersHeader.frame = NSRect(x: 0, y: y, width: width, height: headerHeight)
            foldersTitle.frame = NSRect(
                x: padding.left, y: padding.top + (content - line) / 2,
                width: min(SidebarText.width(foldersTitle.stringValue, font: font), max(0, width - padding.left - padding.right)),
                height: line)
            y += headerHeight
        }
        tree.frame = NSRect(x: 0, y: y, width: width, height: max(0, height - y))
        tree.updateFade(height: layout.treeFadeHeight)
        if !pill.isHidden {
            let size = pill.fittingSize(maxWidth: width - 24)
            let region = NSRect(x: 0, y: layout.titlebarHeight, width: width, height: available)
            pill.frame = NSRect(
                x: ((region.width - size.width) / 2).rounded(), y: (region.minY + (region.height - size.height) / 2).rounded(),
                width: size.width, height: size.height)
        }
    }
}

/// The sidebar's top view: it lays its parts out by hand.
final class SidebarRootView: NSView {
    weak var controller: SidebarViewController?

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        MainActor.assumeIsolated { controller?.layoutPartsForRoot() }
    }
}

extension SidebarViewController {
    func layoutPartsForRoot() { layoutParts() }
}

/// What P5-08 fills to take files dragged onto the sidebar's rows (B-TREE-157..162): the one small seam.
struct SidebarFileDrops {
    /// A row (nil: the background) is offered a drag. The answer is what the drop would do.
    var over: (_ row: SidebarRowState?, _ info: any NSDraggingInfo) -> NSDragOperation
    /// Files dropped on a row.
    var drop: (_ row: SidebarRowState, _ info: any NSDraggingInfo) -> Bool
    /// URLs dropped by the debug seam (`AutomationDropTarget`).
    var dropURLs: (_ row: SidebarRowState, _ urls: [URL], _ allowed: NSDragOperation) -> Bool
}

/// The "Jump to" pill (`.pane-typeahead`): the prefix typed in the sidebar.
final class SidebarTypeaheadPill: NSView {
    private let label = NSTextField(labelWithString: "Jump to")
    private let value = NSTextField(labelWithString: "")
    private var fill = NSColor.clear
    private var border = NSColor.clear

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for field in [label, value] {
            field.isBordered = false
            field.drawsBackground = false
            field.lineBreakMode = .byTruncatingTail
            addSubview(field)
        }
        layer?.shadowOpacity = 0.12
        layer?.shadowRadius = 2
        layer?.shadowOffset = CGSize(width: 0, height: -1)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    static let padding = (x: 10.0, y: 6.0)
    static let gap = 8.0

    func configure(query: String, theme: Theme) {
        let size = DesignTokens.typeScale.callout
        label.font = ChromeColors.font(size: size)
        label.textColor = ChromeColors.color(theme.palette.textSecondary)
        value.font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)
        value.textColor = ChromeColors.color(theme.accent.pillText)
        value.stringValue = query
        fill = ChromeColors.color(theme.palette.bgElevated, percent: 92)
        border = ChromeColors.color(theme.accent.border)
        layer?.backgroundColor = fill.cgColor
        layer?.borderColor = border.cgColor
        layer?.borderWidth = 1
        needsLayout = true
    }

    func fittingSize(maxWidth: Double) -> NSSize {
        let lineHeight = SidebarText.lineHeight(label.font ?? .systemFont(ofSize: 12))
        let textWidth = SidebarText.width(label.stringValue, font: label.font ?? .systemFont(ofSize: 12))
        let valueWidth = SidebarText.width(value.stringValue, font: value.font ?? .systemFont(ofSize: 12))
        let width = min(maxWidth, textWidth + Self.gap + valueWidth + 2 * Self.padding.x + 2)
        return NSSize(width: width, height: lineHeight + 2 * Self.padding.y + 2)
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
        let line = SidebarText.lineHeight(label.font ?? .systemFont(ofSize: 12))
        let labelWidth = SidebarText.width(label.stringValue, font: label.font ?? .systemFont(ofSize: 12))
        label.frame = NSRect(x: 1 + Self.padding.x, y: 1 + Self.padding.y, width: labelWidth, height: line)
        value.frame = NSRect(
            x: label.frame.maxX + Self.gap, y: 1 + Self.padding.y,
            width: max(0, bounds.width - label.frame.maxX - Self.gap - Self.padding.x - 1), height: line)
    }
}
