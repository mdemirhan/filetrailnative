// The window that lists every customized folder (View ▸ Folder View ▸ Manage Folder Views…)
import AppKit
import FTFileSystem
import FTFoundation

/// Folder Views: every folder customized on its own, as a tree, a customized folder inside another listed
/// under it. A row has the folder's icon, its name and where it is, and on the right what it keeps, whether it applies
/// to subfolders, and whether its folder is still there. Remove forgets the selected folders' customizations (⌫ too),
/// leaving those of the folders inside them; Remove with Subfolders forgets those inside each selected folder too, and
/// nothing outside the selected folders. Remove All… forgets every one after asking, and Open (Return, or a
/// double-click) opens the folder in the window that asked. Esc closes the window.
@MainActor
final class FolderViewsWindowController: NSWindowController, NSWindowDelegate, NSOutlineViewDataSource,
    NSOutlineViewDelegate
{
    /// The one window, opened from any explorer window.
    private static var shared: FolderViewsWindowController?

    private let views: SharedFolderViews
    /// Opens a folder in the explorer window that asked last.
    private var open: (String) -> Void
    private let table = FolderViewsTable()
    private let scroll = NSScrollView()
    private let empty = NSStackView()
    private let remove = NSButton(title: "Remove", target: nil, action: nil)
    private let removeTree = NSButton(title: "Remove with Subfolders", target: nil, action: nil)
    private let removeAll = NSButton(title: "Remove All\u{2026}", target: nil, action: nil)
    private let openButton = NSButton(title: "Open", target: nil, action: nil)
    /// The folders at the top of the tree, each with the customized folders inside it.
    private var roots: [FolderViewNode] = []
    private var observer: (any NSObjectProtocol)?

    /// Shows the window, front, listing `views`; a folder opened from it opens through `open`.
    static func show(_ views: SharedFolderViews, open: @escaping (String) -> Void) {
        let controller = shared?.views === views ? shared! : FolderViewsWindowController(views: views, open: open)
        controller.open = open
        shared = controller
        controller.reload()
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.window?.makeFirstResponder(controller.table)
    }

    init(views: SharedFolderViews, open: @escaping (String) -> Void) {
        self.views = views
        self.open = open
        let window = FolderViewsPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 440),
            styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Folder Views"
        window.minSize = NSSize(width: 520, height: 300)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("FolderCustomizations")
        super.init(window: window)
        window.delegate = self
        build()
        observer = NotificationCenter.default.addObserver(
            forName: SharedFolderViews.didChange, object: views, queue: nil
        ) { [weak self] _ in MainActor.assumeIsolated { self?.reload() } }
        if window.frame.origin == .zero { window.center() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    isolated deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    // MARK: Building

    private func build() {
        guard let content = window?.contentView else { return }
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("folder"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.outlineTableColumn = column
        table.indentationPerLevel = 16
        table.autoresizesOutlineColumn = false
        table.headerView = nil
        table.style = .inset
        table.rowHeight = 30
        table.allowsMultipleSelection = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openSelected)
        table.onDelete = { [weak self] in self?.removeSelected() }
        table.onReturn = { [weak self] in self?.openSelected() }
        table.setAccessibilityIdentifier("folderViews.table")
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false

        let symbol = NSImageView(
            image: NSImage(systemSymbolName: "folder.badge.gearshape", accessibilityDescription: nil) ?? NSImage())
        symbol.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 40, weight: .light)
        symbol.contentTintColor = .tertiaryLabelColor
        let emptyTitle = NSTextField(labelWithString: "No Folder Views")
        emptyTitle.font = .systemFont(ofSize: 15, weight: .semibold)
        emptyTitle.textColor = .secondaryLabelColor
        let emptyText = NSTextField(
            wrappingLabelWithString:
                "To give the folder you\u{2019}re in a view of its own, choose View \u{203A} Folder View \u{203A} Remember View for This Folder."
        )
        emptyText.alignment = .center
        emptyText.textColor = .secondaryLabelColor
        emptyText.preferredMaxLayoutWidth = 320
        for view in [symbol, emptyTitle, emptyText] { empty.addArrangedSubview(view) }
        empty.orientation = .vertical
        empty.alignment = .centerX
        empty.spacing = 8
        empty.setCustomSpacing(12, after: symbol)

        remove.toolTip = "Removes the selected folders\u{2019} views. Folders inside them keep theirs."
        remove.setAccessibilityIdentifier("folderViews.remove")
        removeTree.toolTip =
            "Removes the selected folders\u{2019} views, and those of every folder inside them."
        removeTree.setAccessibilityIdentifier("folderViews.removeWithSubfolders")
        for (button, action) in [
            (remove, #selector(removeSelected)), (removeTree, #selector(removeSelectedWithSubfolders)),
            (removeAll, #selector(askToRemoveAll)), (openButton, #selector(openSelected)),
        ] {
            button.target = self
            button.action = action
            button.bezelStyle = .push
        }
        removeAll.setAccessibilityIdentifier("folderViews.removeAll")
        openButton.setAccessibilityIdentifier("folderViews.show")
        let bar = NSStackView(views: [remove, removeTree, NSView(), removeAll, openButton])
        bar.orientation = .horizontal
        bar.spacing = 8

        for view in [scroll, empty, bar] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bar.topAnchor, constant: -10),
            empty.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            bar.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
    }

    /// The rows again from the folders as they are now, keeping the selection where its folders still are.
    func reload() {
        let selected = Set(selectedNodes.map { DiskPath($0.view.path) })
        roots = FolderViewNode.tree(views.views.all)
        table.reloadData()
        table.expandItem(nil, expandChildren: true)
        let rows = (0..<table.numberOfRows).filter { row in
            (table.item(atRow: row) as? FolderViewNode).map { selected.contains(DiskPath($0.view.path)) } == true
        }
        table.selectRowIndexes(IndexSet(rows), byExtendingSelection: false)
        empty.isHidden = !roots.isEmpty
        scroll.isHidden = roots.isEmpty
        syncButtons()
    }

    private var selectedNodes: [FolderViewNode] {
        table.selectedRowIndexes.compactMap { table.item(atRow: $0) as? FolderViewNode }
    }

    private func syncButtons() {
        let selected = selectedNodes
        remove.isEnabled = !selected.isEmpty
        removeTree.isEnabled = !Self.insideAny(selected.map(\.view.path), of: views.views).isEmpty
        removeAll.isEnabled = !roots.isEmpty
        openButton.isEnabled = selected.count == 1 && FolderIdentity.isFolder(selected[0].view.path)
    }

    // MARK: Outline

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? FolderViewNode)?.children.count ?? roots.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? FolderViewNode)?.children[index] ?? roots[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? FolderViewNode)?.children.isEmpty == false
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FolderViewNode else { return nil }
        return FolderViewRowView(Self.summary(node.view))
    }

    func outlineViewSelectionDidChange(_ notification: Notification) { syncButtons() }

    /// What a row shows of a folder's customization.
    struct Summary: Equatable {
        var name: String
        var path: String
        var tags: [String]
        var subfolders: Bool
        /// Why the folder isn't there; nil when it is.
        var missing: String?
    }

    static func summary(_ view: FolderView) -> Summary {
        let missing =
            FolderIdentity.isFolder(view.path)
            ? nil : (view.path.hasPrefix("/Volumes/") ? "Disk Not Connected" : "Not Found")
        let kept = view.keeps.kept.map(\.label)
        return Summary(
            name: FolderViewText.name(view.path),
            path: shortPath(view.path),
            tags: kept.isEmpty ? ["Nothing Kept"] : kept, subfolders: view.subfolders, missing: missing)
    }

    /// A path under the home folder starts with ~.
    static func shortPath(_ path: String) -> String {
        let home = DiskPath.home
        if DiskPath(path) == home { return "~" }
        guard DiskPath(path).isInside(home), home.string.utf8.count > 1 else { return path }
        return "~" + path[path.utf8.index(path.utf8.startIndex, offsetBy: home.string.utf8.count)...]
    }

    // MARK: Actions

    @objc private func removeSelected() {
        let paths = selectedNodes.map(\.view.path)
        guard !paths.isEmpty else { return }
        views.update(from: nil) { views in
            for path in paths { views.remove(path) }
        }
    }

    /// The selected folders' customizations, and those of the folders inside each of them, at any depth: never one
    /// of a folder above, beside or outside a selected folder.
    @objc private func removeSelectedWithSubfolders() {
        let selected = selectedNodes.map(\.view.path)
        guard !selected.isEmpty else { return }
        let paths = selected + Self.insideAny(selected, of: views.views)
        views.update(from: nil) { views in
            for path in paths { views.remove(path) }
        }
    }

    /// The customized folders inside any of `paths` (not those folders themselves).
    static func insideAny(_ paths: [String], of views: FolderViews) -> [String] {
        let inside = Set(paths.flatMap { views.inside($0).map { DiskPath($0.path) } })
        return inside.subtracting(paths.map { DiskPath($0) }).sorted().map(\.string)
    }

    @objc private func askToRemoveAll() {
        let count = views.views.all.count
        guard let window, count > 0 else { return }
        let alert = NSAlert()
        alert.messageText =
            count == 1 ? "Remove the folder view?" : "Remove all \(FormatLocale.count(count)) folder views?"
        alert.informativeText = "These folders will look as the window shows any folder. This can\u{2019}t be undone."
        alert.addButton(withTitle: "Remove All")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .alertFirstButtonReturn else { return }
                self?.views.update(from: nil) { $0 = FolderViews() }
            }
        }
    }

    @objc private func openSelected() {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard let node = table.item(atRow: row) as? FolderViewNode, FolderIdentity.isFolder(node.view.path) else {
            return
        }
        open(node.view.path)
    }

    /// Esc closes the window, as it does a panel.
    @objc func cancel(_ sender: Any?) { window?.performClose(sender) }
    override func cancelOperation(_ sender: Any?) { window?.performClose(sender) }

    #if DEBUG
        /// The window's rows, top to bottom, and its buttons, for tests.
        var shownRows: [FolderView] {
            (0..<table.numberOfRows).compactMap { (table.item(atRow: $0) as? FolderViewNode)?.view }
        }
        /// Where each row is in the tree: 0 at the top.
        var shownLevels: [Int] { (0..<table.numberOfRows).map { table.level(forRow: $0) } }
        var tableView: NSTableView { table }
        var removeButton: NSButton { remove }
        var removeWithSubfoldersButton: NSButton { removeTree }
        func pressRemoveWithSubfolders() { removeSelectedWithSubfolders() }
        var showButton: NSButton { openButton }
        func pressRemove() { removeSelected() }
        func pressShow() { openSelected() }
    #endif
}

/// A customized folder in the tree, with the customized folders inside it.
final class FolderViewNode {
    let view: FolderView
    /// The customized folder it's listed under; nil at the top.
    let parent: String?
    var children: [FolderViewNode] = []

    init(_ view: FolderView, parent: String?) {
        self.view = view
        self.parent = parent
    }

    /// `views` as a tree: each under the nearest folder above it that is customized too, each level by name. A
    /// folder is one by its path's bytes, as its view is kept: two whose paths differ only in how an accent is
    /// encoded are two rows.
    static func tree(_ views: [FolderView]) -> [FolderViewNode] {
        let paths = Set(views.map { DiskPath($0.path) })
        func parent(of path: DiskPath) -> String? {
            var current = path.parent
            while current != path {
                if paths.contains(current) { return current.string }
                if current.string.utf8.count <= 1 { return nil }
                current = current.parent
            }
            return nil
        }
        var nodes: [DiskPath: FolderViewNode] = [:]
        for view in views {
            let path = DiskPath(view.path)
            nodes[path] = FolderViewNode(view, parent: parent(of: path))
        }
        var roots: [FolderViewNode] = []
        for node in nodes.values {
            if let above = node.parent, let parent = nodes[DiskPath(above)] {
                parent.children.append(node)
            } else {
                roots.append(node)
            }
        }
        // Inside a folder, by where each is from it; at the top, the home folder's first.
        let home = DiskPath.home
        func key(_ node: FolderViewNode) -> (Int, String) {
            let path = node.view.path
            guard let parent = node.parent else {
                return (DiskPath(path).isAtOrInside(home) ? 0 : 1, path)
            }
            // What follows the folder above and its slash, counted in bytes as the two paths are matched.
            let rest = path.utf8.index(path.utf8.startIndex, offsetBy: parent == "/" ? 1 : parent.utf8.count + 1)
            return (0, String(path[rest...]))
        }
        func sorted(_ nodes: [FolderViewNode]) -> [FolderViewNode] {
            for node in nodes { node.children = sorted(node.children) }
            return nodes.sorted {
                let (a, b) = (key($0), key($1))
                if a.0 != b.0 { return a.0 < b.0 }
                let order = a.1.localizedStandardCompare(b.1)
                // Two names that read the same go by their bytes, so the rows have one order.
                return order == .orderedSame ? DiskPath(a.1) < DiskPath(b.1) : order == .orderedAscending
            }
        }
        return sorted(roots)
    }
}

/// The window of customized folders: Esc closes it, wherever the keyboard is in it.
final class FolderViewsPanel: NSWindow {
    override func cancelOperation(_ sender: Any?) { performClose(sender) }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { performClose(nil) } else { super.keyDown(with: event) }
    }
}

/// The list of customized folders: ⌫ removes the selected ones and Return opens the one selected.
final class FolderViewsTable: NSOutlineView {
    var onDelete: () -> Void = {}
    var onReturn: () -> Void = {}

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 51, 117: onDelete()
        case 36, 76: onReturn()
        case 53: window?.performClose(nil)
        default: super.keyDown(with: event)
        }
    }
}

/// One customized folder on one line: its icon and its path, and on the right what it keeps. On a selected row's
/// accent color, the path and tags turn white, as a selected row's text does.
final class FolderViewRowView: NSTableCellView {
    private var path = NSTextField()
    private var tags: [FolderViewTag] = []
    private var missing = false

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            let selected = backgroundStyle == .emphasized
            path.textColor =
                selected ? .alternateSelectedControlTextColor : missing ? .secondaryLabelColor : .labelColor
            for tag in tags { tag.selected = selected }
        }
    }

    init(_ summary: FolderViewsWindowController.Summary) {
        super.init(frame: .zero)
        let icon = NSImageView(
            image: summary.missing == nil
                ? NSWorkspace.shared.icon(forFile: NSString(string: summary.path).expandingTildeInPath)
                : NSWorkspace.shared.icon(for: .folder))
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.alphaValue = summary.missing == nil ? 1 : 0.45
        missing = summary.missing != nil
        path = NSTextField(labelWithString: summary.path)
        path.font = .systemFont(ofSize: NSFont.systemFontSize)
        path.textColor = missing ? .secondaryLabelColor : .labelColor
        path.lineBreakMode = .byTruncatingMiddle
        path.toolTip = summary.path
        path.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tags = summary.tags.map { FolderViewTag($0, tint: nil) }
        if summary.subfolders { tags.append(FolderViewTag("Subfolders", tint: .controlAccentColor)) }
        if let missing = summary.missing { tags.insert(FolderViewTag(missing, tint: .systemOrange), at: 0) }
        let tagRow = NSStackView(views: tags)
        tagRow.orientation = .horizontal
        tagRow.spacing = 4
        tagRow.setContentCompressionResistancePriority(.required, for: .horizontal)
        for view in [icon, path, tagRow] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 20),
            path.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            path.centerYAnchor.constraint(equalTo: centerYAnchor),
            tagRow.leadingAnchor.constraint(greaterThanOrEqualTo: path.trailingAnchor, constant: 12),
            tagRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            tagRow.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityLabel(summary.name)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

/// A small rounded label of what a folder keeps: grey, or in its tint; white on a selected row.
final class FolderViewTag: NSView {
    private let tint: NSColor?
    private let field: NSTextField
    var selected = false {
        didSet {
            field.textColor = selected ? .alternateSelectedControlTextColor : tint ?? .secondaryLabelColor
            needsDisplay = true
        }
    }

    init(_ text: String, tint: NSColor?) {
        self.tint = tint
        field = NSTextField(labelWithString: text)
        super.init(frame: .zero)
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize - 1, weight: .medium)
        field.textColor = tint ?? .secondaryLabelColor
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            field.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            field.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = 5
        let fill =
            selected
            ? NSColor.alternateSelectedControlTextColor.withAlphaComponent(0.22)
            : tint?.withAlphaComponent(0.14) ?? NSColor.quaternaryLabelColor
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = fill.cgColor }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
