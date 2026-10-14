import AppKit
import FTFileSystem
import QuickLookThumbnailing

/// The Icon view: a grid that stretches to fill the width, with Quick Look thumbnails. The spike's view, kept working until
/// the Icons package (P5-04) registers its own.
final class IconViewController: NSViewController, FolderPane, NSCollectionViewDataSource, NSCollectionViewDelegate {
    var host: (any ContentPaneHost)?

    private let collection = IconCollectionView()
    private var items: [DirectoryEntry] = []
    private var isSyncing = false

    var focusView: NSView { collection }

    override func loadView() {
        collection.collectionViewLayout = Self.makeLayout()
        collection.isSelectable = true
        collection.allowsMultipleSelection = true
        collection.allowsEmptySelection = true
        collection.backgroundColors = [.clear]
        collection.dataSource = self
        collection.delegate = self
        collection.register(IconItem.self, forItemWithIdentifier: IconItem.identifier)
        collection.onDoubleClick = { [weak self] in
            guard let self, !self.selectedEntries.isEmpty else { return }
            self.host?.activate(self.selectedEntries, newTab: NSEvent.modifierFlags.contains(.command))
        }
        collection.backgroundMenu = { [weak self] in self?.host?.contextMenu(for: nil) }

        let scroll = NSScrollView()
        scroll.documentView = collection
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        view = scroll
    }

    private var selectedEntries: [DirectoryEntry] {
        collection.selectionIndexPaths.map(\.item).sorted().compactMap { items.indices.contains($0) ? items[$0] : nil }
    }

    func reload(scrollToTop: Bool) {
        items = host?.entries ?? []
        collection.reloadData()
        if scrollToTop { collection.scroll(.zero) }
        syncSelection()
    }

    func syncSelection() {
        guard let host else { return }
        let paths = Set(host.selection.paths)
        let selection = Set(
            items.indices.filter { paths.contains(items[$0].path) }.map { IndexPath(item: $0, section: 0) })
        guard selection != collection.selectionIndexPaths else { return }
        isSyncing = true
        collection.selectionIndexPaths = selection
        isSyncing = false
    }

    func reveal(paths: [String]) {
        let wanted = Set(paths)
        if let first = items.indices.first(where: { wanted.contains(items[$0].path) }) {
            collection.scrollToItems(at: [IndexPath(item: first, section: 0)], scrollPosition: .nearestHorizontalEdge)
        }
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        selectionDidChange()
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        selectionDidChange()
    }

    private func selectionDidChange() {
        guard !isSyncing else { return }
        let entries = selectedEntries
        host?.selectionChanged(ContentSelection.of(entries.map(\.path)))
    }

    private static func makeLayout() -> NSCollectionViewLayout {
        NSCollectionViewCompositionalLayout { _, environment in
            let width = environment.container.effectiveContentSize.width
            let columns = max(1, Int(width / 104))
            let item = NSCollectionLayoutItem(
                layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .fractionalHeight(1)))
            let group = NSCollectionLayoutGroup.horizontal(
                layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .absolute(118)),
                subitem: item, count: columns)
            let section = NSCollectionLayoutSection(group: group)
            section.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10)
            return section
        }
    }

    // MARK: Collection view

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        items.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath)
        -> NSCollectionViewItem
    {
        let item = collectionView.makeItem(withIdentifier: IconItem.identifier, for: indexPath)
        (item as? IconItem)?.configure(items[indexPath.item])
        return item
    }
}

final class IconCollectionView: NSCollectionView {
    var onDoubleClick: (() -> Void)?
    var backgroundMenu: () -> NSMenu? = { nil }

    override func menu(for event: NSEvent) -> NSMenu? {
        backgroundMenu()
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        let point = convert(event.locationInWindow, from: nil)
        if event.clickCount == 2, indexPathForItem(at: point) != nil { onDoubleClick?() }
    }
}

final class IconItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("IconItem")

    private let iconBackground = NSBox()
    private let icon = NSImageView()
    private let label = NSTextField(wrappingLabelWithString: "")
    private var representedURL: URL?
    private var thumbnailRequest: QLThumbnailGenerator.Request?

    override var isSelected: Bool {
        didSet { updateSelection() }
    }

    override func loadView() {
        let root = NSView()

        iconBackground.boxType = .custom
        iconBackground.borderWidth = 0
        iconBackground.cornerRadius = 6
        iconBackground.fillColor = .clear
        icon.imageScaling = .scaleProportionallyUpOrDown
        label.font = .systemFont(ofSize: 12)
        label.alignment = .center
        label.maximumNumberOfLines = 2
        label.cell?.truncatesLastVisibleLine = true
        label.drawsBackground = true
        label.backgroundColor = .clear
        label.wantsLayer = true
        label.layer?.cornerRadius = 4
        label.layer?.masksToBounds = true

        for view in [iconBackground, icon, label] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            iconBackground.topAnchor.constraint(equalTo: root.topAnchor, constant: 2),
            iconBackground.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            iconBackground.widthAnchor.constraint(equalToConstant: 76),
            iconBackground.heightAnchor.constraint(equalToConstant: 76),
            icon.centerXAnchor.constraint(equalTo: iconBackground.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: iconBackground.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 64),
            icon.heightAnchor.constraint(equalToConstant: 64),
            label.topAnchor.constraint(equalTo: iconBackground.bottomAnchor, constant: 4),
            label.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            label.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor, constant: -8),
        ])
        label.preferredMaxLayoutWidth = 92
        root.setAccessibilityIdentifier("icons.item")
        label.setAccessibilityIdentifier("icons.item.name")
        view = root
        imageView = icon
        textField = label
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        cancelThumbnail()
    }

    func configure(_ item: DirectoryEntry) {
        cancelThumbnail()
        representedURL = item.url
        label.stringValue = item.name
        icon.image = IconWorkspace.icon(for: item.url)
        if item.kind == .file || item.kind == .symlinkFile { requestThumbnail(for: item.url) }
        updateSelection()
    }

    private func updateSelection() {
        iconBackground.fillColor = isSelected ? .quaternaryLabelColor : .clear
        label.backgroundColor = isSelected ? .selectedContentBackgroundColor : .clear
        label.textColor = isSelected ? .alternateSelectedControlTextColor : .labelColor
    }

    private func requestThumbnail(for url: URL) {
        let scale = view.window?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: 64, height: 64), scale: scale,
            representationTypes: .thumbnail)
        thumbnailRequest = request
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
            [weak self] representation, _ in
            guard let image = representation?.nsImage else { return }
            DispatchQueue.main.async {
                guard let self, self.representedURL == url else { return }
                self.icon.image = image
            }
        }
    }

    private func cancelThumbnail() {
        if let thumbnailRequest { QLThumbnailGenerator.shared.cancel(thumbnailRequest) }
        thumbnailRequest = nil
    }
}

/// The icons macOS has for files, as the spike's view draws them.
@MainActor
enum IconWorkspace {
    private static let cache = NSCache<NSString, NSImage>()

    static func icon(for url: URL) -> NSImage {
        let key = url.path as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        cache.setObject(image, forKey: key)
        return image
    }
}
