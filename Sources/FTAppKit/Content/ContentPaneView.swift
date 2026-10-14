// Port of the rows of the .content-pane of apps/desktop/src/renderer/components/ContentPane.tsx (styles.css:4377-4385)
import AppKit
import FTFoundation

/// The content pane's rows: the search header in search mode (P5-07), the list, the Info Row and the path bar row.
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
        addSubview(infoRow)
        addSubview(pathBarRow)
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
        let pathHeight = PathBarRowView.height
        let infoHeight = infoRow.height
        let listHeight = max(0, bounds.height - y - pathHeight - infoHeight)
        list?.frame = NSRect(x: 0, y: y, width: width, height: listHeight)
        infoRow.frame = NSRect(x: -reach, y: y + listHeight, width: width + reach, height: infoHeight)
        pathBarRow.frame = NSRect(x: -reach, y: bounds.height - pathHeight, width: width + reach, height: pathHeight)
    }
}
