// Port of IconGridItem and IconLabel (apps/desktop/src/renderer/components/IconGridView.tsx:439-521), FileThumbnail
// (lib/fileThumbnails.tsx:134-160), the badge of ClipboardMarkIcon (lib/clipboardMarks.tsx) and their rules in
// styles.css:7767-7782 and 7899-8111
import AppKit
import FTFileSystem
import FTFoundation

/// The previews of icon view, one cache for the app (`thumbnailCache` of `fileThumbnails.tsx`).
@MainActor
enum IconThumbnails {
    static let store = ThumbnailStore()
}

/// The name under an icon (`.icon-item-label`): centred lines, at most two, on the selection's pill when the item is
/// selected. The field holds the label's text (the name as shortened) and draws it itself.
final class IconNameLabel: ListLabel {
    var density = Density.comfortable
    var pillColor: NSColor? {
        didSet { needsDisplay = true }
    }
    /// The lines the text wraps into.
    var lines: [String] = [] {
        didSet { needsDisplay = true }
    }
    /// What a search matched, in the label's text (P5-07): no padding of its own under an icon.
    var marks: [HighlightRange] = [] {
        didSet { needsDisplay = true }
    }
    var marksUnderlined = false {
        didSet { needsDisplay = true }
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
        // `line-height: 16px`: the glyphs sit in the middle of each line, as the browser places them.
        let glyphHeight = font.ascender - font.descender
        let halfLeading = (lineHeight - glyphHeight) / 2
        let inset = CGFloat(layout.labelPaddingHorizontal)
        let width = max(0, bounds.width - inset * 2)
        var shown = Array(lines.prefix(IconLabel.lineCount))
        // `-webkit-line-clamp: 2`: what does not fit ends the second line with an ellipsis.
        if lines.count > IconLabel.lineCount, !shown.isEmpty {
            shown[shown.count - 1] = lines[(IconLabel.lineCount - 1)...].joined()
        }
        var lineStart = 0
        for (number, line) in shown.enumerated() {
            let top = CGFloat(layout.labelPaddingVertical) + CGFloat(number) * lineHeight + halfLeading
            defer { lineStart += line.utf16.count }
            let lineMarks = NameHighlight.marks(in: line, ranges: marks, offset: lineStart)
            if !lineMarks.isEmpty {
                let marked = MarkedName.Line(line, marks: lineMarks, attributes: attributes, padding: 0)
                let lineWidth = min(width, marked.width)
                MarkedName.draw(
                    marked, at: NSPoint(x: inset + (width - lineWidth) / 2, y: top), width: lineWidth,
                    lineHeight: glyphHeight, font: font, color: textColor ?? .labelColor,
                    underlined: marksUnderlined, truncates: true, in: self)
                continue
            }
            (line as NSString).draw(
                with: NSRect(
                    x: inset, y: TextBaseline.lineTop(top, font: font, in: self), width: width, height: glyphHeight),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
        }
    }
}

/// A Quick Look preview that keeps its file's proportions; a photo or a video frame is framed with a hairline and a
/// soft shadow (`.file-thumbnail-img.framed`).
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
        // `0 1px 2px`: down by the offset, whichever way the layer counts y.
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

/// `.clipboard-mark-badge`: an 18 pt circle on the corner of the picture with the copy or the scissors glyph.
final class ClipboardBadgeView: PassThroughView {
    var mark: ContentClipboardMark = .copy {
        didSet { needsDisplay = true }
    }
    var theme = AppearanceModel.shared.theme {
        didSet { needsDisplay = true }
    }
    var style = IconItemStyle.make(density: .comfortable)

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
        ToolbarGlyph.draw(
            mark == .cut ? .cut : .copy, in: box, strokeWidth: DesignTokens.toolbar.iconStrokeWidth,
            color: NSColor(theme.accent.solidButton), flipped: true)
    }
}

/// The tile the icon sits on (`.icon-item-image`): a backdrop of the text colour while the item is selected.
final class IconTileView: PassThroughView {
    var backdrop: NSColor? {
        didSet { needsDisplay = true }
    }
    var radius: CGFloat = 0

    override func draw(_ dirtyRect: NSRect) {
        guard let backdrop else { return }
        backdrop.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
    }
}

/// The root of an item (`.icon-item`): the pointer goes through to the collection, which asks the item whether a press
/// is on its tile or its name. It draws what a drop on the item would do while a drag is over it (P5-08).
final class IconItemRootView: PassThroughView {
    var drop: (state: DropTargetState, theme: Theme)? {
        didSet { needsDisplay = true }
    }
    var radius: CGFloat = 0

    override func draw(_ dirtyRect: NSRect) {
        if let drop { DropHighlight.drawIcon(drop.state, in: bounds, radius: radius, theme: drop.theme) }
    }
}

/// An item of the Icon view.
final class IconItem: NSCollectionViewItem, GridItemView, GridItemDragging {
    static let identifier = NSUserInterfaceItemIdentifier("icons.item")

    let root = IconItemRootView()
    let tile = IconTileView()
    /// `.icon-item-image .file-icon`: the box the icon or the preview is drawn in.
    let iconBox = PassThroughView()
    let iconView = NSImageView()
    let thumbnail = IconThumbnailView()
    let badge = ClipboardBadgeView()
    let label = IconNameLabel()
    let pill = GridMarkerView(id: "icons.item.pill")
    /// Marks the item a drag would drop into, for the capture.
    let dropMarker = GridMarkerView(id: "icons.item.dropTarget")
    /// The whole name, for what reads the item's text field (the capture's `select` step).
    private let nameField = NSTextField(labelWithString: "")

    private(set) var path: String?
    private var density = Density.comfortable
    private var iconRequest: LoadHandle?
    private var thumbnailRequest: LoadHandle?
    private var hasThumbnail = false

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
        root.addSubview(badge)
        root.addSubview(label)
        label.addSubview(pill)
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
        nameField.stringValue = entry.name
        root.setAccessibilityLabel(entry.name)
        // `title={entry.name}`: the whole name, for one shortened in the middle.
        root.toolTip = entry.name
        let layout = pane.layout
        let style = pane.style
        let fitted = IconLabelText.fit(name: entry.name, extension: entry.fileExtension, density: density)
        label.density = density
        label.font = IconLabelText.font(layout)
        label.stringValue = fitted
        label.lines = IconLabelText.lines(fitted, density: density)
        // The match is marked in what is left of a name shortened in the middle.
        label.marks =
            host.search?.match(in: entry.name).map {
                NameHighlight.mapToLabel(name: entry.name, label: fitted, match: $0)
            } ?? []
        labelTextWidth = IconLabelText.width(fitted, density: density)
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

    private var labelTextWidth = 0.0

    private func loadThumbnail(_ entry: DirectoryEntry, pane: IconViewController) {
        thumbnailRequest?.cancel()
        thumbnailRequest = nil
        let theme = pane.host?.theme ?? AppearanceModel.shared.theme
        let style = pane.style
        thumbnailRequest = IconThumbnails.store.load(
            path: entry.path, kind: entry.iconEntry.kind, listing: pane.listing
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
        if let mark = host.clipboardMark(for: entry.path) {
            badge.mark = mark
            badge.theme = theme
            badge.style = pane.style
            badge.isHidden = false
        } else {
            badge.isHidden = true
        }
        // Cut items look taken out already: the name and the picture (not its badge) dimmed (P5-08).
        let cut = host.clipboardMark(for: entry.path) == .cut
        label.alphaValue = cut ? CGFloat(ClipboardLayout.Mark.cutLabelAlpha) : 1
        iconBox.alphaValue = cut ? CGFloat(ClipboardLayout.Mark.cutIconAlpha) : 1
        let dropState = host.dropState(for: entry.path)
        root.radius = CGFloat(pane.style.tileRadius)
        root.drop = dropState.map { ($0, theme) }
        dropMarker.isHidden = dropState == nil || dropState == .invalid
        DropHighlight.setWiggle(iconBox, on: dropState == .springing)
        if hasThumbnail, !thumbnail.isHidden, let picture = IconThumbnails.store.loadedPicture(forPath: entry.path) {
            thumbnail.show(picture, theme: theme, style: pane.style)
        }
    }

    // MARK: Layout

    private func layoutParts() {
        let layout = DesignTokens.iconGrid(density: density)
        let style = IconItemStyle.make(density: density)
        let tileFrame = layout.tileFrame(style: style)
        tile.frame = NSRect(x: tileFrame.x, y: tileFrame.y, width: tileFrame.width, height: tileFrame.height)
        let inset = layout.iconInset
        iconBox.frame = NSRect(x: inset, y: inset, width: layout.iconSize, height: layout.iconSize)
        iconView.frame = iconBox.bounds
        if hasThumbnail, thumbnailSize.width > 0, thumbnailSize.height > 0 {
            // `max-width: 100%; max-height: 100%`: shrunk to fit the box, never enlarged.
            let side = layout.iconSize
            let scale = min(1, side / Double(thumbnailSize.width), side / Double(thumbnailSize.height))
            let width = Double(thumbnailSize.width) * scale
            let height = Double(thumbnailSize.height) * scale
            thumbnail.frame = NSRect(x: (side - width) / 2, y: (side - height) / 2, width: width, height: height)
        }
        let labelFrame = layout.labelFrame(textWidth: labelTextWidth, lines: label.lines.count)
        label.frame = NSRect(x: labelFrame.x, y: labelFrame.y, width: labelFrame.width, height: labelFrame.height)
        pill.frame = label.bounds
        dropMarker.frame = root.bounds
        let badgeSize = layout.clipboardBadgeSize
        let offset = layout.clipboardBadgeOffset
        // `top: -4px; right: -4px` of the tile.
        badge.frame = NSRect(
            x: tileFrame.maxX - offset - badgeSize, y: tileFrame.y + offset, width: badgeSize, height: badgeSize)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        layoutParts()
    }

    // MARK: Clipboard and drags (P5-08)

    /// The item was just copied or cut (`.icon-item.clipboard-flash::after`): the whole item, in the accent.
    func flashClipboardMark(in pane: ItemGridPane) {
        guard let path, let host = pane.host, host.clipboardMarks?.mark(for: path) != nil else { return }
        ClipboardFlash.flash(
            root, color: ClipboardMarkGlyph.color(theme: host.theme, onSelection: false),
            radius: CGFloat(IconItemStyle.make(density: density).tileRadius))
    }

    /// Where the picture and the name are drawn, in `view`'s coordinates, for the drag's images.
    func dragPlacement(in view: NSView, visible: NSRect) -> FileDragPlacement {
        // `.file-icon`: the box the icon or the preview is drawn in.
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
