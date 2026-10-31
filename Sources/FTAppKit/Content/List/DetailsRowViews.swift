// Port of DetailsRow and DetailsCell (apps/desktop/src/renderer/components/ContentPane.tsx:1893-2260) and the row rules of
// styles.css:2894-2960 and 4440-4500
import AppKit
import FTFileSystem
import FTFoundation

/// The row of the table: it draws nothing itself. The bar inside the cell is the row the original draws (inset from the
/// pane's edges, with rounded corners), and it takes the selection.
final class DetailsRowView: NSTableRowView {
    /// The whole row takes the pointer: AppKit's own separator view inside it would otherwise.
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    var cellView: DetailsCellView? { subviews.compactMap { $0 as? DetailsCellView }.first }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        // The cell fills its row, which is as wide as the pane (`.details-row { width: 100% }`).
        if let cell = cellView, cell.frame != bounds { cell.frame = bounds }
    }

    override var isSelected: Bool {
        didSet {
            if isSelected != oldValue { cellView?.bar.setSelected(isSelected) }
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func drawBackground(in dirtyRect: NSRect) {}
    override func drawSelection(in dirtyRect: NSRect) {}
    override func drawSeparator(in dirtyRect: NSRect) {}
    override func drawDraggingDestinationFeedback(in dirtyRect: NSRect) {}
}

/// The table's one cell: a full-width view that holds the inset bar.
final class DetailsCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("name")
    let bar = DetailsBarView()

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        addSubview(bar)
        textField = bar.nameLabel
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let inset = bar.layoutMetrics.rowInset
        bar.frame = NSRect(x: inset, y: 0, width: max(0, bounds.width - 2 * inset), height: bounds.height)
    }
}

/// The Name cell (`.details-name`): the icon, then the name.
final class NameCellView: NSView, TextStyleSource {
    let iconView = NSImageView()
    let label = NameLabel()
    /// The copy or cut glyph after the name of an item on the clipboard (P5-08).
    let markGlyph = ClipboardMarkGlyph(identifier: "list.row.clipboardMark")

    var styleTextField: NSTextField? { label }

    init() {
        super.init(frame: .zero)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.isEditable = false
        addSubview(iconView)
        addSubview(label)
        addSubview(markGlyph)
        setAccessibilityIdentifier("list.row.name")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func layout(metrics: DetailsLayout) {
        let icon = metrics.iconSize
        iconView.frame = NSRect(x: 0, y: (bounds.height - icon) / 2, width: icon, height: icon)
        let x = icon + metrics.nameIconGap
        let height = label.lineHeight
        var width = max(0, bounds.width - x)
        if !markGlyph.isHidden {
            // The glyph follows the name; a name that does not fit is shortened, and the glyph keeps its size.
            let size = ClipboardMarkGlyph.size
            let gap = CGFloat(ClipboardLayout.Mark.gap)
            width = max(0, min(ceil(label.textWidth), bounds.width - x - gap - size))
            // After the text itself: the label's frame is whole points wide, the text isn't.
            let textEnd = min(label.textWidth, width)
            markGlyph.frame = NSRect(x: x + textEnd + gap, y: (bounds.height - size) / 2, width: size, height: size)
        }
        label.frame = NSRect(x: x, y: (bounds.height - height) / 2, width: width, height: height)
    }
}

/// A transparent view over a row that marks it for the capture: an odd (striped) row, a selected one. It reports the
/// row's name as its text, as the original's selection bar does.
final class RowMarkerView: NSView, TextStyleSource {
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

/// A size bar (`.details-size-bar`), drawn behind the size.
final class SizeBarView: NSView {
    var color: NSColor = .clear {
        didSet { needsDisplay = true }
    }
    var radius: CGFloat = 0

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
    }
}

/// The Size cell (`.details-size`): the text at the right edge, and the bar behind it while sorted by size.
final class SizeCellView: NSView {
    let label = ListLabel()
    let bar = SizeBarView()

    init() {
        super.init(frame: .zero)
        addSubview(bar)
        addSubview(label)
        // The bar's overhang and its right-hand rounding are cut at the cell's edge (styles.css:2883-2888).
        clipsToBounds = true
        setAccessibilityIdentifier("list.row.sizeCell")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The row as the original draws it: a bar inset from the pane's edges, rounded, striped or selected, with a cell for
/// each column. Cells are laid out by hand.
final class DetailsBarView: NSView {
    let nameCell = NameCellView()
    let sizeCell = SizeCellView()
    private var labels: [DetailColumn: ListLabel] = [:]

    private(set) var layoutMetrics = DesignTokens.details(density: .comfortable)
    private var fitted = DetailsColumnSet(columns: [.name], widths: [:])
    private var colors = RowColors.make(
        theme: AppearanceModel.shared.theme, layout: DesignTokens.details(density: .comfortable), selected: false,
        odd: false, paneFocused: false, windowActive: true)
    private weak var host: (any ContentPaneHost)?
    private(set) var entry: DirectoryEntry?
    private var row = 0
    private var selected = false
    private var iconRequest: LoadHandle?
    private var sizeBarFraction: Double?
    private let oddMarker = RowMarkerView(id: "list.row.odd")
    private let selectedMarker = RowMarkerView(id: "list.row.selected")
    /// Marks a cut row for the capture (`.details-row.clipboard-cut`).
    private let cutMarker = RowMarkerView(id: "list.row.cut")
    /// Marks the row a drag would drop into (`.details-row[data-drop-target-state="valid"]`).
    private let dropMarker = RowMarkerView(id: "list.row.dropTarget")
    private var dropState: DropTargetState?

    var nameLabel: NameLabel { nameCell.label }

    init() {
        super.init(frame: .zero)
        addSubview(oddMarker)
        addSubview(selectedMarker)
        addSubview(cutMarker)
        addSubview(dropMarker)
        addSubview(nameCell)
        addSubview(sizeCell)
        setAccessibilityIdentifier("list.row")
        oddMarker.source = nameCell.label
        selectedMarker.source = nameCell.label
        cutMarker.source = nameCell.label
        dropMarker.source = nameCell.label
        sizeCell.label.setAccessibilityIdentifier("list.row.size")
        sizeCell.bar.setAccessibilityIdentifier("list.row.sizeBar")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    // MARK: Content

    func configure(
        entry: DirectoryEntry, row: Int, selected: Bool, host: any ContentPaneHost, fitted: DetailsColumnSet,
        layout: DetailsLayout
    ) {
        self.host = host
        self.entry = entry
        self.row = row
        self.selected = selected
        self.fitted = fitted
        layoutMetrics = layout
        nameLabel.stringValue = entry.name
        nameLabel.fileExtension = entry.fileExtension
        nameLabel.marks = host.search?.match(in: entry.name).map { [$0] } ?? []
        toolTip = entry.path
        showIcon(for: entry, host: host)
        refreshCells()
        needsLayout = true
        needsDisplay = true
    }

    /// Reads the row's details again (they arrived, a folder size came in, the clock moved on).
    func refreshCells() {
        guard let entry, let host else { return }
        let layout = layoutMetrics
        let metadata = host.metadata(for: entry.path)
        let now = RelativeClock.shared.relativeNow
        colors = RowColors.make(
            theme: host.theme, layout: layout, selected: selected, odd: row % 2 == 1,
            paneFocused: host.paneHasKeyboard, windowActive: host.windowIsActive)
        let font = ListFonts.row(layout)
        nameLabel.font = font
        nameLabel.textColor = NSColor(colors.name)
        nameLabel.marksUnderlined = selected && host.paneHasKeyboard && host.windowIsActive
        // The rename field stands in for the name it edits.
        nameLabel.isHidden = host.inlineRename?.path == entry.path
        // An item on the clipboard: its glyph after the name, and a cut one dimmed (P5-08).
        let mark = host.clipboardMarks?.mark(for: entry.path)
        nameCell.markGlyph.mark = mark
        nameCell.markGlyph.color = ClipboardMarkGlyph.color(theme: host.theme, onSelection: marksOnSelection)
        nameLabel.alphaValue = mark == .cut ? CGFloat(ClipboardLayout.Mark.cutLabelAlpha) : 1
        cutMarker.isHidden = mark != .cut
        dropState = host.dropState(for: entry.path)
        dropMarker.isHidden = dropState == nil || dropState == .invalid
        DropHighlight.setWiggle(nameCell.iconView, on: dropState == .springing)
        sizeBarFraction = nil
        for column in fitted.columns where column != .name {
            let content = ListCellText.content(
                column: column, entry: entry, metadata: metadata, folderSize: host.folderSizeEntry(entry.path),
                now: now)
            switch column {
            case .size:
                sizeCell.label.font = font
                sizeCell.label.stringValue = content.text
                sizeCell.label.textColor = NSColor(content.isPlaceholder ? colors.placeholder : colors.cell)
                if let scale = host.sizeBarScale {
                    sizeBarFraction = SizeBars.fraction(bytes: host.sizeBytes(of: entry), maxBytes: scale)
                }
                sizeCell.bar.color = NSColor(colors.sizeBar.withAlpha(colors.sizeBarAlpha))
                sizeCell.bar.radius = CGFloat(DesignTokens.radii.xs)
            case .folder:
                // `.details-folder`: right to left, so a long folder loses its start ("…src › renderer").
                let label = label(for: column)
                label.font = font
                label.stringValue = host.search?.folderLabel(entry.path) ?? ""
                label.textColor = NSColor(colors.cell)
                label.toolTip = NodePath.dirname(entry.path)
            default:
                let label = label(for: column)
                label.font = column == .permissions ? ListFonts.permissions(layout) : font
                label.stringValue = content.text
                label.textColor = NSColor(colors.cell)
                label.toolTip = content.tooltip
            }
        }
        oddMarker.isHidden = row % 2 != 1
        selectedMarker.isHidden = !selected
        needsLayout = true
        needsDisplay = true
    }

    private func label(for column: DetailColumn) -> ListLabel {
        if let existing = labels[column] { return existing }
        let label = column == .folder ? FolderColumnLabel() : ListLabel()
        label.setAccessibilityIdentifier("list.row.cell.\(column.rawValue)")
        addSubview(label)
        labels[column] = label
        return label
    }

    private func showIcon(for entry: DirectoryEntry, host: any ContentPaneHost) {
        iconRequest?.cancel()
        iconRequest = nil
        nameCell.iconView.image = nil
        guard let store = host.iconStore else { return }
        let request = IconRequest(entry: entry.iconEntry)
        switch store.lookup(request) {
        case .image(let image): nameCell.iconView.image = image
        case .none: break
        case .missing:
            let path = entry.path
            iconRequest = store.load(request) { [weak self] image in
                guard let self, self.entry?.path == path else { return }
                self.nameCell.iconView.image = image
            }
        }
    }

    // MARK: Selection and look

    func setSelected(_ value: Bool) {
        guard value != selected else { return }
        selected = value
        refreshCells()
    }

    /// Whether the dates in this row read in minutes (they need the minute clock).
    var readsInMinutes: Bool {
        guard let entry, let host else { return false }
        let metadata = host.metadata(for: entry.path)
        let now = RelativeClock.shared.relativeNow
        return fitted.columns.contains { column in
            switch column {
            case .modified: ListCellText.readsInMinutes(metadata?.modifiedAt, now: now)
            case .created: ListCellText.readsInMinutes(metadata?.createdAt, now: now)
            default: false
            }
        }
    }

    // MARK: Drawing and layout

    override func draw(_ dirtyRect: NSRect) {
        let radius = CGFloat(layoutMetrics.rowRadius)
        if let background = colors.background {
            NSColor(background).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        }
        if let dropState, let host {
            DropHighlight.drawRow(dropState, in: bounds, radius: radius, theme: host.theme)
        }
    }

    /// A selected row in the focused list of the window in front: the glyph and the flash take the text's color.
    private var marksOnSelection: Bool {
        selected && (host?.paneHasKeyboard ?? false) && (host?.windowIsActive ?? false)
    }

    /// The row's item was just copied or cut (`.clipboard-flash`).
    func flashClipboardMark() {
        guard let entry, let host, host.clipboardMarks?.mark(for: entry.path) != nil else { return }
        ClipboardFlash.flash(
            self, color: ClipboardMarkGlyph.color(theme: host.theme, onSelection: marksOnSelection),
            radius: CGFloat(layoutMetrics.rowRadius))
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let layout = layoutMetrics
        oddMarker.frame = bounds
        selectedMarker.frame = bounds
        cutMarker.frame = bounds
        dropMarker.frame = bounds
        for label in labels.values { label.isHidden = true }
        sizeCell.isHidden = true
        var x = layout.rowPaddingInline
        for column in fitted.columns {
            let width = fitted.width(column)
            switch column {
            case .name:
                let icon = layout.iconSize
                nameCell.frame = NSRect(x: x, y: (bounds.height - icon) / 2, width: width, height: icon)
                nameCell.layout(metrics: layout)
            case .size:
                sizeCell.isHidden = false
                sizeCell.frame = NSRect(x: x, y: 0, width: width, height: bounds.height)
                let height = sizeCell.label.lineHeight
                let textWidth = min(width, sizeCell.label.textWidth)
                sizeCell.label.frame = NSRect(
                    x: width - textWidth, y: (bounds.height - height) / 2, width: textWidth, height: height)
                if let span = SizeBars.span(fraction: sizeBarFraction, cellWidth: width, layout: layout) {
                    sizeCell.bar.isHidden = false
                    sizeCell.bar.frame = NSRect(
                        x: span.x, y: layout.sizeBarInsetVertical, width: span.width,
                        height: max(0, bounds.height - 2 * layout.sizeBarInsetVertical))
                } else {
                    sizeCell.bar.isHidden = true
                }
            default:
                let label = label(for: column)
                label.isHidden = false
                let height = label.lineHeight
                label.frame = NSRect(x: x, y: (bounds.height - height) / 2, width: width, height: height)
            }
            x += width + layout.columnGap
        }
    }

    isolated deinit {
        iconRequest?.cancel()
    }
}
