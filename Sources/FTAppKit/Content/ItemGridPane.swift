// Port of what IconGridView (apps/desktop/src/renderer/components/IconGridView.tsx) and FlowListView
// (ContentPane.tsx:1082-1448) do alike: the items on screen, the selection drawn from the shared model, the keys, the
// presses, drag-to-select (hooks/useDragSelection.ts), the rename field and the items brought into view
import AppKit
import FTFileSystem
import FTFoundation

/// An item view of the Icons or Compact List view.
@MainActor
protocol GridItemView: AnyObject {
    /// The path of the entry it shows.
    var path: String? { get }
    /// Whether a point (in the item's view) is on a part that takes clicks: the tile or the name of an icon, a list item.
    func takesClick(at point: NSPoint) -> Bool
    /// The size of the part that depends on the name, as drag-to-select measures it (`measuredPartSelector`).
    var measuredSize: DragSelectionSize? { get }
}

/// A view of the folder that lays its items out in a grid: Icons and Compact List. Subclasses place the items and draw
/// them; this keeps the rest.
class ItemGridPane: NSViewController, FolderPane, NSCollectionViewDataSource, NSCollectionViewDelegate, GridPlacement,
    LayoutNavigation, RevealScroller
{
    /// Weakly: the host (the content pane) holds this pane as its child.
    weak var host: (any ContentPaneHost)? {
        didSet {
            keyboard = host.map { ContentKeyboard(host: $0, navigation: self) }
            refreshLook()
        }
    }
    private(set) var keyboard: ContentKeyboard?

    let root = ItemGridRootView()
    let scroll = ItemGridScrollView()
    let collection = ItemGridView()
    let gridLayout = ItemGridLayout()
    /// The marquee box, in the collection's content so it scrolls with the items.
    let marquee = MarqueeBoxView()
    var renameField: InlineRenameField?
    var renamingPath: String?
    var lastRefusalCount = 0

    var entries: [DirectoryEntry] = []
    private var indexCache: [String: Int]?
    var indexByPath: [String: Int] {
        if let indexCache { return indexCache }
        let made = Dictionary(entries.enumerated().map { ($1.path, $0) }, uniquingKeysWith: { first, _ in first })
        indexCache = made
        return made
    }
    /// The paths selected, for drawing.
    private(set) var selectedPaths = Set<String>()
    /// Stands for this reading of the folder: previews are checked against their files once for each
    /// (`listing` of IconGridView).
    private(set) var listing = NSObject()
    private var scrollObserver: (any NSObjectProtocol)?

    var focusView: NSView { collection }
    private(set) var hasKeyboard = false

    // MARK: What a subclass says

    /// The view mode, for the keys.
    var navigationViewMode: ExplorerViewMode { .icons }
    var itemIdentifier: NSUserInterfaceItemIdentifier { NSUserInterfaceItemIdentifier("grid.item") }
    func makeItem() -> NSCollectionViewItem { NSCollectionViewItem() }
    /// Shows `entry` in `item`.
    func configure(_ item: NSCollectionViewItem, entry: DirectoryEntry, index: Int) {}
    /// Draws the selection and focus of an item again.
    func refreshLook(of item: NSCollectionViewItem, entry: DirectoryEntry) {}
    /// The density or another metric changed: the items are placed again.
    func metricsChanged() -> Bool { false }
    var placedCount: Int { entries.count }
    func contentSize(viewport: NSSize) -> NSSize { .zero }
    func itemFrame(at index: Int, viewport: NSSize) -> NSRect { .zero }
    func items(in rect: NSRect, viewport: NSSize) -> Range<Int> { 0..<0 }
    func placesChange(from old: NSSize, to new: NSSize) -> Bool { old != new }
    /// The items the box touches; the box is in the collection's coordinates.
    func marqueeHits(box: DragSelectionBox, sizes: [String: DragSelectionSize]) -> [DragSelectionHit] { [] }
    /// The scroll offset that brings the item into view, or nil to leave it.
    func revealOffset(for index: Int) -> NSPoint? { nil }
    /// The rename field over an item, in the collection's coordinates, and its font and alignment.
    func renameFrame(at index: Int) -> NSRect { .zero }
    func renameFont() -> NSFont { NSFont.systemFont(ofSize: NSFont.systemFontSize) }
    var renameAlignment: NSTextAlignment { .left }
    /// The pane's width is about to change (the Icons view moves its items when the Info panel slides).
    func paneWidthWillChange() {}
    /// The items were placed again after a change of the pane's size.
    func didPlaceItems() {}
    var itemsPerLine: Int { 1 }
    var pageGeometry: (viewportSize: Double, lineExtent: Double) { (0, 1) }
    func isWhollyInView(index: Int) -> Bool { true }
    @discardableResult
    func scroll(by delta: Double) -> Bool { false }

    // MARK: View

    override func loadView() {
        root.pane = self
        collection.pane = self
        gridLayout.placement = self
        collection.collectionViewLayout = gridLayout
        collection.isSelectable = false
        collection.allowsMultipleSelection = false
        collection.backgroundColors = [.clear]
        collection.dataSource = self
        collection.delegate = self
        collection.focusRingType = .none
        registerForFileDrops()
        scroll.documentView = collection
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        scroll.contentView.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                // The scrollers show while a pane scrolls, by the keyboard too (lib/scrollbarVisibility.ts).
                self?.scroll.flashScrollers()
                self?.scrolled()
            }
        }
        root.addSubview(scroll)
        view = root
    }

    isolated deinit {
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
    }

    private var lastViewport = NSSize.zero

    func layoutPane() {
        let room = root.roomAboveRows
        let frame = NSRect(x: 0, y: room, width: root.bounds.width, height: max(0, root.bounds.height - room))
        if scroll.frame != frame { scroll.frame = frame }
        let resized = lastViewport != viewport
        if placesChange(from: lastViewport, to: viewport) { gridLayout.invalidateLayout() }
        lastViewport = viewport
        placeItems()
        if resized { keepInView(.layout) }
        didPlaceItems()
        positionRenameField()
    }

    var viewport: NSSize { scroll.contentView.bounds.size }

    /// Sizes the collection to its content (every item's place, as the layout reckons it) and places the items on
    /// screen.
    func placeItems() {
        let size = gridLayout.collectionViewContentSize
        if collection.frame.size != size { collection.setFrameSize(size) }
        collection.layoutSubtreeIfNeeded()
        reportVisiblePaths()
    }

    // MARK: Pane

    func reload(scrollToTop: Bool) {
        entries = host?.entries ?? []
        indexCache = nil
        listing = NSObject()
        _ = metricsChanged()
        readSelection()
        collection.reloadData()
        if scrollToTop {
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
            revealKeeper.forget()
        }
        placeItems()
        keepInView(.list)
        syncRename()
    }

    func reloadRows(paths: Set<String>) {
        entries = host?.entries ?? []
        indexCache = nil
        listing = NSObject()
        let indexPaths = Set(paths.compactMap { indexByPath[$0] }.map { IndexPath(item: $0, section: 0) })
        collection.reloadItems(at: indexPaths)
        syncSelection()
        keepInView(.list)
    }

    func refresh(paths: Set<String>?) {
        forEachVisibleItem { item, entry in
            if paths == nil || paths?.contains(entry.path) == true { self.refreshLook(of: item, entry: entry) }
        }
    }

    func syncSelection() {
        keepInView(.ask)
        let before = selectedPaths
        readSelection()
        guard before != selectedPaths else { return }
        let changed = before.symmetricDifference(selectedPaths)
        forEachVisibleItem { item, entry in
            if changed.contains(entry.path) { self.refreshLook(of: item, entry: entry) }
        }
    }

    private func readSelection() {
        selectedPaths = Set(host?.selection.paths ?? [])
    }

    func refreshLook() {
        marquee.apply(theme: host?.theme ?? AppearanceModel.shared.theme)
        renameField?.applyTheme(host?.theme ?? AppearanceModel.shared.theme)
        forEachVisibleItem { item, entry in self.refreshLook(of: item, entry: entry) }
    }

    /// The clipboard's marks changed (P5-08): the items are drawn again.
    func clipboardMarksChanged() {
        refresh(paths: nil)
    }

    func columnsChanged() {
        guard metricsChanged() else { return }
        collection.reloadData()
        placeItems()
        keepInView(.layout)
        syncRename()
    }

    func reveal(index: Int) {
        placeItems()
        guard let offset = revealOffset(for: index) else { return }
        let clip = scroll.contentView
        guard abs(offset.x - clip.bounds.origin.x) > 1 || abs(offset.y - clip.bounds.origin.y) > 1 else { return }
        clip.scroll(to: offset)
        scroll.reflectScrolledClipView(clip)
    }

    /// Whether the view keeps the item being renamed in view, and brings back a refused name.
    var keepsRenameInView: Bool { true }

    private let revealKeeper = RevealKeeper()

    /// The item being renamed, or else the selection's lead, is kept in view as `RevealKeeper` says.
    func keepInView(_ change: RevealKeeper.Change) {
        guard let host else { return }
        let ask = host.revealAsk(followingRename: keepsRenameInView)
        revealKeeper.keepInView(change, ask: ask, index: ask.path.flatMap { indexByPath[$0] }, scroller: self)
    }

    var scrollOrigin: NSPoint { scroll.contentView.bounds.origin }

    func isInView(index: Int) -> Bool { isWhollyInView(index: index) }

    func bringIntoView(index: Int) {
        guard viewport.width > 0, viewport.height > 0 else { return }
        reveal(index: index)
    }

    var scrollPosition: (top: Double, left: Double) {
        get {
            let origin = scroll.contentView.bounds.origin
            return (Double(origin.y), Double(origin.x))
        }
        set {
            placeItems()
            let clip = scroll.contentView
            let document = collection.frame.size
            let maxX = max(0, document.width - clip.bounds.width)
            let maxY = max(0, document.height - clip.bounds.height)
            clip.scroll(to: NSPoint(x: min(maxX, max(0, newValue.left)), y: min(maxY, max(0, newValue.top))))
            scroll.reflectScrolledClipView(clip)
        }
    }

    func keyboardChanged(_ has: Bool) {
        hasKeyboard = has
        forEachVisibleItem { item, entry in self.refreshLook(of: item, entry: entry) }
    }

    // MARK: Items

    var paneFocused: Bool { hasKeyboard }
    var windowActive: Bool { host?.windowIsActive ?? true }

    func isSelected(_ path: String) -> Bool { selectedPaths.contains(path) }

    func forEachVisibleItem(_ body: (NSCollectionViewItem, DirectoryEntry) -> Void) {
        for indexPath in collection.indexPathsForVisibleItems() {
            guard entries.indices.contains(indexPath.item), let item = collection.item(at: indexPath) else { continue }
            body(item, entries[indexPath.item])
        }
    }

    func visibleItem(at index: Int) -> NSCollectionViewItem? {
        collection.item(at: IndexPath(item: index, section: 0))
    }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        entries.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath)
        -> NSCollectionViewItem
    {
        let item = collectionView.makeItem(withIdentifier: itemIdentifier, for: indexPath)
        if entries.indices.contains(indexPath.item) {
            configure(item, entry: entries[indexPath.item], index: indexPath.item)
        }
        return item
    }

    /// The item under a point of the collection, on a part of it that takes clicks.
    func itemIndex(at point: NSPoint) -> Int? {
        for indexPath in collection.indexPathsForVisibleItems() {
            guard let item = collection.item(at: indexPath), item.view.frame.contains(point),
                let gridItem = item as? GridItemView
            else { continue }
            if gridItem.takesClick(at: item.view.convert(point, from: collection)) { return indexPath.item }
        }
        return nil
    }

    /// The entry under a point of the collection, for drops.
    func entry(at point: NSPoint) -> DirectoryEntry? {
        itemIndex(at: point).map { entries[$0] }
    }

    var selectedEntries: [DirectoryEntry] {
        (host?.selection.paths ?? []).compactMap { indexByPath[$0].map { entries[$0] } }
    }

    /// The capture's `select` step: these items, in the list's order.
    func selectFromOutside(_ indices: [Int]) {
        let paths = indices.filter { entries.indices.contains($0) }.map { entries[$0].path }
        host?.selectionChanged(ContentSelection.of(paths))
    }

    // MARK: Scrolling

    // The details of a folder's items on screen are read only in the List, which shows them
    // (useExplorerNavigationController's `viewMode === "details"`); search results' are read in every view, so sizes
    // reach the status line and the Info panel (App.tsx onVisiblePathsChange -> loadSearchResultMetadata).
    private func scrolled() {
        // Scrolling moves the item away from the reason a name was refused, so it is dropped until the next try.
        renameField?.hideError()
        reportVisiblePaths()
    }

    private func reportVisiblePaths() {
        guard let host, host.search != nil, !entries.isEmpty else { return }
        let visible = collection.indexPathsForVisibleItems().map(\.item).filter { entries.indices.contains($0) }
        guard let lower = visible.min(), let upper = visible.max() else { return }
        host.requestMetadata(for: entries[lower...upper].map(\.path))
    }
}
