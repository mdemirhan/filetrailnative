// Port of what IconGridView.tsx and FlowListView (apps/desktop/src/renderer/components/ContentPane.tsx:1082-1448) share:
// the scroll container, items placed from layout tokens instead of measured, and the selection colours of styles.css:4470-4500
// and 8041-8053
import AppKit
import FTFileSystem
import FTFoundation

/// What the clipboard holds of an item, as the views of the folder mark it (`ClipboardMarks` of `clipboardMarks.tsx`):
/// copied, cut, or nothing. The window's clipboard (P5-08) tells the content pane.
enum ContentClipboardMark: Equatable, Sendable {
    case copy, cut
}

/// The colours of a selected item in the Icons and Compact List views: the accent with white text in the pane that has
/// the keyboard, grey otherwise, and grey with the ordinary text while the window is in the background
/// (`body.window-inactive`).
struct GridSelectionColors: Equatable {
    /// Behind the item (Compact List) or its name (Icons); nil when it is not selected.
    var background: RGBA?
    var text: RGBA
    /// The extension after a Compact List name.
    var softText: RGBA

    static func make(theme: Theme, selected: Bool, paneFocused: Bool, windowActive: Bool) -> GridSelectionColors {
        let palette = theme.palette
        guard selected else {
            return GridSelectionColors(background: nil, text: palette.textPrimary, softText: palette.textPrimary)
        }
        guard paneFocused else {
            return GridSelectionColors(
                background: palette.bgActiveInactive, text: palette.textPrimary, softText: palette.textPrimary)
        }
        guard windowActive else {
            return GridSelectionColors(
                background: palette.bgActiveInactive, text: palette.textPrimary, softText: palette.textSecondary)
        }
        let accent = theme.accent
        return GridSelectionColors(
            background: accent.selectionBg, text: accent.onSelection, softText: accent.onSelectionSoft)
    }
}

/// Where a view of the folder places its items, from its layout tokens (the views never measure the page for this).
@MainActor
protocol GridPlacement: AnyObject {
    var placedCount: Int { get }
    /// The size of the scrolling content in a viewport of this size.
    func contentSize(viewport: NSSize) -> NSSize
    /// Where the item at `index` sits in the scrolling content.
    func itemFrame(at index: Int, viewport: NSSize) -> NSRect
    /// The items whose places may meet `rect`.
    func items(in rect: NSRect, viewport: NSSize) -> Range<Int>
    /// Whether a viewport of a new size moves items (the Icons view's width, the Compact List's height).
    func placesChange(from old: NSSize, to new: NSSize) -> Bool
}

/// The collection view's layout: frames from the view's placement, nothing measured.
final class ItemGridLayout: NSCollectionViewLayout {
    weak var placement: (any GridPlacement)?
    private var laidOutViewport = NSSize.zero

    var viewport: NSSize {
        collectionView?.enclosingScrollView?.contentView.bounds.size ?? collectionView?.bounds.size ?? .zero
    }

    override func prepare() {
        super.prepare()
        laidOutViewport = viewport
    }

    override var collectionViewContentSize: NSSize {
        let viewport = self.viewport
        let size = placement?.contentSize(viewport: viewport) ?? .zero
        return NSSize(width: max(size.width, viewport.width), height: max(size.height, viewport.height))
    }

    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        guard let placement else { return [] }
        let viewport = self.viewport
        let range = placement.items(in: rect, viewport: viewport)
        var attributes: [NSCollectionViewLayoutAttributes] = []
        attributes.reserveCapacity(range.count)
        for index in range where index < placement.placedCount {
            let frame = placement.itemFrame(at: index, viewport: viewport)
            guard frame.intersects(rect) else { continue }
            let item = NSCollectionViewLayoutAttributes(forItemWith: IndexPath(item: index, section: 0))
            item.frame = frame
            attributes.append(item)
        }
        return attributes
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        guard let placement, indexPath.item >= 0, indexPath.item < placement.placedCount else { return nil }
        let item = NSCollectionViewLayoutAttributes(forItemWith: indexPath)
        item.frame = placement.itemFrame(at: indexPath.item, viewport: viewport)
        return item
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        guard let placement else { return false }
        return placement.placesChange(from: laidOutViewport, to: viewport)
    }
}

/// The scroll container (`.content-scroll`): thin overlay scrollers, no background of its own. The Compact List turns
/// the wheel's up and down into sideways travel.
final class ItemGridScrollView: NSScrollView {
    /// The vertical wheel scrolls sideways (B-VIEW-035).
    var wheelScrollsSideways = false
    /// How far one notch of a wheel without precise deltas moves: Chromium's 40 px per Cocoa line (B-VIEW-035).
    static let wheelLineStep = 40.0

    /// The collection view gives its scroll view the scrollers of its layout's direction, which is vertical for a custom
    /// layout: without this the Compact List would lose the one scroller it has (106), and its thumb with it.
    override var hasHorizontalScroller: Bool {
        get { super.hasHorizontalScroller }
        set { super.hasHorizontalScroller = newValue || wheelScrollsSideways }
    }

    override func scrollWheel(with event: NSEvent) {
        guard wheelScrollsSideways, !event.modifierFlags.contains(.control),
            abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX)
        else {
            super.scrollWheel(with: event)
            return
        }
        // DOM `deltaY` is down-positive; AppKit's is the other way round. A wheel without precise deltas moves by lines.
        let delta = -event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : CGFloat(Self.wheelLineStep))
        scrollSideways(by: Double(delta))
    }

    /// `scrollLeft += delta`, kept within the content.
    func scrollSideways(by delta: Double) {
        let clip = contentView
        let width = documentView?.frame.width ?? 0
        let maxX = max(0, width - clip.bounds.width)
        let next = min(maxX, max(0, clip.bounds.origin.x + CGFloat(delta)))
        guard next != clip.bounds.origin.x else { return }
        clip.scroll(to: NSPoint(x: next, y: clip.bounds.origin.y))
        reflectScrolledClipView(clip)
    }
}

/// The collection view of the Icons and Compact List views. The pane keeps the selection, the keys and the presses;
/// AppKit's own selection is not used.
final class ItemGridView: NSCollectionView, NSUserInterfaceValidations {
    weak var pane: ItemGridPane?
    /// Scrolls under a drag held at an edge: the drops here don't go through the collection's own drag handling.
    var edgeScroll = DragEdgeScroll()

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        if pane?.renameField != nil, !(subview is InlineRenameField) { InlineRenameField.keepOnTop(in: self) }
    }

    /// The collection is as large as its content: AppKit keeps a custom layout's collection as wide as the clip view,
    /// which would leave the Compact List nothing to scroll sideways.
    override func setFrameSize(_ newSize: NSSize) {
        let content = collectionViewLayout?.collectionViewContentSize ?? newSize
        super.setFrameSize(
            NSSize(width: max(newSize.width, content.width), height: max(newSize.height, content.height)))
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { pane?.keyboardChanged(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { pane?.keyboardChanged(false) }
        return accepted
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        pane?.menu(forEventAt: convert(event.locationInWindow, from: nil))
    }

    override func mouseDown(with event: NSEvent) {
        if let pane { pane.handleMouseDown(event) } else { super.mouseDown(with: event) }
    }

    override func keyDown(with event: NSEvent) {
        _ = pane?.handleKeyDown(event)
    }

    override func selectAll(_ sender: Any?) {
        pane?.host?.selectAllEntries()
    }

    func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(NSResponder.selectAll(_:)) { return !(pane?.host?.entryPaths.isEmpty ?? true) }
        return item.action.map { responds(to: $0) } ?? false
    }

    /// Escape and ⌘. while nothing else takes them do nothing here (Escape never clears a selection, B-SEL-017).
    override func cancelOperation(_ sender: Any?) {}

    /// Setting the selection from outside (the capture's `select` step) selects those items in the pane's model.
    override var selectionIndexPaths: Set<IndexPath> {
        get { super.selectionIndexPaths }
        set { pane?.selectFromOutside(newValue.map(\.item).sorted()) }
    }
}

/// The pane's root: the scroll container fills it.
final class ItemGridRootView: NSView, RowsBelowCard {
    weak var pane: ItemGridPane?
    var roomAboveRows: CGFloat = 0 {
        didSet { if roomAboveRows != oldValue { needsLayout = true } }
    }

    override var isFlipped: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        let old = frame.size
        if old.width != newSize.width { pane?.paneWidthWillChange() }
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        pane?.layoutPane()
    }
}

/// A transparent view over an item that names a state of it for the capture (selected, the name's pill); it reports the
/// item's text, as the original's element does.
final class GridMarkerView: NSView, TextStyleSource {
    weak var source: NSTextField?
    var styleTextField: NSTextField? { source }

    init(id: String) {
        super.init(frame: .zero)
        setAccessibilityIdentifier(id)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A view that draws nothing of its own and lets the pointer through to the collection view.
class PassThroughView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The icon of an item, as macOS draws it, from the window's icon store.
@MainActor
enum GridIcons {
    /// Shows the icon of `entry` in `view`, now when it is cached; the returned handle takes the request back.
    static func show(
        _ entry: DirectoryEntry, in view: NSImageView, host: any ContentPaneHost, isCurrent: @escaping () -> Bool
    ) -> LoadHandle? {
        view.image = nil
        guard let store = host.iconStore else { return nil }
        let request = IconRequest(entry: entry.iconEntry)
        switch store.lookup(request) {
        case .image(let image):
            view.image = image
            return nil
        case .none:
            return nil
        case .missing:
            return store.load(request) { image in
                guard isCurrent() else { return }
                view.image = image
            }
        }
    }
}
