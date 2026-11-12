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
    /// What a search matched, in the whole name.
    var marks: [HighlightRange] = [] {
        didSet { needsDisplay = true }
    }
    var marksUnderlined = false {
        didSet { needsDisplay = true }
    }

    override var textWidth: CGFloat {
        SplitName.width(stringValue, extension: fileExtension, marks: marks, font: font)
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
        let y = (bounds.height - height) / 2
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

/// The root of a Compact List item: as wide as its icon and name, with the selection behind them in the layer's color
/// and corners, as `IconTileView` says. The pointer goes through to the collection.
final class CompactItemRootView: PassThroughView {
    var highlight: NSColor? {
        didSet { if highlight != oldValue { needsDisplay = true } }
    }
    var radius: CGFloat = 0 {
        didSet {
            if radius != oldValue { needsDisplay = true }
            dropView?.radius = radius
        }
    }
    /// What a drop on the item would do, while a drag is over it: drawn over the selection by a view that is there only
    /// as long as the drag is.
    var drop: (state: DropTargetState, theme: Theme)? {
        didSet {
            guard let drop else {
                dropView?.removeFromSuperview()
                dropView = nil
                return
            }
            let view = dropView ?? CompactDropView(frame: bounds)
            if dropView == nil {
                view.autoresizingMask = [.width, .height]
                addSubview(view, positioned: .below, relativeTo: nil)
                dropView = view
            }
            view.radius = radius
            view.drop = drop
        }
    }
    private var dropView: CompactDropView?

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = highlight?.cgColor
        layer?.cornerRadius = radius
    }
}

/// The drop highlight of a Compact List item, under its icon and name.
private final class CompactDropView: PassThroughView {
    var drop: (state: DropTargetState, theme: Theme)? {
        didSet { needsDisplay = true }
    }
    var radius: CGFloat = 0 {
        didSet { if radius != oldValue { needsDisplay = true } }
    }

    override func draw(_ dirtyRect: NSRect) {
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
    /// The copy or cut glyph after the name of an item on the clipboard.
    let markGlyph = ClipboardMarkGlyph(identifier: "compactList.item.clipboardMark")
    let tagDots = TagDotsView()
    /// Marks the item a drag would drop into, for automation.
    let dropMarker = GridMarkerView(id: "compactList.item.dropTarget")

    private(set) var path: String?
    private var layout = DesignTokens.flowList(density: .standard)
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
        root.addSubview(tagDots)
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
        // An item on the clipboard: its glyph after the name, and a cut one dimmed.
        let mark = host.clipboardMarks?.mark(for: entry.path)
        let wasMarked = !markGlyph.isHidden
        markGlyph.mark = mark
        markGlyph.color = ClipboardMarkGlyph.color(theme: host.theme, onSelection: marksOnSelection(pane, selected))
        label.alphaValue = mark == .cut ? CGFloat(ClipboardLayout.Mark.cutLabelAlpha) : 1
        iconView.alphaValue = entry.isHidden ? CGFloat(HiddenItemLook.iconAlpha) : 1
        let dropState = host.dropState(for: entry.path)
        root.drop = dropState.map { ($0, host.theme) }
        dropMarker.isHidden = dropState == nil || dropState == .invalid
        DropHighlight.setWiggle(iconView, on: dropState == .springing)
        let tagColors = host.tagColors(for: entry)
        let tagsChanged = tagDots.colors != tagColors
        tagDots.colors = tagColors
        if wasMarked != (mark != nil) || tagsChanged { layoutParts() }
    }

    /// A selected item in the focused list of the window in front: its glyph and flash take the text's color.
    private func marksOnSelection(_ pane: ItemGridPane, _ selected: Bool) -> Bool {
        selected && pane.paneFocused && pane.windowActive
    }

    /// The item was just copied or cut: its mark flashes.
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
        let dots = tagDots.isHidden ? 0 : tagDots.dotsWidth + TagDotsView.gap
        let glyph = markGlyph.isHidden ? 0 : ClipboardMarkGlyph.size + CGFloat(ClipboardLayout.Mark.gap)
        if dots + glyph > 0 {
            // The tags and the glyph follow the name (the item's 8 pt gap); a name that does not fit is shortened, and
            // they keep their size.
            width = max(0, min(ceil(label.textWidth), width - dots - glyph))
            if dots > 0 {
                tagDots.frame = NSRect(
                    x: x + width + TagDotsView.gap, y: 0, width: tagDots.dotsWidth, height: view.bounds.height)
            }
            if glyph > 0 {
                let size = ClipboardMarkGlyph.size
                markGlyph.frame = NSRect(
                    x: x + width + dots + CGFloat(ClipboardLayout.Mark.gap), y: (view.bounds.height - size) / 2,
                    width: size, height: size)
            }
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
