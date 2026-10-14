import AppKit

/// The List view: one row per item, sortable columns, Name always first.
final class ListViewController: NSViewController, FolderPane, NSTableViewDataSource,
    NSTableViewDelegate
{
    private enum Column: String, CaseIterable {
        case name, modified, size, kind

        var title: String {
            switch self {
            case .name: "Name"
            case .modified: "Date Modified"
            case .size: "Size"
            case .kind: "Kind"
            }
        }

        var width: CGFloat {
            switch self {
            case .name: 300
            case .modified: 180
            case .size: 80
            case .kind: 160
            }
        }
    }

    var onOpen: (([FileItem]) -> Void)?
    var onSortChange: ((NSSortDescriptor) -> Void)?

    private let table = NSTableView()
    private var items: [FileItem] = []
    private var isSortingInCode = false

    var focusView: NSView { table }

    var selectedItems: [FileItem] {
        table.selectedRowIndexes.compactMap { items.indices.contains($0) ? items[$0] : nil }
    }

    override func loadView() {
        for column in Column.allCases {
            let tableColumn = NSTableColumn(identifier: .init(column.rawValue))
            tableColumn.title = column.title
            tableColumn.width = column.width
            tableColumn.minWidth = 60
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.rawValue, ascending: true)
            if column == .size { tableColumn.headerCell.alignment = .right }
            table.addTableColumn(tableColumn)
        }
        table.style = .fullWidth
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.autosaveName = "ListColumns"
        table.autosaveTableColumns = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked(_:))

        table.headerView?.setAccessibilityIdentifier("list.header")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        view = scroll
    }

    func show(_ items: [FileItem], sort: NSSortDescriptor, scrollToTop: Bool) {
        self.items = items
        if table.sortDescriptors.first != sort {
            isSortingInCode = true
            table.sortDescriptors = [sort]
            isSortingInCode = false
        }
        table.reloadData()
        if scrollToTop, !items.isEmpty { table.scrollRowToVisible(0) }
    }

    func select(_ urls: [URL]) {
        guard !urls.isEmpty || !table.selectedRowIndexes.isEmpty else { return }
        // Listed URLs are already standard; normalizing 3,000 of them costs ~30 ms.
        let paths = Set(urls.map(\.comparablePath))
        let rows = IndexSet(items.indices.filter { paths.contains(items[$0].url.path) })
        table.selectRowIndexes(rows, byExtendingSelection: false)
        if let first = rows.first { table.scrollRowToVisible(first) }
    }

    @objc private func doubleClicked(_ sender: Any?) {
        guard table.clickedRow >= 0 else { return }
        onOpen?(selectedItems)
    }

    // MARK: Table view

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, let column = Column(rawValue: tableColumn.identifier.rawValue) else {
            return nil
        }
        let item = items[row]
        let cell =
            tableView.makeView(withIdentifier: tableColumn.identifier, owner: nil) as? LabelCell
            ?? LabelCell(
                identifier: tableColumn.identifier, iconSize: column == .name ? 16 : nil,
                alignment: column == .size ? .right : .left)
        switch column {
        case .name:
            cell.setAccessibilityIdentifier("list.row.name")
            cell.textField?.stringValue = item.name
            cell.imageView?.image = FileIcons.icon(for: item.url)
        case .modified:
            cell.textField?.stringValue = Formatting.date(item.modified)
        case .size:
            cell.textField?.stringValue = Formatting.size(item.size)
        case .kind:
            cell.textField?.stringValue = item.kind
        }
        if column != .name { cell.textField?.textColor = .secondaryLabelColor }
        return cell
    }

    func tableView(_ tableView: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int) {
        rowView.setAccessibilityIdentifier("list.row")
    }

    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int)
        -> String?
    {
        tableColumn?.identifier.rawValue == Column.name.rawValue ? items[row].name : nil
    }

    func tableView(_ tableView: NSTableView, shouldReorderColumn columnIndex: Int, toColumn newColumnIndex: Int)
        -> Bool
    {
        columnIndex != 0 && newColumnIndex != 0
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard !isSortingInCode, let sort = tableView.sortDescriptors.first else { return }
        onSortChange?(sort)
    }
}
