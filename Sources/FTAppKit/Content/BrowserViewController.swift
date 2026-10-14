// Port of the content pane shell of apps/desktop/src/renderer/components/ContentPane.tsx (its rows) around the
// spike's folder views
import AppKit

/// What the List and Icon views share, so the browser can swap them.
@MainActor
protocol FolderPane: AnyObject {
    var onOpen: (([FileItem]) -> Void)? { get set }
    var focusView: NSView { get }
    var selectedItems: [FileItem] { get }
    func show(_ items: [FileItem], sort: NSSortDescriptor, scrollToTop: Bool)
    func select(_ urls: [URL])
}

/// The content side of the window: the current view of the folder and the status bar.
final class BrowserViewController: NSViewController {
    enum Mode: Int {
        case icons, list
    }

    var onOpen: (([FileItem]) -> Void)?
    private(set) var mode: Mode

    private let listPane = ListViewController()
    private let iconPane = IconViewController()
    private let container = NSView()
    private var listing: FolderListing?
    private var availableCapacity: Int64?
    private var shown: [FileItem] = []
    private var filter = ""
    private var sort = NSSortDescriptor(key: "name", ascending: true)

    private var pane: FolderPane { mode == .list ? listPane : iconPane }
    var selectedItems: [FileItem] { pane.selectedItems }

    init() {
        mode = UserDefaults.standard.string(forKey: "viewMode") == "icons" ? .icons : .list
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The rows of the content pane (`.content-pane`): the search header (P5-07), the list, the Info Row and the
    /// path bar row (P5-06).
    let shell = ContentPaneView()
    private var status: NSTextField { shell.pathBarRow.status }

    /// Opens or closes the Info Row.
    func setInfoRowOpen(_ open: Bool) {
        shell.infoRow.isOpen = open
        shell.needsLayout = true
    }

    override func loadView() {
        let root = shell
        container.setAccessibilityIdentifier("content")
        shell.list = container

        for child in [listPane, iconPane] as [NSViewController & FolderPane] {
            addChild(child)
            child.onOpen = { [weak self] items in self?.onOpen?(items) }
        }
        listPane.onSortChange = { [weak self] sort in
            guard let self else { return }
            let selection = self.selectedItems.map(\.url)
            self.sort = sort
            self.refresh(selecting: selection, scrollToTop: false)
            self.onSortChanged?(sort)
        }
        view = root
        install()
    }

    /// Shows a newly read folder and focuses it.
    func show(_ listing: FolderListing, selecting urls: [URL]) {
        self.listing = listing
        availableCapacity = nil
        filter = ""
        refresh(selecting: urls, scrollToTop: true)
        view.window?.makeFirstResponder(pane.focusView)
    }

    func setAvailableCapacity(_ capacity: Int64?) {
        availableCapacity = capacity
        updateStatus()
    }

    /// Told when a column header changes the sort.
    var onSortChanged: ((NSSortDescriptor) -> Void)?

    /// Sorts by `key` (name, modified, size, kind), as the toolbar's Sort menu and the View menu do.
    func setSort(key: String, ascending: Bool) {
        guard key != sort.key || ascending != sort.ascending else { return }
        let selection = selectedItems.map(\.url)
        sort = NSSortDescriptor(key: key, ascending: ascending)
        refresh(selecting: selection, scrollToTop: false)
    }

    func setFilter(_ text: String) {
        guard text != filter else { return }
        filter = text
        refresh(selecting: selectedItems.map(\.url), scrollToTop: true)
    }

    func setMode(_ newMode: Mode) {
        guard newMode != mode else { return }
        let selection = selectedItems.map(\.url)
        mode = newMode
        UserDefaults.standard.set(newMode == .icons ? "icons" : "list", forKey: "viewMode")
        install()
        refresh(selecting: selection, scrollToTop: true)
        view.window?.makeFirstResponder(pane.focusView)
    }

    private func install() {
        for subview in container.subviews { subview.removeFromSuperview() }
        let paneView = (pane as! NSViewController).view
        paneView.frame = container.bounds
        paneView.autoresizingMask = [.width, .height]
        container.addSubview(paneView)
    }

    private func refresh(selecting urls: [URL], scrollToTop: Bool) {
        let all = listing?.items ?? []
        let matching = filter.isEmpty ? all : all.filter { $0.name.localizedStandardContains(filter) }
        shown = Sorting.sorted(matching, by: sort)
        pane.show(shown, sort: sort, scrollToTop: scrollToTop)
        pane.select(urls)
        updateStatus()
    }

    private func updateStatus() {
        let total = listing?.items.count ?? 0
        var text = filter.isEmpty ? itemCount(total) : "\(shown.count) of \(itemCount(total))"
        if let capacity = availableCapacity {
            text += ", \(Formatting.size(capacity)) available"
        }
        status.stringValue = text
        shell.pathBarRow.needsLayout = true
    }

    private func itemCount(_ count: Int) -> String {
        count == 1 ? "1 item" : "\(count) items"
    }
}
