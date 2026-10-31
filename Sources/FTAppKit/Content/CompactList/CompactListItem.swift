// Port of FlowListItem (apps/desktop/src/renderer/components/ContentPane.tsx:1406-1448), FileNameLabel (:2422-2445) and
// the `.flow-item` rules of styles.css:2598-2700 and 4483-4500, with its clipboard mark and drop state (P5-08)
import AppKit
import FTFileSystem
import FTFoundation

/// A name in the Compact List: the stem, which ends in an ellipsis when the column is too narrow, and the extension
/// after it, which always shows (in the softer selection text on a selected item). The field holds the whole name.
final class CompactNameLabel: ListLabel {
    var fileExtension = "" {
        didSet { needsDisplay = true }
    }
    var extensionColor: NSColor? {
        didSet { needsDisplay = true }
    }
    /// What a search matched, in the whole name (P5-07).
    var marks: [HighlightRange] = [] {
        didSet { needsDisplay = true }
    }
    var marksUnderlined = false {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let parts = DisplayName.split(stringValue, extension: fileExtension)
        let font = font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let color = textColor ?? .labelColor
        let height = lineHeight
        if !marks.isEmpty {
            MarkedName.drawSplitName(
                stem: parts.stem, suffix: parts.extensionSuffix, ranges: marks, in: bounds, of: self,
                lineHeight: height,
                font: font, color: color, suffixColor: extensionColor ?? color, underlined: marksUnderlined)
            return
        }
        let y = TextBaseline.lineTop((bounds.height - height) / 2, font: font, in: self)
        let plain: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        var suffix = plain
        suffix[.foregroundColor] = extensionColor ?? color
        let suffixWidth = ceil((parts.extensionSuffix as NSString).size(withAttributes: plain).width)
        let stemRoom = max(0, bounds.width - suffixWidth)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        var stemAttributes = plain
        stemAttributes[.paragraphStyle] = paragraph
        let stemWidth = ceil((parts.stem as NSString).size(withAttributes: plain).width)
        let drawn = min(stemWidth, stemRoom)
        (parts.stem as NSString).draw(
            with: NSRect(x: 0, y: y, width: drawn, height: height),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: stemAttributes)
        if !parts.extensionSuffix.isEmpty {
            (parts.extensionSuffix as NSString).draw(
                with: NSRect(x: drawn, y: y, width: suffixWidth, height: height), options: [.usesLineFragmentOrigin],
                attributes: suffix)
        }
    }
}

/// The root of a Compact List item (`.flow-item`): as wide as its icon and name, with the selection behind them. The
/// pointer goes through to the collection.
final class CompactItemRootView: PassThroughView {
    var highlight: NSColor? {
        didSet { needsDisplay = true }
    }
    var radius: CGFloat = 0
    /// What a drop on the item would do, while a drag is over it (`data-drop-target-state`).
    var drop: (state: DropTargetState, theme: Theme)? {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        if let highlight {
            highlight.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        }
        if let drop { DropHighlight.drawRow(drop.state, in: bounds, radius: radius, theme: drop.theme) }
    }
}

/// An item of the Compact List: the file's icon and its name.
final class CompactListItem: NSCollectionViewItem, GridItemView, GridItemDragging {
    static let identifier = NSUserInterfaceItemIdentifier("compactList.item")

    let root = CompactItemRootView()
    let iconView = NSImageView()
    let label = CompactNameLabel()
    let selectedMarker = GridMarkerView(id: "compactList.item.selected")
    /// The copy or cut glyph after the name of an item on the clipboard (P5-08).
    let markGlyph = ClipboardMarkGlyph(identifier: "compactList.item.clipboardMark")
    /// Marks the item a drag would drop into, for the capture.
    let dropMarker = GridMarkerView(id: "compactList.item.dropTarget")

    private(set) var path: String?
    private var layout = DesignTokens.flowList(density: .comfortable)
    private var iconRequest: LoadHandle?

    override func loadView() {
        root.setAccessibilityIdentifier("compactList.item")
        root.setAccessibilityRole(.cell)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.isEditable = false
        iconView.unregisterDraggedTypes()
        iconView.setAccessibilityIdentifier("compactList.item.icon")
        label.setAccessibilityIdentifier("compactList.item.name")
        selectedMarker.source = label
        dropMarker.source = label
        root.addSubview(iconView)
        root.addSubview(label)
        root.addSubview(markGlyph)
        root.addSubview(selectedMarker)
        root.addSubview(dropMarker)
        view = root
        textField = label
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        iconRequest?.cancel()
        iconRequest = nil
        path = nil
    }

    func configure(entry: DirectoryEntry, pane: CompactListViewController) {
        guard let host = pane.host else { return }
        let changed = path != entry.path
        path = entry.path
        layout = pane.layout
        root.setAccessibilityLabel(entry.name)
        // `title={entry.name}`: the whole name, for one shortened in the middle.
        root.toolTip = entry.name
        root.radius = CGFloat(pane.style.radius)
        label.font = pane.nameFont
        label.stringValue = entry.name
        label.fileExtension = entry.fileExtension
        label.marks = host.search?.match(in: entry.name).map { [$0] } ?? []
        if changed || iconView.image == nil {
            iconRequest?.cancel()
            iconRequest = GridIcons.show(entry, in: iconView, host: host) { [weak self] in
                self?.path == entry.path
            }
        }
        applyLook(pane: pane, entry: entry)
        layoutParts()
    }

    func applyLook(pane: CompactListViewController, entry: DirectoryEntry) {
        guard let host = pane.host else { return }
        let renaming = pane.renamingPath == entry.path
        let selected = pane.isSelected(entry.path) || renaming
        // A name being edited is drawn as selected in a pane without the keyboard (`active inactive renaming`).
        let colors = GridSelectionColors.make(
            theme: host.theme, selected: selected, paneFocused: pane.paneFocused && !renaming,
            windowActive: pane.windowActive)
        root.highlight = colors.background.map { NSColor($0) }
        label.textColor = NSColor(colors.text)
        label.extensionColor = NSColor(colors.softText)
        label.marksUnderlined = selected && pane.paneFocused && pane.windowActive
        label.isHidden = renaming
        selectedMarker.isHidden = !selected
        // An item on the clipboard: its glyph after the name, and a cut one dimmed (P5-08).
        let mark = host.clipboardMarks?.mark(for: entry.path)
        let wasMarked = !markGlyph.isHidden
        markGlyph.mark = mark
        markGlyph.color = ClipboardMarkGlyph.color(theme: host.theme, onSelection: marksOnSelection(pane, selected))
        label.alphaValue = mark == .cut ? CGFloat(ClipboardLayout.Mark.cutLabelAlpha) : 1
        let dropState = host.dropState(for: entry.path)
        root.drop = dropState.map { ($0, host.theme) }
        dropMarker.isHidden = dropState == nil || dropState == .invalid
        DropHighlight.setWiggle(iconView, on: dropState == .springing)
        if wasMarked != (mark != nil) { layoutParts() }
    }

    /// `.flow-item.active:not(.inactive)`: a selected item in the focused list of the window in front; its glyph and
    /// flash take the text's color.
    private func marksOnSelection(_ pane: ItemGridPane, _ selected: Bool) -> Bool {
        selected && pane.paneFocused && pane.windowActive
    }

    /// The item was just copied or cut (`.clipboard-flash`).
    func flashClipboardMark(in pane: ItemGridPane) {
        guard let path, let host = pane.host, host.clipboardMarks?.mark(for: path) != nil else { return }
        let selected = pane.isSelected(path)
        ClipboardFlash.flash(
            root, color: ClipboardMarkGlyph.color(theme: host.theme, onSelection: marksOnSelection(pane, selected)),
            radius: root.radius)
    }

    /// Where the icon and the name are drawn, in `view`'s coordinates, for the drag's images.
    func dragPlacement(in view: NSView, visible: NSRect) -> FileDragPlacement {
        let icon = iconView.convert(iconView.bounds, to: view)
        var nameRect = label.convert(label.bounds, to: view)
        nameRect.size.width = min(nameRect.width, ceil(label.textWidth))
        return FileDragPlacement(
            iconRect: icon, nameRect: nameRect, nameFontSize: Double(label.font?.pointSize ?? 13), nameCentered: false,
            thumbnail: false, inSight: FileDragImages.isInSight(icon, within: [visible]))
    }

    private func layoutParts() {
        let style = FlowItemStyle.make()
        let left = style.borderWidth + style.paddingInline
        let icon = layout.iconSize
        iconView.frame = NSRect(x: left, y: (view.bounds.height - icon) / 2, width: icon, height: icon)
        let x = left + icon + layout.iconGap
        let height = label.lineHeight
        var width = max(0, view.bounds.width - x - left)
        if !markGlyph.isHidden {
            // The glyph follows the name (the item's 8 pt gap); a name that does not fit is shortened, and the glyph
            // keeps its size.
            let size = ClipboardMarkGlyph.size
            let gap = CGFloat(ClipboardLayout.Mark.gap)
            width = max(0, min(ceil(label.textWidth), width - gap - size))
            markGlyph.frame = NSRect(
                x: x + width + gap, y: (view.bounds.height - size) / 2, width: size, height: size)
        }
        label.frame = NSRect(x: x, y: (view.bounds.height - height) / 2, width: width, height: height)
        selectedMarker.frame = view.bounds
        dropMarker.frame = view.bounds
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        layoutParts()
    }

    // MARK: GridItemView

    func takesClick(at point: NSPoint) -> Bool { view.bounds.contains(point) }

    var measuredSize: DragSelectionSize? {
        DragSelectionSize(width: Double(view.bounds.width), height: Double(view.bounds.height))
    }
}
