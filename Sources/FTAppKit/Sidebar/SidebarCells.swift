// Port of TreeItemRow and renderSectionHeader (apps/desktop/src/renderer/components/TreePane.tsx) with the sidebar rules of styles.css
import AppKit
import CoreText
import FTFoundation

/// A view named for the geometry dump that shows another view's text style: the original's `.tree-row` is compared by
/// its box and by the style of the `.tree-label-text` inside it.
final class SidebarTagView: SidebarPlainView, TextStyleSource {
    weak var source: NSTextField?
    var styleTextField: NSTextField? { source }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The box of a row (`.tree-row`): its fill, its ring, and the parts inside.
final class SidebarRowBox: SidebarPlainView, TextStyleSource {
    weak var label: NSTextField?
    var styleTextField: NSTextField? { label }
    var fill: NSColor?
    var border: NSColor?
    var borderWidth = 0.0
    var ring: NSColor?
    var ringWidth = 0.0
    var radius = DesignTokens.radii.control

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        if let fill {
            fill.setFill()
            shape.fill()
        }
        if let border, borderWidth > 0 {
            let inset = NSBezierPath(
                roundedRect: bounds.insetBy(dx: borderWidth / 2, dy: borderWidth / 2),
                xRadius: radius - borderWidth / 2,
                yRadius: radius - borderWidth / 2)
            inset.lineWidth = borderWidth
            border.setStroke()
            inset.stroke()
        }
        if let ring, ringWidth > 0 {
            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            let inset = NSBezierPath(
                roundedRect: bounds.insetBy(dx: ringWidth / 2, dy: ringWidth / 2), xRadius: radius - ringWidth / 2,
                yRadius: radius - ringWidth / 2)
            inset.lineWidth = ringWidth
            ring.setStroke()
            inset.stroke()
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}

/// The text of a row: one line, ending in an ellipsis.
final class SidebarLabelField: NSTextField {
    override var isFlipped: Bool { true }

    /// Text that starts at the left edge of its frame, as a web page's does.
    override class var cellClass: AnyClass? {
        get { TextBoxCell.self }
        set {}
    }

    convenience init() {
        self.init(labelWithString: "")
        lineBreakMode = .byTruncatingTail
        cell?.usesSingleLineMode = true
        cell?.truncatesLastVisibleLine = true
        isBordered = false
        drawsBackground = false
        isSelectable = false
        focusRingType = .none
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Line heights as Chromium lays text out for `line-height: normal`: the font's ascent, descent and gap, each rounded.
enum SidebarText {
    static func lineHeight(_ font: NSFont) -> Double {
        Double(font.ascender - font.descender + font.leading)
    }

    static func width(_ text: String, font: NSFont, kern: Double = 0) -> Double {
        // Core Text lays the line out with pair kerning, as the web page does. An explicit kern of 0 turns that off.
        let attributes: [NSAttributedString.Key: Any] = kern == 0 ? [.font: font] : [.font: font, .kern: kern]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        return CTLineGetTypographicBounds(line, nil, nil, nil)
    }
}

/// A row of the tree, the Favorites or the Locations.
final class SidebarItemCell: NSTableCellView, SidebarAccessibleCell {
    var accessibilityButtons: [NSView] { [chevron, eject] }

    static let identifier = NSUserInterfaceItemIdentifier("SidebarItemCell")

    let box = SidebarRowBox()
    private let chevron = SidebarChevronView()
    private let icon = SidebarIconView()
    private let label = SidebarLabelField()
    private let badge = SidebarBadgeView()
    private let eject = SidebarEjectView()
    private let dropBadge = SidebarBadgeView()
    private let dropLine = SidebarPlainView()
    /// The copy or cut glyph after the name of an item on the clipboard (P5-08).
    private let markGlyph = ClipboardMarkGlyph(identifier: "sidebar.row.clipboardMark")
    private let loading = SidebarLabelField()
    private let error = SidebarLabelField()
    private let treeRowTag = SidebarTagView()
    private let favoriteTag = SidebarTagView()
    private let selectedTag = SidebarTagView()
    private let menuTargetTag = SidebarTagView()
    private let expandedTag = SidebarTagView()
    private let kindTag = SidebarTagView()
    private(set) var state: SidebarRowState?
    private var noteHeight = 0.0

    var onToggle: (() -> Void)?
    var onEject: (() -> Void)?
    var onMenu: ((NSEvent) -> Void)?
    var onIconArrived: (() -> Void)?

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
        wantsLayer = true
        box.label = label
        label.cell?.lineBreakMode = .byTruncatingTail
        for (view, name) in [
            (box, "sidebar.row"), (chevron, "sidebar.row.chevron"), (icon, "sidebar.row.icon"),
            (label, "sidebar.row.label"), (badge, "sidebar.row.badge"), (eject, "sidebar.row.eject"),
            (dropBadge, "sidebar.row.dropBadge"), (dropLine, "sidebar.favorite.dropLine"),
            (treeRowTag, "sidebar.treeRow"),
        ] as [(NSView, String)] {
            view.setAccessibilityIdentifier(name)
        }
        favoriteTag.setAccessibilityIdentifier("sidebar.favorite")
        selectedTag.setAccessibilityIdentifier("sidebar.row.selected")
        menuTargetTag.setAccessibilityIdentifier("sidebar.row.menuTarget")
        expandedTag.setAccessibilityIdentifier("sidebar.row.expanded")
        for tag in [treeRowTag, favoriteTag, selectedTag, menuTargetTag, expandedTag, kindTag] { tag.source = label }
        for view in [
            chevron, icon, label, badge, eject, dropBadge, dropLine, treeRowTag, favoriteTag, selectedTag,
            menuTargetTag,
            expandedTag, kindTag, markGlyph,
        ] as [NSView] {
            box.addSubview(view)
        }
        addSubview(box)
        for note in [loading, error] {
            note.lineBreakMode = .byWordWrapping
            note.cell?.usesSingleLineMode = false
            note.maximumNumberOfLines = 0
            addSubview(note)
        }
        loading.setAccessibilityIdentifier("sidebar.row.loading")
        error.setAccessibilityIdentifier("sidebar.row.error")
        chevron.onClick = { [weak self] in self?.onToggle?() }
        eject.onClick = { [weak self] in self?.onEject?() }
        eject.onRightClick = { [weak self] event in self?.onMenu?(event) }
        dropBadge.setAccessibilityElement(false)
        dropLine.wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: Contents

    /// The row just opened or closed.
    func turnChevron() { chevron.turnToWhereItIs() }

    func configure(_ state: SidebarRowState, width: Double) {
        self.state = state
        let layout = SidebarLayout(density: state.density)
        let theme = SidebarColors.theme(for: self)
        let palette = theme.palette
        let accent = theme.accent
        let item = state.item
        let isHeading = item.kind == .favoritesRoot || item.kind == .locationsRoot
        let selectedFocused = state.selection == .focused
        let selected = state.selection != .none
        let onSelection = ChromeColors.color(accent.onSelection)

        // The box
        box.radius = layout.rowRadius
        box.fill = nil
        box.border = nil
        box.borderWidth = 0
        box.ring = nil
        box.ringWidth = 0
        switch state.selection {
        case .focused: box.fill = ChromeColors.color(accent.selectionBg)
        // Finder's: about 9.5% of black or white over its sidebar, not the system's opaque unemphasized color.
        case .inactive: box.fill = .systemFill
        case .none: break
        }
        switch state.drop {
        case .valid:
            box.fill = ChromeColors.color(accent.softBg)
            box.border = ChromeColors.color(accent.border)
            box.borderWidth = 2
        case .invalid:
            box.fill = ChromeColors.color(palette.danger, percent: 10)
            box.border = ChromeColors.color(palette.danger, percent: 48)
            box.borderWidth = 2
        case nil: break
        }
        if state.menuTarget {
            box.ring = ChromeColors.color(accent.solid)
            box.ringWidth = layout.menuRingWidth
        }
        box.toolTip = item.kind == .location ? item.label : (item.path ?? item.label)
        box.setAccessibilityLabel(item.label)
        alphaValue = state.dragging ? CGFloat(layout.draggedRowOpacity) : 1

        // The disclosure button
        let canExpand = item.canExpand
        chevron.isHidden = !state.hasDisclosure
        chevron.iconSize = layout.chevronIcon
        chevron.strokeWidth = layout.chevronStroke
        chevron.expanded = item.expanded
        chevron.isEnabled = canExpand && !item.loading
        chevron.isVisibleGlyph = canExpand || item.loading
        chevron.color = selectedFocused ? onSelection : ChromeColors.color(palette.textSecondary)
        let isHeadingKind = isHeading
        chevron.toolTip =
            !canExpand
            ? (isHeadingKind ? "No favorites" : "No subfolders")
            : isHeadingKind
                ? "\(item.expanded ? "Collapse" : "Expand") \(item.label)"
                : (item.expanded ? "Collapse Folder" : "Expand Folder")
        chevron.setAccessibilityLabel(
            isHeadingKind
                ? "\(item.expanded ? "Collapse" : "Expand") \(item.label)"
                : (item.expanded ? "Collapse Folder" : "Expand Folder"))

        // The icon
        switch item.kind {
        case .favoritesRoot, .locationsRoot:
            icon.content = .heading(
                item.kind == .favoritesRoot ? .favorites : .locations,
                color: selectedFocused ? onSelection : ChromeColors.color(accent.solid))
        case .favorite:
            icon.content = .symbol(
                SidebarIcons.symbolName(for: item.icon ?? .folder), pointSize: layout.iconSize,
                color: selectedFocused ? onSelection : ChromeColors.color(accent.solid))
        case .location:
            icon.content = .symbol(
                SidebarIcons.locationSymbolName(for: item.icon ?? .folder, path: item.path),
                pointSize: layout.iconSize, color: selectedFocused ? onSelection : .secondaryLabelColor)
        case .filesystem:
            let image = item.path.flatMap { path in
                SidebarFolderIcons.shared.icon(path: path, alias: item.isSymlink) { [weak self] in
                    self?.icon.needsDisplay = true
                    self?.onIconArrived?()
                }
            }
            icon.content = .folder(image)
        }

        // The label
        let headingStyle = isHeading
        let size = headingStyle ? layout.headingFontSize : layout.labelFontSize
        let weight = headingStyle ? 600 : (selected ? 600 : 400)
        var labelColor = headingStyle ? palette.textSecondary : palette.textPrimary
        var textColor = ChromeColors.color(labelColor)
        var labelWeight = weight
        if selectedFocused, !headingStyle {
            textColor = onSelection
        }
        if state.drop == .valid {
            textColor = ChromeColors.color(accent.border)
            labelWeight = 700
            labelColor = accent.border
        }
        label.font = ChromeColors.font(size: size, weight: labelWeight)
        label.textColor = textColor
        label.stringValue = item.label
        // On the clipboard: the glyph after the name, and a cut item's name dimmed (`.clipboard-cut .tree-label-text`).
        markGlyph.mark = state.clipboardMark
        markGlyph.color = selectedFocused ? onSelection : ChromeColors.color(accent.solidButton)
        label.alphaValue = state.clipboardMark == .cut ? CGFloat(ClipboardLayout.Mark.cutLabelAlpha) : 1

        // The Alias badge
        badge.isHidden = !item.isSymlink
        badge.fill = ChromeColors.color(palette.bgHover)
        badge.textColor = ChromeColors.color(palette.textSecondary)
        badge.apply(layout: layout)

        // The eject button
        let showsEject = item.kind == .location && item.canEject && item.path != nil && state.drop != .valid
        eject.isHidden = !showsEject
        eject.iconSize = layout.ejectIcon
        eject.strokeWidth = layout.ejectStroke
        eject.color = selectedFocused ? onSelection : ChromeColors.color(palette.textSecondary)
        eject.hoverColor = selectedFocused ? onSelection : ChromeColors.color(palette.textPrimary)
        eject.isEnabled = !state.ejecting
        eject.toolTip = "Eject \u{201C}\(item.label)\u{201D}"
        eject.setAccessibilityLabel("Eject \u{201C}\(item.label)\u{201D}")

        // The drop pill and the favorites' drop line
        dropBadge.isHidden = state.drop != .valid
        dropBadge.fill = ChromeColors.color(accent.solidButton)
        dropBadge.textColor = ChromeColors.color(accent.onSolid)
        dropBadge.apply(layout: layout)
        dropLine.isHidden = state.dropLine == nil
        dropLine.layer?.backgroundColor = ChromeColors.color(accent.solid).cgColor
        dropLine.layer?.cornerRadius = 1

        // Loading and errors under the row
        let noteFont = ChromeColors.font(size: layout.noteFontSize)
        loading.isHidden = !(item.loading && state.showsLoading)
        loading.font = noteFont
        loading.textColor = ChromeColors.color(palette.textSecondary)
        loading.stringValue = "Loading folder\u{2026}"
        error.isHidden = item.error == nil
        error.font = noteFont
        error.textColor = ChromeColors.color(palette.danger)
        error.stringValue = item.error ?? ""

        // Tags for the scenarios
        favoriteTag.isHidden = item.kind != .favorite
        selectedTag.isHidden = state.selection == .none && !state.isCurrentRow
        menuTargetTag.isHidden = !state.menuTarget
        expandedTag.isHidden = !(item.canExpand && item.expanded)
        switch item.kind {
        case .filesystem: kindTag.setAccessibilityIdentifier("sidebar.folder")
        case .location: kindTag.setAccessibilityIdentifier("sidebar.location")
        case .favorite: kindTag.setAccessibilityIdentifier("sidebar.favoriteRow")
        case .favoritesRoot, .locationsRoot: kindTag.setAccessibilityIdentifier("sidebar.heading")
        }

        noteHeight = Self.noteHeight(state, width: width)
        needsLayout = true
        needsDisplay = true
    }

    /// The row's item was just copied or cut: its box flashes (`.tree-row.clipboard-flash`).
    func flashClipboardMark() {
        guard let state, state.clipboardMark != nil else { return }
        let theme = SidebarColors.theme(for: self)
        let color = state.selection == .focused ? theme.accent.onSelection : theme.accent.solidButton
        ClipboardFlash.flash(
            box, color: ChromeColors.color(color), radius: CGFloat(SidebarLayout(density: state.density).rowRadius))
    }

    /// The height of the notes under a row: "Loading folder…" and an error, each in the padding of `.tree-loading`.
    static func noteHeight(_ state: SidebarRowState, width: Double) -> Double {
        let layout = SidebarLayout(density: state.density)
        let font = ChromeColors.font(size: layout.noteFontSize)
        var total = 0.0
        let textWidth = max(1, width - layout.noteLeading(depth: state.item.depth) - layout.notePadding.right)
        let line = SidebarText.lineHeight(font)
        if state.item.loading && state.showsLoading {
            total += layout.notePadding.top + line + layout.notePadding.bottom
        }
        if let error = state.item.error {
            let bounds = (error as NSString).boundingRect(
                with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin], attributes: [.font: font])
            let lines = max(1, (bounds.height / (font.ascender - font.descender + font.leading)).rounded())
            total += layout.notePadding.top + lines * line + layout.notePadding.bottom
        }
        return total
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        guard let state else { return }
        let layout = SidebarLayout(density: state.density)
        let item = state.item
        let rowHeight = layout.rowHeight
        let boxFrame = NSRect(
            x: layout.rowMarginX, y: 0, width: bounds.width - 2 * layout.rowMarginX, height: rowHeight)
        box.frame = boxFrame
        let width = boxFrame.width
        let leading = layout.contentLeading(depth: item.depth)
        var x = leading
        if state.hasDisclosure {
            chevron.frame = NSRect(
                x: x, y: ((rowHeight - layout.chevronBox) / 2), width: layout.chevronBox, height: layout.chevronBox)
            x += layout.chevronBox + layout.rowGap
        }
        var limit = width - layout.rowPaddingRight
        if !eject.isHidden {
            let ejectX = width - layout.rowPaddingRight - layout.ejectBox - layout.ejectMarginRight
            eject.frame = NSRect(
                x: ejectX, y: (rowHeight - layout.ejectBox) / 2, width: layout.ejectBox, height: layout.ejectBox)
            limit = ejectX - layout.rowGap
        }
        if !dropBadge.isHidden {
            let font = ChromeColors.font(size: DesignTokens.typeScale.small, weight: 600)
            let textWidth = SidebarText.width("Drop here", font: font)
            let pillWidth = textWidth + 20
            let pillHeight = SidebarText.lineHeight(font) + 8
            dropBadge.frame = NSRect(
                x: limit - pillWidth + layout.rowGap, y: (rowHeight - pillHeight) / 2, width: pillWidth,
                height: pillHeight)
            limit = dropBadge.frame.minX - layout.rowGap
        }
        // The icon, the name, and the badge
        icon.frame = NSRect(x: x, y: (rowHeight - layout.iconSize) / 2, width: layout.iconSize, height: layout.iconSize)
        var textX = x + layout.iconSize + layout.labelGap
        var textLimit = limit
        if !badge.isHidden {
            let badgeWidth = badge.fittingWidth(layout: layout)
            let badgeHeight =
                SidebarText.lineHeight(ChromeColors.font(size: layout.badgeFontSize)) + 2 * layout.badgePaddingY
            textLimit -= badgeWidth + layout.labelGap
            badge.frame = NSRect(
                x: max(
                    textX,
                    min(
                        textX + SidebarText.width(label.stringValue, font: label.font ?? .systemFont(ofSize: 14))
                            + layout.labelGap, textLimit + layout.labelGap)),
                y: (rowHeight - badgeHeight) / 2, width: badgeWidth, height: badgeHeight)
        }
        let font = label.font ?? ChromeColors.font(size: layout.labelFontSize)
        let lineHeight = SidebarText.lineHeight(font)
        let natural = SidebarText.width(label.stringValue, font: font)
        // `.sidebar-main-native .tree-label { gap: 6px }`: the tree's gap, not the list's.
        let markRoom = markGlyph.isHidden ? 0 : layout.labelGap + ClipboardLayout.Mark.iconSize
        let textWidth = max(0, min(natural, textLimit - textX - markRoom))
        label.frame = NSRect(x: textX, y: (rowHeight - lineHeight) / 2, width: textWidth, height: lineHeight)
        if !markGlyph.isHidden {
            let size = ClipboardLayout.Mark.iconSize
            markGlyph.frame = NSRect(
                x: label.frame.maxX + layout.labelGap, y: (rowHeight - size) / 2, width: size, height: size)
        }
        textX = 0
        textLimit = 0
        // The favorites' drop line sits on the row's top or bottom edge.
        if let position = state.dropLine {
            let y =
                position == .before
                ? layout.dropLineOffset
                : rowHeight + layout.dropLineOffset - layout.dropLineHeight + layout.dropLineHeight
            dropLine.frame = NSRect(
                x: layout.dropLineInset,
                y: position == .before ? y : rowHeight - layout.dropLineHeight - layout.dropLineOffset,
                width: width - 2 * layout.dropLineInset, height: layout.dropLineHeight)
        }
        for tag in [treeRowTag, favoriteTag, selectedTag, menuTargetTag, expandedTag, kindTag] {
            tag.frame = box.bounds
        }

        // Notes under the row
        var noteY = rowHeight
        let noteFont = ChromeColors.font(size: layout.noteFontSize)
        let line = SidebarText.lineHeight(noteFont)
        let noteX = layout.noteLeading(depth: item.depth)
        let noteWidth = max(1, bounds.width - noteX - layout.notePadding.right)
        if !loading.isHidden {
            noteY += layout.notePadding.top
            loading.frame = NSRect(x: noteX, y: noteY, width: noteWidth, height: line)
            noteY += line + layout.notePadding.bottom
        }
        if !error.isHidden {
            noteY += layout.notePadding.top
            let height = (error.stringValue as NSString).boundingRect(
                with: NSSize(width: noteWidth, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin],
                attributes: [.font: noteFont]
            ).height
            let lines = max(1, (height / (noteFont.ascender - noteFont.descender + noteFont.leading)).rounded())
            error.frame = NSRect(x: noteX, y: noteY, width: noteWidth, height: lines * line)
        }
    }

    // MARK: Mouse

    override func menu(for event: NSEvent) -> NSMenu? {
        // The outline view above asks its owner.
        nil
    }
}

extension SidebarRowState {
    /// Shown selected: the selection, or the row just pressed.
    var isCurrentRow: Bool { selection != .none }
}

/// A section header of the separate layout (`.sidebar-section-header`): the title, and a chevron that shows on hover and
/// stays while the section is closed.
final class SidebarHeaderCell: NSTableCellView, SidebarAccessibleCell {
    var accessibilityButtons: [NSView] { [button] }

    static let identifier = NSUserInterfaceItemIdentifier("SidebarHeaderCell")

    private let button = SidebarHeaderButton()
    private(set) var state: SidebarHeaderState?
    var onToggle: (() -> Void)?
    var onPress: (() -> Void)?

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
        addSubview(button)
        button.onClick = { [weak self] in self?.onToggle?() }
        button.onPress = { [weak self] in self?.onPress?() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(_ state: SidebarHeaderState) {
        self.state = state
        button.configure(state)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard let state else { return }
        let layout = SidebarLayout(density: state.density)
        let top = state.first ? layout.sectionHeaderFirstMarginTop : layout.sectionHeaderMarginTop
        button.frame = NSRect(
            x: layout.sectionHeaderMarginX, y: top, width: bounds.width - 2 * layout.sectionHeaderMarginX,
            height: layout.sectionHeaderHeight)
    }
}

/// The button of a section header: a title and a chevron.
final class SidebarHeaderButton: SidebarPlainView, TextStyleSource {
    private let title = SidebarLabelField()
    private let stateTag = SidebarTagView()
    private var state: SidebarHeaderState?
    private var isHovered = false
    var onClick: (() -> Void)?
    /// The button went down: counted as a press on empty space before the click toggles the section.
    var onPress: (() -> Void)?
    var styleTextField: NSTextField? { title }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityParent() -> Any? { sidebarAccessibilityParent(of: self) }
    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(enclosingOutline)
        onPress?()
        var inside = true
        while let next = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            inside = bounds.contains(convert(next.locationInWindow, from: nil))
            if next.type == .leftMouseUp { break }
        }
        if inside { onClick?() }
    }

    private var enclosingOutline: NSView? {
        var view: NSView? = superview
        while let candidate = view, !(candidate is NSOutlineView) { view = candidate.superview }
        return view
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityIdentifier("sidebar.sectionHeader")
        title.setAccessibilityIdentifier("sidebar.sectionHeader.title")
        addSubview(title)
        stateTag.source = title
        addSubview(stateTag)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(_ state: SidebarHeaderState) {
        self.state = state
        let theme = SidebarColors.theme(for: self)
        let layout = SidebarLayout(density: state.density)
        title.font = ChromeColors.font(size: layout.headingFontSizeSmall, weight: 600)
        title.textColor = ChromeColors.color(theme.palette.textSecondary)
        title.stringValue = state.title
        toolTip = state.expanded ? "Hide \(state.title)" : "Show \(state.title)"
        stateTag.setAccessibilityIdentifier(
            state.expanded ? "sidebar.sectionHeader.expanded" : "sidebar.sectionHeader.collapsed")
        setAccessibilityLabel(toolTip)
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        guard let state else { return }
        let layout = SidebarLayout(density: state.density)
        stateTag.frame = bounds
        let font = title.font ?? ChromeColors.font(size: layout.headingFontSizeSmall, weight: 600)
        let height = SidebarText.lineHeight(font)
        title.frame = NSRect(
            x: layout.sectionHeaderPaddingLeft, y: (bounds.height - height) / 2,
            width: min(
                SidebarText.width(title.stringValue, font: font),
                max(
                    0,
                    bounds.width - layout.sectionHeaderPaddingLeft - layout.sectionHeaderPaddingRight
                        - layout.sectionChevron)),
            height: height)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(
            NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let state else { return }
        // The chevron shows under the pointer, and stays while the section is closed; turned 90° when open.
        guard isHovered || !state.expanded else { return }
        let layout = SidebarLayout(density: state.density)
        let theme = SidebarColors.theme(for: self)
        let size = layout.sectionChevron
        let rect = NSRect(
            x: bounds.width - layout.sectionHeaderPaddingRight - size, y: (bounds.height - size) / 2, width: size,
            height: size)
        SidebarIcons.drawChevron(
            in: rect, color: ChromeColors.color(theme.palette.textSecondary), stroke: layout.sectionChevronStroke,
            rotation: state.expanded ? .pi / 2 : 0)
    }
}
