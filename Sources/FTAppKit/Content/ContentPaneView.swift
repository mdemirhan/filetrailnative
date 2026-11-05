import AppKit
import FTFoundation

/// The content pane's rows: the search header in search mode or the Trash's bar, the list and the Info Row. The
/// path bar row is the pane's too, but lies in the workspace's status cell, which runs under the Info panel as well.
final class ContentPaneView: NSView {
    /// The search results' header; nil outside search mode.
    var searchHeader: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let searchHeader { addSubview(searchHeader) }
            needsLayout = true
        }
    }
    var searchHeaderHeight = 0.0
    /// The Trash's bar; nil anywhere else, and while search results show.
    var trashHeader: TrashHeaderView? {
        didSet {
            guard trashHeader !== oldValue else { return }
            oldValue?.removeFromSuperview()
            if let trashHeader { addSubview(trashHeader) }
            needsLayout = true
        }
    }
    var list: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let list { addSubview(list, positioned: .below, relativeTo: infoRow) }
            needsLayout = true
        }
    }
    let infoRow = InfoRowView()
    let pathBarRow = PathBarRowView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityIdentifier("contentPane")
        // Closed, it is a line's height: what is in it is cut off (`overflow: hidden`), and not on screen.
        infoRow.clipsToBounds = true
        addSubview(infoRow)
        infoRow.onHeightChange = { [weak self] in self?.needsLayout = true }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    /// Told when the pane is put in a window or taken out of one, to follow the window's focus.
    var onMovedToWindow: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onMovedToWindow?(window)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        let reach = PathBarRowView.reach
        var y = 0.0
        if let searchHeader {
            searchHeader.frame = NSRect(x: 0, y: 0, width: width, height: searchHeaderHeight)
            y = searchHeaderHeight
        }
        if let trashHeader {
            trashHeader.frame = NSRect(x: 0, y: y, width: width, height: TrashHeaderView.height)
            y += TrashHeaderView.height
        }
        let infoHeight = infoRow.height
        let listHeight = max(0, bounds.height - y - infoHeight)
        list?.frame = NSRect(x: 0, y: y, width: width, height: listHeight)
        infoRow.frame = NSRect(x: -reach, y: y + listHeight, width: width + reach, height: infoHeight)
    }
}
