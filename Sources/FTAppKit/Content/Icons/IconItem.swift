import AppKit
import FTFileSystem
import FTFoundation

/// The previews of icon view, one cache for the app.
@MainActor
enum IconThumbnails {
    static let store = ThumbnailStore()
}

/// The name under an icon: centred lines, at most two, on the selection's pill when the item is selected. The field
/// holds the label's text (the name as shortened) and draws it itself.
final class IconNameLabel: ListLabel {
    var density = Density.standard
    var pillColor: NSColor? {
        didSet { needsDisplay = true }
    }
    /// The lines the text wraps into.
    var lines: [String] = [] {
        didSet { needsDisplay = true }
    }
    /// What a search matched, in the label's text: no padding of its own under an icon.
    var marks: [HighlightRange] = [] {
        didSet { needsDisplay = true }
    }
    var marksUnderlined = false {
        didSet { needsDisplay = true }
    }
    /// The tag dots at the start of the first line, centered with it.
    let tagDots = TagDotsView()
    var firstLineIndent: CGFloat {
        tagDots.colors.isEmpty ? 0 : tagDots.dotsWidth + TagDotsView.gap
    }

    /// Puts the dots before the first line, as centered with them.
    func placeTagDots() {
        guard !tagDots.colors.isEmpty, let font, let first = lines.first else { return }
        let layout = DesignTokens.iconGrid(density: density)
        let inset = CGFloat(layout.labelPaddingHorizontal)
        let room = max(0, bounds.width - inset * 2)
        let indent = firstLineIndent
        let text = min((first as NSString).size(withAttributes: [.font: font]).width, room - indent)
        tagDots.frame = NSRect(
            x: inset + max(0, (room - indent - text) / 2),
            y: CGFloat(layout.labelPaddingVertical) + (CGFloat(layout.labelLineHeight) - TagDotsView.diameter) / 2,
            width: tagDots.dotsWidth, height: TagDotsView.diameter)
    }

    override func draw(_ dirtyRect: NSRect) {
        let layout = DesignTokens.iconGrid(density: density)
        if let pillColor {
            pillColor.setFill()
            let radius = CGFloat(layout.labelRadius)
            NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        }
        guard let font else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: textColor ?? .labelColor, .paragraphStyle: paragraph,
        ]
        let lineHeight = CGFloat(layout.labelLineHeight)
        // Each line is the layout's label line height, with the glyphs in its middle.
        let glyphHeight = font.ascender - font.descender
        let halfLeading = (lineHeight - glyphHeight) / 2
        let inset = CGFloat(layout.labelPaddingHorizontal)
        let width = max(0, bounds.width - inset * 2)
        var shown = Array(lines.prefix(IconLabel.lineCount))
        // What does not fit in two lines ends the second line with an ellipsis.
        if lines.count > IconLabel.lineCount, !shown.isEmpty {
            shown[shown.count - 1] = lines[(IconLabel.lineCount - 1)...].joined()
        }
        var lineStart = 0
        for (number, line) in shown.enumerated() {
            let top = CGFloat(layout.labelPaddingVertical) + CGFloat(number) * lineHeight + halfLeading
            defer { lineStart += line.utf16.count }
            // The first line and the dots before it are centered as one.
            let indent = number == 0 ? firstLineIndent : 0
            let lineX = inset + indent
            let lineRoom = max(0, width - indent)
            let lineMarks = NameHighlight.marks(in: line, ranges: marks, offset: lineStart)
            if !lineMarks.isEmpty {
                let marked = MarkedName.Line(line, marks: lineMarks, attributes: attributes, padding: 0)
                let lineWidth = min(lineRoom, marked.width)
                MarkedName.draw(
                    marked, at: NSPoint(x: lineX + (lineRoom - lineWidth) / 2, y: top), width: lineWidth,
                    lineHeight: glyphHeight, font: font, color: textColor ?? .labelColor,
                    underlined: marksUnderlined, truncates: true, in: self)
                continue
            }
            (line as NSString).draw(
                with: NSRect(
                    x: lineX, y: top, width: lineRoom, height: glyphHeight),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
        }
    }
}

/// A Quick Look preview that keeps its file's proportions; a photo or a video frame is framed with a hairline and a
/// soft shadow.
final class IconThumbnailView: PassThroughView {
    private let imageLayer = CALayer()
    private let ring = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        imageLayer.contentsGravity = .resize
        imageLayer.masksToBounds = true
        layer?.addSublayer(ring)
        layer?.addSublayer(imageLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private(set) var isFramed = false
    private var shadowDrop: CGFloat = 0

    func show(_ picture: ThumbnailPicture, theme: Theme, style: IconItemStyle) {
        isFramed = picture.isOpaque
        setAccessibilityIdentifier(isFramed ? "icons.item.thumbnail" : "")
        // At once: layers of their own fade a new picture and frame in over a quarter of a second otherwise.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        imageLayer.contents = picture.image
        let radius = isFramed ? CGFloat(style.thumbnailRadius) : 0
        imageLayer.cornerRadius = radius
        let hairline = CGFloat(style.thumbnailHairlineWidth)
        ring.isHidden = !isFramed
        ring.cornerRadius = radius + hairline
        ring.borderWidth = hairline
        ring.borderColor = NSColor(theme.palette.textPrimary.withAlpha(style.thumbnailHairlineAlpha)).cgColor
        layer?.shadowOpacity = isFramed ? Float(style.thumbnailShadowAlpha) : 0
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowRadius = CGFloat(style.thumbnailShadowBlur) / 2
        shadowDrop = CGFloat(style.thumbnailShadowOffsetY)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = bounds
        let hairline = ring.borderWidth
        ring.frame = bounds.insetBy(dx: -hairline, dy: -hairline)
        // The shadow falls down by its offset, whichever way the layer counts y.
        let down: CGFloat = (layer?.contentsAreFlipped() ?? false) ? 1 : -1
        layer?.shadowOffset = CGSize(width: 0, height: shadowDrop * down)
        layer?.shadowPath =
            isFramed
            ? CGPath(
                roundedRect: bounds, cornerWidth: imageLayer.cornerRadius,
                cornerHeight: imageLayer.cornerRadius, transform: nil) : nil
        CATransaction.commit()
    }
}

/// The clipboard badge: an 18 pt circle on the corner of the picture with the copy or the scissors glyph.
final class ClipboardBadgeView: PassThroughView {
    var mark: ContentClipboardMark = .copy {
        didSet { needsDisplay = true }
    }
    var theme = AppearanceModel.shared.theme {
        didSet { needsDisplay = true }
    }
    var style = IconItemStyle.make(density: .standard)

    override func draw(_ dirtyRect: NSRect) {
        let border = CGFloat(style.badgeBorderWidth)
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: border / 2, dy: border / 2))
        NSColor(theme.palette.bgBase).setFill()
        circle.fill()
        circle.lineWidth = border
        NSColor(theme.accent.solidButton.withAlpha(style.badgeBorderAlpha)).setStroke()
        circle.stroke()
        let glyph = CGFloat(style.badgeGlyphSize)
        let box = NSRect(x: (bounds.width - glyph) / 2, y: (bounds.height - glyph) / 2, width: glyph, height: glyph)
        SymbolGlyph.draw(
            (mark == .cut ? CommandIcon.cut : .copy).symbolName, in: box, color: NSColor(theme.accent.solidButton))
    }
}

/// The tile the icon sits on: a backdrop of the text colour while the item is selected, shown by the layer's own color
/// and corners. AppKit visits every view that draws itself with `draw(_:)`, hidden or not, on each frame of a scroll,
/// and draws one that may draw past its bounds again: the items' views draw only what needs drawing (their names).
final class IconTileView: PassThroughView {
    var backdrop: NSColor? {
        didSet { if backdrop != oldValue { needsDisplay = true } }
    }
    var radius: CGFloat = 0 {
        didSet { if radius != oldValue { needsDisplay = true } }
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = backdrop?.cgColor
        layer?.cornerRadius = radius
    }
}

/// The root of an item: the pointer goes through to the collection, which asks the item whether a press is on its tile
/// or its name. It shows what a drop on the item would do while a drag is over it, in its layer's color and border, as
/// the tile does.
final class IconItemRootView: PassThroughView {
    var drop: DropTargetState? {
        didSet { if drop != oldValue { needsDisplay = true } }
    }
    var theme = AppearanceModel.shared.theme {
        didSet { if drop != nil, theme != oldValue { needsDisplay = true } }
    }
    var radius: CGFloat = 0 {
        didSet { if radius != oldValue { needsDisplay = true } }
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        let look = drop.map { DropHighlight.iconLook($0, theme: theme) }
        layer.backgroundColor = look.map { NSColor($0.fill).cgColor }
        layer.borderColor = look.map { NSColor($0.edge).cgColor }
        layer.borderWidth = look?.edgeWidth ?? 0
        layer.cornerRadius = radius
    }
}

/// An item of the Icon view.
final class IconItem: NSCollectionViewItem, GridItemView, GridItemDragging {
    static let identifier = NSUserInterfaceItemIdentifier("icons.item")

    let root = IconItemRootView()
    let tile = IconTileView()
    /// The box the icon or the preview is drawn in.
    let iconBox = PassThroughView()
    let iconView = NSImageView()
    let thumbnail = IconThumbnailView()
    let badge = ClipboardBadgeView()
    let label = IconNameLabel()
    let pill = GridMarkerView(id: "icons.item.pill")
    /// Marks the item a drag would drop into, for automation.
    let dropMarker = GridMarkerView(id: "icons.item.dropTarget")
    /// The whole name, for what reads the item's text field (a scenario's `select` step).
    private let nameField = NSTextField(labelWithString: "")

    private(set) var path: String?
    private var density = Density.standard
    /// The pane's grid and look, at its icon size.
    private var layout = DesignTokens.iconGrid(density: .standard)
    private var style = IconItemStyle.make(density: .standard)
    private var iconRequest: LoadHandle?
    private var thumbnailRequest: LoadHandle?
    private var hasThumbnail = false
    /// The picture fills the item's place, whatever its shape (the Previews view).
    private var fillsPlace = false

    override func loadView() {
        root.setAccessibilityIdentifier("icons.item")
        root.setAccessibilityRole(.cell)
        tile.setAccessibilityIdentifier("icons.item.tile")
        iconBox.setAccessibilityIdentifier("icons.item.icon")
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.isEditable = false
        iconView.unregisterDraggedTypes()
        label.setAccessibilityIdentifier("icons.item.name")
        label.usesSingleLineMode = false
        label.cell?.wraps = true
        badge.setAccessibilityIdentifier("icons.item.badge")
        badge.isHidden = true
        thumbnail.isHidden = true
        pill.source = label
        dropMarker.source = label
        iconBox.addSubview(iconView)
        iconBox.addSubview(thumbnail)
        tile.addSubview(iconBox)
        root.addSubview(tile)
        root.addSubview(label)
        label.addSubview(pill)
        label.addSubview(label.tagDots)
        root.addSubview(dropMarker)
        view = root
        textField = nameField
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        iconRequest?.cancel()
        iconRequest = nil
        // A preview not loaded yet is dropped from the queue when its item is reused.
        thumbnailRequest?.cancel()
        thumbnailRequest = nil
        path = nil
    }

    // MARK: Showing an entry

    func configure(entry: DirectoryEntry, pane: IconViewController) {
        guard let host = pane.host else { return }
        let changed = path != entry.path
        path = entry.path
        density = pane.density
        layout = pane.layout
        style = pane.style
        fillsPlace = pane.picturesFillTheirPlace
        nameField.stringValue = entry.name
        root.setAccessibilityLabel(entry.name)
        // `title={entry.name}`: the whole name, for one shortened in the middle.
        root.toolTip = pane.toolTip(for: entry)
        label.tagDots.colors = host.tagColors(for: entry)
        fitName(entry, host: host, layout: layout)
        tile.radius = CGFloat(style.tileRadius)
        if changed || iconView.image == nil {
            iconRequest?.cancel()
            iconRequest = GridIcons.show(entry, in: iconView, host: host) { [weak self] in
                self?.path == entry.path
            }
        }
        loadThumbnail(entry, pane: pane)
        applyLook(pane: pane, entry: entry)
        layoutParts()
    }

    /// The name's lines, which go around the tag dots.
    private func fitName(_ entry: DirectoryEntry, host: any ContentPaneHost, layout: IconGridLayout) {
        let indent = label.firstLineIndent
        let fitted = IconLabelText.fit(
            name: entry.name, extension: entry.fileExtension, layout: layout, firstLineIndent: indent)
        label.density = density
        label.font = IconLabelText.font(layout)
        label.stringValue = fitted
        label.lines = IconLabelText.lines(fitted, layout: layout, firstLineIndent: indent)
        // The match is marked in what is left of a name shortened in the middle.
        label.marks = NameHighlight.mapToLabel(name: entry.name, label: fitted, marks: host.nameMarks(entry.name))
        labelTextWidth = IconLabelText.width(fitted, layout: layout) + Double(indent)
    }

    private var labelTextWidth = 0.0

    private func loadThumbnail(_ entry: DirectoryEntry, pane: IconViewController) {
        thumbnailRequest?.cancel()
        thumbnailRequest = nil
        let theme = pane.host?.theme ?? AppearanceModel.shared.theme
        let style = pane.style
        thumbnailRequest = pane.thumbnailStore.load(
            path: entry.path, kind: entry.iconEntry.kind, size: pane.thumbnailPixelSize, listing: pane.listing
        ) { [weak self] picture in
            guard let self, self.path == entry.path else { return }
            if let picture {
                self.hasThumbnail = true
                self.thumbnail.show(picture, theme: theme, style: style)
                self.thumbnailSize = picture.image.size
            } else {
                self.hasThumbnail = false
                self.thumbnail.setAccessibilityIdentifier("")
            }
            self.thumbnail.isHidden = !self.hasThumbnail
            self.iconView.isHidden = self.hasThumbnail
            self.layoutParts()
        }
    }

    private var thumbnailSize = NSSize.zero

    /// Draws the selection, the focus and the clipboard badge.
    func applyLook(pane: IconViewController, entry: DirectoryEntry) {
        guard let host = pane.host else { return }
        let theme = host.theme
        let renaming = pane.renamingPath == entry.path
        let selected = pane.isSelected(entry.path) || renaming
        // A name being edited is drawn as selected in a pane without the keyboard (`active inactive renaming`).
        let colors = GridSelectionColors.make(
            theme: theme, selected: selected, paneFocused: pane.paneFocused && !renaming,
            windowActive: pane.windowActive)
        tile.backdrop =
            selected ? NSColor(theme.palette.textPrimary.withAlpha(pane.style.selectedTileAlpha)) : nil
        label.pillColor = colors.background.map { NSColor($0) }
        label.textColor = NSColor(colors.text)
        label.marksUnderlined = selected && pane.paneFocused && pane.windowActive
        label.isHidden = renaming
        pill.isHidden = !selected || renaming
        // The badge is in the item only while it shows, as `IconTileView` says.
        if let mark = host.clipboardMark(for: entry.path) {
            badge.mark = mark
            badge.theme = theme
            badge.style = pane.style
            badge.isHidden = false
            if badge.superview == nil { root.addSubview(badge, positioned: .above, relativeTo: tile) }
        } else {
            badge.isHidden = true
            badge.removeFromSuperview()
        }
        let tagColors = host.tagColors(for: entry)
        if label.tagDots.colors != tagColors {
            label.tagDots.colors = tagColors
            fitName(entry, host: host, layout: pane.layout)
            layoutParts()
        }
        // Cut items look taken out already: the name and the picture (not its badge) dimmed.
        let cut = host.clipboardMark(for: entry.path) == .cut
        label.alphaValue = cut ? CGFloat(ClipboardLayout.Mark.cutLabelAlpha) : 1
        iconBox.alphaValue =
            cut ? CGFloat(ClipboardLayout.Mark.cutIconAlpha) : entry.isHidden ? CGFloat(HiddenItemLook.iconAlpha) : 1
        let dropState = host.dropState(for: entry.path)
        root.radius = CGFloat(pane.style.tileRadius)
        root.theme = theme
        root.drop = dropState
        dropMarker.isHidden = dropState == nil || dropState == .invalid
        DropHighlight.setWiggle(iconBox, on: dropState == .springing)
        if hasThumbnail, !thumbnail.isHidden, let picture = pane.thumbnailStore.loadedPicture(forPath: entry.path) {
            thumbnail.show(picture, theme: theme, style: pane.style)
        }
    }

    // MARK: Layout

    private func layoutParts() {
        if fillsPlace {
            layoutFillingThePlace()
            return
        }
        let tileFrame = layout.tileFrame(style: style)
        tile.frame = NSRect(x: tileFrame.x, y: tileFrame.y, width: tileFrame.width, height: tileFrame.height)
        let inset = layout.iconInset
        iconBox.frame = NSRect(x: inset, y: inset, width: layout.iconSize, height: layout.iconSize)
        iconView.frame = iconBox.bounds
        if hasThumbnail, thumbnailSize.width > 0, thumbnailSize.height > 0 {
            // Shrunk to fit the box, never enlarged.
            let side = layout.iconSize
            let scale = min(1, side / Double(thumbnailSize.width), side / Double(thumbnailSize.height))
            let width = Double(thumbnailSize.width) * scale
            let height = Double(thumbnailSize.height) * scale
            thumbnail.frame = NSRect(x: (side - width) / 2, y: (side - height) / 2, width: width, height: height)
        }
        let labelFrame = layout.labelFrame(textWidth: labelTextWidth, lines: label.lines.count)
        label.frame = NSRect(x: labelFrame.x, y: labelFrame.y, width: labelFrame.width, height: labelFrame.height)
        pill.frame = label.bounds
        label.placeTagDots()
        dropMarker.frame = root.bounds
        let badgeSize = layout.clipboardBadgeSize
        let offset = layout.clipboardBadgeOffset
        // The badge sits on the tile's top right corner, reaching past it by the offset.
        badge.frame = NSRect(
            x: tileFrame.maxX - offset - badgeSize, y: tileFrame.y + offset, width: badgeSize, height: badgeSize)
    }

    /// The Previews view: the picture as large as its place allows in its own shape (an icon at most two thirds of
    /// it), the tile hugging it, and the name right under it, the two together in the middle of the place.
    private func layoutFillingThePlace() {
        let box = PreviewGrid.pictureBox(layout)
        let picture: (width: Double, height: Double)
        if hasThumbnail, thumbnailSize.width > 0, thumbnailSize.height > 0 {
            picture = PreviewGrid.fitted(
                (Double(thumbnailSize.width), Double(thumbnailSize.height)), in: box)
        } else {
            let side = min(box.width, box.height) * 2 / 3
            picture = (side, side)
        }
        let labelFrame = layout.labelFrame(textWidth: labelTextWidth, lines: label.lines.count)
        let inset = 4.0
        let placeHeight = layout.rowHeight - style.heightInset
        let together = picture.height + inset * 2 + layout.labelGap + labelFrame.height
        let top = max(0, (placeHeight - together) / 2)
        let tileFrame = GridRect(
            x: (layout.cellMinWidth - picture.width) / 2 - inset, y: top, width: picture.width + inset * 2,
            height: picture.height + inset * 2)
        tile.frame = NSRect(x: tileFrame.x, y: tileFrame.y, width: tileFrame.width, height: tileFrame.height)
        iconBox.frame = NSRect(x: inset, y: inset, width: picture.width, height: picture.height)
        iconView.frame = iconBox.bounds
        thumbnail.frame = iconBox.bounds
        label.frame = NSRect(
            x: labelFrame.x, y: tileFrame.maxY + layout.labelGap, width: labelFrame.width, height: labelFrame.height)
        pill.frame = label.bounds
        label.placeTagDots()
        dropMarker.frame = root.bounds
        let badgeSize = layout.clipboardBadgeSize
        let offset = layout.clipboardBadgeOffset
        badge.frame = NSRect(
            x: tileFrame.maxX - offset - badgeSize, y: tileFrame.y + offset, width: badgeSize, height: badgeSize)
    }

    /// Where the name is in the item, for the rename field over it.
    var nameFrame: NSRect { label.frame }

    override func viewDidLayout() {
        super.viewDidLayout()
        layoutParts()
    }

    // MARK: Clipboard and drags

    /// The item was just copied or cut: the whole item flashes in the accent.
    func flashClipboardMark(in pane: ItemGridPane) {
        guard let path, let host = pane.host, host.clipboardMarks?.mark(for: path) != nil else { return }
        ClipboardFlash.flash(
            root, color: ClipboardMarkGlyph.color(theme: host.theme, onSelection: false),
            radius: CGFloat(IconItemStyle.make(density: density).tileRadius))
    }

    /// Where the picture and the name are drawn, in `view`'s coordinates, for the drag's images.
    func dragPlacement(in view: NSView, visible: NSRect) -> FileDragPlacement {
        // The box the icon or the preview is drawn in.
        let icon = iconBox.convert(iconBox.bounds, to: view)
        return FileDragPlacement(
            iconRect: icon, nameRect: label.convert(label.bounds, to: view),
            nameFontSize: Double(label.font?.pointSize ?? 12), nameCentered: true,
            thumbnail: hasThumbnail && !thumbnail.isHidden,
            inSight: FileDragImages.isInSight(icon, within: [visible]))
    }

    // MARK: GridItemView

    func takesClick(at point: NSPoint) -> Bool {
        tile.frame.contains(point) || (!label.isHidden && label.frame.contains(point))
    }

    var measuredSize: DragSelectionSize? {
        DragSelectionSize(width: Double(label.frame.width), height: Double(label.frame.height))
    }
}
