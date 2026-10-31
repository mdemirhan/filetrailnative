// Port of BatchRenamePreview, PreviewRow, Segments, ItemGlyph and the arrow of
// apps/desktop/src/renderer/components/BatchRenameSheet.tsx, and the .batch-rename-preview rules of
// apps/desktop/src/renderer/styles.css (7016-7140)
import AppKit
import FTFoundation

/// One row of the preview, as it is drawn.
struct BatchRenamePreviewRow: Equatable {
    enum Kind: Equatable {
        case item
        /// "and N more", after the last row drawn.
        case more(String)
    }

    var kind: Kind
    var path = ""
    var oldName = ""
    var isFolder = false
    /// The new name and its pieces; nil for "No change".
    var newName: String?
    var segments: [NameSegment] = []
    var tone = BatchRenameSheetText.RowTone.plain
    var note: BatchRenameSheetText.RowNote?

    /// The row's words as shown, without what is there only for screen readers ("IMG_1.jpgx1.jpg").
    var shownText: String {
        switch kind {
        case .more(let text): return text
        case .item:
            return oldName + (newName ?? BatchRenameSheetText.noChange) + (note?.text ?? "")
        }
    }

    /// What a screen reader reads of it.
    var accessibilityText: String {
        switch kind {
        case .more(let text): return text
        case .item:
            var text = oldName + BatchRenameSheetText.becomes + (newName ?? BatchRenameSheetText.noChange)
            if tone == .skipped { text += BatchRenameSheetText.notRenamed }
            if let note { text += " " + note.text }
            return text
        }
    }

    /// The rows for `targets` and the plan: at most 1,000, then "and N more".
    static func rows(targets: [BatchRenameTarget], plan: BatchRenamePlan) -> [BatchRenamePreviewRow] {
        let limit = BatchRenameSheetText.previewRowLimit
        var rows = targets.prefix(limit).enumerated().map { index, target in
            let item = plan.items.indices.contains(index) ? plan.items[index] : .unchanged
            let new = BatchRenameSheetText.newName(item)
            return BatchRenamePreviewRow(
                kind: .item, path: target.path, oldName: target.name, isFolder: target.isFolder, newName: new?.name,
                segments: new?.segments ?? [], tone: BatchRenameSheetText.rowTone(item),
                note: BatchRenameSheetText.describeRow(item))
        }
        if targets.count > limit {
            rows.append(BatchRenamePreviewRow(kind: .more(BatchRenameSheetText.moreRows(targets.count - limit))))
        }
        return rows
    }
}

/// The preview: its header (Name, New Name) and the list of new names ("New names"), which takes the keyboard so it
/// can be scrolled with it.
@MainActor
final class BatchRenamePreviewView: NSView, ThemeApplying, NSTableViewDataSource, NSTableViewDelegate {
    let head = BatchRenamePreviewHead()
    let scroll = NSScrollView()
    let table = BatchRenamePreviewTable()
    private(set) var rows: [BatchRenamePreviewRow] = []
    private var theme = AppearanceModel.shared.theme
    private var heights: [CGFloat] = []
    private var heightsWidth: CGFloat = -1

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityIdentifier("batchRename.preview")
        wantsLayer = true
        layer?.cornerRadius = CGFloat(BatchRenameSheetLayout.Preview.radius)
        layer?.masksToBounds = true
        addSubview(head)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("row"))
        table.addTableColumn(column)
        table.headerView = nil
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.gridStyleMask = []
        table.focusRingType = .none
        table.rowSizeStyle = .custom
        table.usesAutomaticRowHeights = false
        table.style = .plain
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel("New names")
        table.setAccessibilityIdentifier("batchRename.rows")
        table.onFocusChange = { [weak self] in self?.needsDisplay = true }
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsetsZero
        addSubview(scroll)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    func setRows(_ next: [BatchRenamePreviewRow]) {
        guard next != rows else { return }
        rows = next
        heightsWidth = -1
        table.reloadData()
        needsLayout = true
    }

    /// The rows' heights at the list's width: 26, or taller for a note under the new name.
    func rowHeights(width: CGFloat) -> [CGFloat] {
        if width == heightsWidth { return heights }
        let columns = BatchRenameSheetLayout.Preview.columns(width: Double(width))
        let newWidth = CGFloat(columns[3].width)
        heights = rows.map { BatchRenameRowCell.height(of: $0, newNameWidth: newWidth) }
        heightsWidth = width
        return heights
    }

    /// The height it takes at `width`: the header and the rows, the list at most 8 rows of 28.
    func naturalHeight(width: CGFloat) -> CGFloat {
        let layout = BatchRenameSheetLayout.Preview.self
        let total = rowHeights(width: width).reduce(0, +)
        return CGFloat(layout.headHeight) + min(total, CGFloat(layout.maxRowsHeight))
    }

    override func layout() {
        super.layout()
        let headHeight = CGFloat(BatchRenameSheetLayout.Preview.headHeight)
        head.frame = NSRect(x: 0, y: 0, width: bounds.width, height: headHeight)
        scroll.frame = NSRect(x: 0, y: headHeight, width: bounds.width, height: max(0, bounds.height - headHeight))
        table.tableColumns.first?.width = bounds.width
        let total = rowHeights(width: bounds.width).reduce(0, +)
        table.frame = NSRect(x: 0, y: 0, width: bounds.width, height: total)
        table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<rows.count))
    }

    func applyTheme(_ theme: Theme) {
        self.theme = theme
        needsDisplay = true
        table.enumerateAvailableRowViews { rowView, _ in rowView.needsDisplay = true }
    }

    var holdsKeyboard: Bool { window?.firstResponder === table }

    override func draw(_ dirtyRect: NSRect) {
        // `box-shadow: inset 0 0 0 0.5px var(--border-active)`, under the header's fill.
        let edge = CGFloat(BatchRenameSheetLayout.Preview.edge)
        let radius = CGFloat(BatchRenameSheetLayout.Preview.radius)
        let path = NSBezierPath(
            roundedRect: bounds.insetBy(dx: edge / 2, dy: edge / 2), xRadius: radius, yRadius: radius)
        path.lineWidth = edge
        NSColor(theme.palette.borderActive).setStroke()
        path.stroke()
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        let heights = rowHeights(width: bounds.width)
        return heights.indices.contains(row) ? heights[row] : CGFloat(BatchRenameSheetLayout.Preview.rowMinHeight)
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = BatchRenameRowBackground()
        view.index = row
        view.tone = rows.indices.contains(row) ? rows[row].tone : .plain
        return view
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("batchRename.rowCell")
        let cell =
            tableView.makeView(withIdentifier: identifier, owner: self) as? BatchRenameRowCell
            ?? {
                let made = BatchRenameRowCell()
                made.identifier = identifier
                return made
            }()
        cell.show(rows[row])
        return cell
    }
}

/// The list of new names: it takes the keyboard (to be scrolled with it) and says when it does.
@MainActor
final class BatchRenamePreviewTable: NSTableView {
    var onFocusChange: () -> Void = {}

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        onFocusChange()
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        onFocusChange()
        return resigned
    }

    override func drawBackground(inClipRect clipRect: NSRect) {}
}

/// `.batch-rename-preview-head`: Name and New Name over their columns, on the surface's fill with a line under it.
@MainActor
final class BatchRenamePreviewHead: NSView, ThemeApplying {
    let nameLabel: ThemedText
    let newNameLabel: ThemedText
    private var theme = AppearanceModel.shared.theme

    override init(frame: NSRect) {
        let style = batchRenameStyle(BatchRenameSheetLayout.Fonts.small, { $0.palette.textTertiary })
        var onSurface = style
        onSurface.background = { $0.palette.bgSurface }
        nameLabel = ThemedText("Name", style: onSurface)
        newNameLabel = ThemedText("New Name", style: onSurface)
        super.init(frame: frame)
        setAccessibilityIdentifier("batchRename.previewHead")
        setAccessibilityElement(false)
        nameLabel.setAccessibilityIdentifier("batchRename.previewHead.label")
        newNameLabel.setAccessibilityIdentifier("batchRename.previewHead.label")
        addSubview(nameLabel)
        addSubview(newNameLabel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    func applyTheme(_ theme: Theme) {
        self.theme = theme
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let layout = BatchRenameSheetLayout.Preview.self
        let columns = layout.columns(width: Double(bounds.width))
        let line = batchRenameLine(BatchRenameSheetLayout.Fonts.small)
        let inner = bounds.height - CGFloat(layout.headBorder)
        let y = ((inner - line) / 2).rounded()
        nameLabel.frame = NSRect(
            x: CGFloat(columns[1].x), y: y, width: CGFloat(columns[1].width), height: line)
        newNameLabel.frame = NSRect(x: CGFloat(columns[3].x), y: y, width: CGFloat(columns[3].width), height: line)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(theme.palette.bgSurface).setFill()
        bounds.fill()
        let border = CGFloat(BatchRenameSheetLayout.Preview.headBorder)
        NSColor(theme.palette.borderLight).setFill()
        NSRect(x: 0, y: bounds.height - border, width: bounds.width, height: border).fill()
    }
}

/// A row's fill: every second row striped, a row to fix tinted as danger.
@MainActor
final class BatchRenameRowBackground: NSTableRowView {
    var index = 0
    var tone = BatchRenameSheetText.RowTone.plain

    override var isFlipped: Bool { true }

    override func drawBackground(in dirtyRect: NSRect) {
        let theme = AppearanceModel.shared.theme
        let layout = BatchRenameSheetLayout.Preview.self
        if tone == .danger {
            NSColor(theme.palette.danger.withAlpha(layout.dangerRowTint)).setFill()
            bounds.fill()
        } else if index % 2 == 1 {
            // `:nth-child(even)`: the second, fourth… row.
            NSColor(theme.palette.neutralInk.withAlpha(layout.stripeInk)).setFill()
            bounds.fill()
        }
    }

    override func drawSelection(in dirtyRect: NSRect) {}
}

/// A row: the glyph, the old name, the arrow, and the new name with the changed parts marked and the row's note under
/// it; or "and N more".
@MainActor
final class BatchRenameRowCell: NSTableCellView {
    let glyph = BatchRenameGlyphView(.file, identifier: "batchRename.glyph")
    let oldLabel = ThemedText(wrapping: false) { _ in NSAttributedString() }
    let arrow = BatchRenameGlyphView(.arrow, identifier: "batchRename.arrow")
    let newColumn = BatchRenameNewNameView()
    let moreLabel = ThemedText(wrapping: false) { _ in NSAttributedString() }
    private(set) var row = BatchRenamePreviewRow(kind: .item)

    init() {
        super.init(frame: .zero)
        setAccessibilityIdentifier("batchRename.row")
        oldLabel.setAccessibilityIdentifier("batchRename.old")
        oldLabel.lineBreakMode = .byTruncatingTail
        moreLabel.setAccessibilityIdentifier("batchRename.more")
        for view in [glyph, oldLabel, arrow, newColumn, moreLabel] as [NSView] { addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    static var nameLine: CGFloat { batchRenameLine(BatchRenameSheetLayout.Fonts.body) }

    /// A row's height for a new-name column `newNameWidth` wide.
    static func height(of row: BatchRenamePreviewRow, newNameWidth: CGFloat) -> CGFloat {
        let layout = BatchRenameSheetLayout.Preview.self
        let padding = CGFloat(2 * layout.rowPaddingVertical)
        guard case .item = row.kind else {
            return max(CGFloat(layout.rowMinHeight), nameLine + padding)
        }
        let content = max(
            CGFloat(layout.glyphSize), CGFloat(layout.arrowSize),
            BatchRenameNewNameView.height(
                of: row, width: newNameWidth))
        return max(CGFloat(layout.rowMinHeight), content + padding)
    }

    func show(_ row: BatchRenamePreviewRow) {
        self.row = row
        toolTip = row.path.isEmpty ? nil : row.path
        setAccessibilityLabel(row.accessibilityText)
        switch row.kind {
        case .more(let text):
            for view in [glyph, oldLabel, arrow, newColumn] as [NSView] { view.isHidden = true }
            moreLabel.isHidden = false
            moreLabel.content = {
                batchRenameStyle(BatchRenameSheetLayout.Fonts.body, { $0.palette.textSecondary }).string(text, $0)
            }
        case .item:
            for view in [glyph, oldLabel, arrow, newColumn] as [NSView] { view.isHidden = false }
            moreLabel.isHidden = true
            glyph.kind = row.isFolder ? .folder : .file
            oldLabel.content = { [name = row.oldName] theme in
                batchRenameStyle(BatchRenameSheetLayout.Fonts.body, { $0.palette.textSecondary }).string(name, theme)
            }
            oldLabel.toolTip = row.oldName
            newColumn.show(row)
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let layout = BatchRenameSheetLayout.Preview.self
        let columns = layout.columns(width: Double(bounds.width))
        let padding = CGFloat(layout.rowPaddingVertical)
        if case .more = row.kind {
            moreLabel.frame = NSRect(
                x: CGFloat(layout.paddingHorizontal), y: padding,
                width: max(0, bounds.width - CGFloat(2 * layout.paddingHorizontal)), height: Self.nameLine)
            return
        }
        func centered(_ height: CGFloat) -> CGFloat { ((bounds.height - height) / 2).rounded() }
        let glyphSize = CGFloat(layout.glyphSize)
        glyph.frame = NSRect(x: CGFloat(columns[0].x), y: centered(glyphSize), width: glyphSize, height: glyphSize)
        let line = Self.nameLine
        oldLabel.frame = NSRect(
            x: CGFloat(columns[1].x), y: centered(line), width: CGFloat(columns[1].width), height: line)
        let arrowSize = CGFloat(layout.arrowSize)
        arrow.frame = NSRect(x: CGFloat(columns[2].x), y: centered(arrowSize), width: arrowSize, height: arrowSize)
        let newWidth = CGFloat(columns[3].width)
        let newHeight = BatchRenameNewNameView.height(of: row, width: newWidth)
        newColumn.frame = NSRect(x: CGFloat(columns[3].x), y: centered(newHeight), width: newWidth, height: newHeight)
    }
}

/// `.batch-rename-new`: the new name with its changed parts marked ("No change" for an item left as it is), and the
/// row's note under it.
@MainActor
final class BatchRenameNewNameView: NSView, TextStyleSource {
    let nameLabel = ThemedText(wrapping: false) { _ in NSAttributedString() }
    let noteLabel = ThemedText(wrapping: true) { _ in NSAttributedString() }
    private(set) var marks: [BatchRenameMarkView] = []
    private var row = BatchRenamePreviewRow(kind: .item)

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityIdentifier("batchRename.newName")
        nameLabel.setAccessibilityIdentifier("batchRename.name")
        nameLabel.lineBreakMode = .byTruncatingTail
        noteLabel.setAccessibilityIdentifier("batchRename.note")
        addSubview(nameLabel)
        addSubview(noteLabel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    var styleTextField: NSTextField? { nameLabel }

    static func noteStyle(_ tone: BatchRenameSheetText.NoteTone) -> TextStyle {
        batchRenameStyle(BatchRenameSheetLayout.Fonts.small) { theme in
            tone == .danger ? theme.palette.dangerText : theme.palette.textSecondary
        }
    }

    /// The column's height: the name's line, and the note's lines under it.
    static func height(of row: BatchRenamePreviewRow, width: CGFloat) -> CGFloat {
        var height = BatchRenameRowCell.nameLine
        if let note = row.note {
            let text = noteStyle(note.tone).string(note.text, AppearanceModel.shared.theme)
            let lines = text.boundingRect(
                with: NSSize(width: max(1, width), height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin]
            ).height
            let line = batchRenameLine(BatchRenameSheetLayout.Fonts.small)
            height += max(line, (lines / line).rounded() * line)
        }
        return height
    }

    func show(_ row: BatchRenamePreviewRow) {
        self.row = row
        let body = BatchRenameSheetLayout.Fonts.body
        if let name = row.newName {
            let segments = row.segments.isEmpty ? [NameSegment(text: name, changed: false)] : row.segments
            nameLabel.content = { theme in Self.attributedName(segments, tone: row.tone, theme: theme, size: body) }
            nameLabel.toolTip = name
        } else {
            nameLabel.content = { theme in
                batchRenameStyle(body, { $0.palette.textTertiary }).string(BatchRenameSheetText.noChange, theme)
            }
            nameLabel.toolTip = nil
        }
        if let note = row.note {
            noteLabel.isHidden = false
            noteLabel.content = { Self.noteStyle(note.tone).string(note.text, $0) }
            noteLabel.setAccessibilityValue(note.tone.rawValue)
        } else {
            noteLabel.isHidden = true
        }
        for mark in marks { mark.removeFromSuperview() }
        marks = []
        if row.newName != nil, row.tone != .skipped {
            var offset = 0.0
            for segment in row.segments {
                let width = Double(batchRenameTextWidthExact(segment.text, body))
                if segment.changed {
                    let mark = BatchRenameMarkView(danger: row.tone == .danger, start: offset, width: width)
                    addSubview(mark, positioned: .below, relativeTo: nameLabel)
                    marks.append(mark)
                }
                offset += width
            }
        }
        needsLayout = true
    }

    /// The name's pieces: the changed ones in the marks' color; struck through and dimmed for an item left as it is.
    static func attributedName(
        _ segments: [NameSegment], tone: BatchRenameSheetText.RowTone, theme: Theme, size: Double
    ) -> NSAttributedString {
        let text = NSMutableAttributedString()
        for segment in segments {
            let color: @MainActor (Theme) -> RGBA =
                switch (tone, segment.changed) {
                case (.skipped, _): { $0.palette.textTertiary }
                case (.danger, true): { $0.palette.dangerText }
                case (_, true): { $0.accent.batchRenameMarkText }
                default: { $0.palette.textPrimary }
                }
            var attributes = batchRenameStyle(size, color).attributes(theme)
            if tone == .skipped { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            text.append(NSAttributedString(string: segment.text, attributes: attributes))
        }
        return text
    }

    override func layout() {
        super.layout()
        let line = BatchRenameRowCell.nameLine
        nameLabel.frame = NSRect(x: 0, y: 0, width: bounds.width, height: line)
        let padding = CGFloat(BatchRenameSheetLayout.Preview.markPadding)
        for mark in marks {
            mark.frame = NSRect(
                x: CGFloat(mark.start) - padding, y: 0, width: CGFloat(mark.width) + 2 * padding, height: line)
        }
        if !noteLabel.isHidden {
            noteLabel.frame = NSRect(x: 0, y: line, width: bounds.width, height: max(0, bounds.height - line))
        }
    }
}

/// The width of a piece of text, unrounded (pieces of a name are laid end to end).
@MainActor
func batchRenameTextWidthExact(_ text: String, _ size: Double) -> CGFloat {
    (text as NSString).size(withAttributes: [.font: ThemeFonts.sans(size)]).width
}

/// `.batch-rename-changed`: the tint behind a changed part of a new name, 1 wider each side, rounded 3.
@MainActor
final class BatchRenameMarkView: NSView, ThemeApplying {
    let danger: Bool
    let start: Double
    let width: Double

    init(danger: Bool, start: Double, width: Double) {
        self.danger = danger
        self.start = start
        self.width = width
        super.init(frame: .zero)
        setAccessibilityIdentifier("batchRename.mark")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func applyTheme(_ theme: Theme) { needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let theme = AppearanceModel.shared.theme
        let radius = CGFloat(BatchRenameSheetLayout.Preview.markRadius)
        let fill =
            danger
            ? theme.palette.danger.withAlpha(BatchRenameSheetLayout.Preview.dangerMarkTint)
            : theme.accent.batchRenameMarkBg
        NSColor(fill).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
    }
}
