import AppKit

/// Finder-style sidebar: Favorites and Locations in a source list.
final class SidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    final class Node {
        let title: String
        let url: URL?
        let symbol: String?
        let children: [Node]

        init(title: String, url: URL? = nil, symbol: String? = nil, children: [Node] = []) {
            self.title = title
            self.url = url
            self.symbol = symbol
            self.children = children
        }
    }

    var onSelect: ((URL) -> Void)?

    private let outline = NSOutlineView()
    private var sections: [Node] = []
    private var currentFolder: URL?
    private var isSelectingInCode = false

    override func loadView() {
        let column = NSTableColumn(identifier: .init("place"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.floatsGroupRows = false
        outline.dataSource = self
        outline.delegate = self

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        view = scroll

        let center = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification,
            NSWorkspace.didRenameVolumeNotification,
        ] {
            center.addObserver(self, selector: #selector(volumesChanged(_:)), name: name, object: nil)
        }
        reload()
    }

    func select(_ folder: URL) {
        currentFolder = folder
        let path = folder.comparablePath
        let row = (0..<outline.numberOfRows).first { row in
            (outline.item(atRow: row) as? Node)?.url?.comparablePath == path
        }
        isSelectingInCode = true
        if let row {
            outline.selectRowIndexes([row], byExtendingSelection: false)
        } else {
            outline.deselectAll(nil)
        }
        isSelectingInCode = false
    }

    @objc private func volumesChanged(_ notification: Notification) {
        reload()
    }

    private func reload() {
        sections = [
            Node(title: "Favorites", children: Self.favorites()),
            Node(title: "Locations", children: Self.locations()),
        ]
        outline.reloadData()
        outline.expandItem(nil, expandChildren: true)
        if let currentFolder { select(currentFolder) }
    }

    private static func favorites() -> [Node] {
        let fm = FileManager.default
        let places: [(FileManager.SearchPathDirectory, FileManager.SearchPathDomainMask, String)] = [
            (.applicationDirectory, .localDomainMask, "square.grid.2x2"),
            (.desktopDirectory, .userDomainMask, "menubar.dock.rectangle"),
            (.documentDirectory, .userDomainMask, "doc"),
            (.downloadsDirectory, .userDomainMask, "arrow.down.circle"),
        ]
        return places.compactMap { directory, domain, symbol in
            guard let url = fm.urls(for: directory, in: domain).first else { return nil }
            return Node(title: fm.displayName(atPath: url.path), url: url, symbol: symbol)
        }
    }

    private static func locations() -> [Node] {
        let fm = FileManager.default
        var nodes = [Node(title: NSUserName(), url: fm.homeDirectoryForCurrentUser, symbol: "house")]

        let keys: [URLResourceKey] = [
            .volumeLocalizedNameKey, .volumeIsInternalKey, .volumeIsBrowsableKey,
            .volumeIsLocalKey,
        ]
        for volume in fm.mountedVolumeURLs(
            includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        {
            let values = try? volume.resourceValues(forKeys: Set(keys))
            guard values?.volumeIsBrowsable != false else { continue }
            let symbol =
                values?.volumeIsLocal == false
                ? "network" : values?.volumeIsInternal == true ? "internaldrive" : "externaldrive"
            nodes.append(
                Node(
                    title: values?.volumeLocalizedName ?? fm.displayName(atPath: volume.path),
                    url: volume, symbol: symbol))
        }

        if let trash = try? fm.url(
            for: .trashDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        {
            nodes.append(Node(title: "Trash", url: trash, symbol: "trash"))
        }
        return nodes
    }

    // MARK: Outline view

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? Node)?.children.count ?? sections.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? Node)?.children[index] ?? sections[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !((item as? Node)?.children.isEmpty ?? true)
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        (item as? Node)?.url == nil
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        (item as? Node)?.url != nil
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any)
        -> NSView?
    {
        guard let node = item as? Node else { return nil }
        if node.url == nil {
            let id = NSUserInterfaceItemIdentifier("HeaderCell")
            let cell =
                outlineView.makeView(withIdentifier: id, owner: nil) as? LabelCell
                ?? LabelCell(identifier: id, iconSize: nil)
            cell.textField?.stringValue = node.title
            return cell
        }
        let id = NSUserInterfaceItemIdentifier("PlaceCell")
        let cell =
            outlineView.makeView(withIdentifier: id, owner: nil) as? LabelCell
            ?? LabelCell(identifier: id, iconSize: 18)
        cell.textField?.stringValue = node.title
        cell.textField?.lineBreakMode = .byTruncatingTail
        cell.imageView?.image = node.symbol.flatMap {
            NSImage(systemSymbolName: $0, accessibilityDescription: nil)
        }
        cell.imageView?.contentTintColor = .secondaryLabelColor
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isSelectingInCode,
            let url = (outline.item(atRow: outline.selectedRow) as? Node)?.url
        else { return }
        onSelect?(url)
    }
}
