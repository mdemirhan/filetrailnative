// What the word at the caret of a search can be: a list under the toolbar's field, and under the Edit Search box's
// text. Rows in sections ("Kind", "Or a condition"), each with what it types at its end; one is highlighted, which
// Return or Tab takes and the arrows move. A press on a row takes it; the keyboard stays where it is typed. Given less
// room than its rows want, the rows scroll and the keys stay at the bottom.
import AppKit
import FTFoundation

@MainActor
final class SearchSuggestionsView: NSView, ThemeApplying {
    /// A row was taken with the mouse.
    var onChoose: (Int) -> Void {
        get { rows.onChoose }
        set { rows.onChoose = newValue }
    }
    var suggestions: SearchQuerySuggestions? { rows.suggestions }
    /// The link at the end of the line of keys was pressed: Help opens at Search. None, no link.
    var onHelp: (() -> Void)? {
        didSet { helpLink.isHidden = onHelp == nil }
    }
    let helpLink = SearchSyntaxHelpLink()
    var highlighted: Int { rows.highlighted }
    var highlightedRow: SearchQuerySuggestion? { rows.highlightedRow }

    private let scroll = NSScrollView()
    private let rows = SearchSuggestionRows()
    private var theme = AppearanceModel.shared.theme
    /// Drawn over what is under it, with a shadow.
    private let floating: Bool

    static let padding = 5.0
    static let footHeight = 26.0
    private static let footFont = ThemeFonts.sans(DesignTokens.typeScale.small)

    init(floating: Bool, identifier: String) {
        self.floating = floating
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.list)
        setAccessibilityLabel("Suggestions")
        setAccessibilityIdentifier(identifier)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        scroll.documentView = rows
        addSubview(scroll)
        helpLink.isHidden = true
        helpLink.onPress = { [weak self] in self?.onHelp?() }
        addSubview(helpLink)
        applyTheme(theme)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Shows `suggestions`; a new list starts on its first row.
    func show(_ suggestions: SearchQuerySuggestions?) {
        rows.show(suggestions)
        needsLayout = true
        needsDisplay = true
        NSAccessibility.post(element: self, notification: .layoutChanged)
    }

    /// The highlighted row moves by `step`, round the list, and scrolls into sight.
    func move(_ step: Int) {
        rows.move(step)
        rows.scrollToVisible(rows.highlightedFrame.insetBy(dx: 0, dy: -Self.padding))
        NSAccessibility.post(element: self, notification: .selectedChildrenChanged)
    }

    /// As tall as all its rows and the line of keys.
    var preferredHeight: Double { rows.contentHeight + 2 * Self.padding + Self.footHeight }

    /// As tall as fits in `room`, ending on a whole row: a list that scrolls never shows half of one.
    func height(fitting room: Double) -> Double {
        let chrome = 2 * Self.padding + Self.footHeight
        guard preferredHeight > room else { return preferredHeight }
        let bottom = rows.rowBottoms.last { $0 <= room - chrome } ?? rows.rowBottoms.first ?? 0
        return bottom + chrome
    }

    /// Wide enough for its longest row.
    var preferredWidth: Double { rows.contentWidth + 2 * Self.padding }

    func applyTheme(_ theme: Theme) {
        self.theme = theme
        let palette = theme.palette
        layer?.cornerRadius = CGFloat(DesignTokens.radii.menu)
        layer?.backgroundColor = NSColor(palette.dropdownBg).cgColor
        layer?.borderColor = NSColor(palette.border).cgColor
        layer?.borderWidth = 1
        layer?.masksToBounds = false
        if floating, let shadow = palette.shadowLg.first {
            layer?.shadowColor = NSColor(shadow.color.withAlpha(1)).cgColor
            layer?.shadowOpacity = Float(shadow.color.alpha)
            layer?.shadowRadius = CGFloat(shadow.blur / 2)
            // Flipped: a shadow's positive y is down.
            layer?.shadowOffset = CGSize(width: shadow.x, height: shadow.y)
        }
        rows.applyTheme(theme)
        helpLink.applyTheme(theme)
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        scroll.frame = NSRect(
            x: Self.padding, y: Self.padding, width: max(0, bounds.width - 2 * Self.padding),
            height: max(0, bounds.height - 2 * Self.padding - Self.footHeight))
        rows.frame = NSRect(x: 0, y: 0, width: scroll.contentSize.width, height: rows.contentHeight)
        rows.scrollToVisible(rows.highlightedFrame)
        let link = helpLink.fittingSize
        let inset = Self.padding + SearchSuggestionRows.rowInset
        helpLink.frame = NSRect(
            x: bounds.width - inset - link.width, y: bounds.height - Self.padding - Self.footHeight + 1,
            width: link.width, height: Self.footHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard suggestions != nil else { return }
        let palette = theme.palette
        let inset = Self.padding + SearchSuggestionRows.rowInset
        let top = bounds.height - Self.padding - Self.footHeight
        NSColor(palette.border).setFill()
        NSRect(x: inset, y: top + 1, width: max(0, bounds.width - 2 * inset), height: 1).fill()
        let foot = NSAttributedString(
            string: "↩ Choose     ⇥ Complete     ↑↓ Move     esc Close",
            attributes: [.font: Self.footFont, .foregroundColor: NSColor(palette.textSecondary)])
        foot.draw(at: NSPoint(x: inset, y: top + 1 + (Self.footHeight - foot.size().height) / 2))
    }

    override func accessibilityChildren() -> [Any]? { rows.accessibilityRows(parent: self) }
}

/// The rows themselves, in the list's scroll view.
@MainActor
final class SearchSuggestionRows: NSView {
    var onChoose: (Int) -> Void = { _ in }
    private(set) var suggestions: SearchQuerySuggestions?
    private(set) var highlighted = 0
    private var theme = AppearanceModel.shared.theme
    private var trackingArea: NSTrackingArea?

    static let rowHeight = DesignTokens.controlHeights.regular
    static let titleHeight = 20.0
    static let separatorHeight = 9.0
    static let rowInset = 9.0
    private static let titleFont = ThemeFonts.sans(DesignTokens.typeScale.body)
    private static let hintFont = ThemeFonts.mono(DesignTokens.typeScale.mono)
    private static let headingFont = ThemeFonts.sans(DesignTokens.typeScale.small, .semibold)

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// A new list starts on its first row, or on none when Return is to leave the word as it is.
    func show(_ suggestions: SearchQuerySuggestions?) {
        if suggestions?.rows != self.suggestions?.rows || suggestions?.range != self.suggestions?.range {
            highlighted =
                suggestions?.highlightsFirst == false || suggestions?.rows.first?.canBeChosen != true ? -1 : 0
        }
        self.suggestions = suggestions
        needsDisplay = true
    }

    /// The highlighted row moves by `step`, round the list, over rows that can't be chosen (what is wrong with a
    /// word); from none, ↓ goes to the first and ↑ to the last. With none to choose, none is highlighted.
    func move(_ step: Int) {
        guard let rows = suggestions?.rows, rows.contains(where: \.canBeChosen) else { return }
        let count = rows.count
        var next = highlighted < 0 ? (step > 0 ? 0 : count - 1) : ((highlighted + step) % count + count) % count
        while !rows[next].canBeChosen { next = ((next + (step > 0 ? 1 : -1)) % count + count) % count }
        highlighted = next
        needsDisplay = true
    }

    var highlightedRow: SearchQuerySuggestion? {
        guard let rows = suggestions?.rows, rows.indices.contains(highlighted) else { return nil }
        return rows[highlighted]
    }

    func applyTheme(_ theme: Theme) {
        self.theme = theme
        needsDisplay = true
    }

    var contentHeight: Double {
        guard let suggestions else { return 0 }
        var height = 0.0
        for (index, section) in suggestions.sections.enumerated() {
            if index > 0 { height += Self.separatorHeight }
            if section.title != nil { height += Self.titleHeight }
            height += Double(section.rows.count) * Self.rowHeight
        }
        return height
    }

    var contentWidth: Double {
        guard let suggestions else { return 0 }
        let widest =
            suggestions.rows.map { row in
                NSAttributedString(string: row.title, attributes: [.font: Self.titleFont]).size().width
                    + NSAttributedString(string: row.hint, attributes: [.font: Self.hintFont]).size().width + 28
            }.max() ?? 0
        return ceil(widest + 2 * Self.rowInset)
    }

    /// Where each row ends, top to bottom.
    var rowBottoms: [Double] { frames().rows.map { Double($0.maxY) } }

    var highlightedFrame: NSRect {
        let rows = frames().rows
        return rows.indices.contains(highlighted) ? rows[highlighted] : .zero
    }

    /// Each row's frame, each section title's, and where each line between sections is.
    private func frames() -> (rows: [NSRect], titles: [(String, NSRect)], separators: [Double]) {
        guard let suggestions else { return ([], [], []) }
        var y = 0.0
        var rows: [NSRect] = []
        var titles: [(String, NSRect)] = []
        var separators: [Double] = []
        for (index, section) in suggestions.sections.enumerated() {
            if index > 0 {
                separators.append(y + Self.separatorHeight / 2)
                y += Self.separatorHeight
            }
            if let title = section.title {
                titles.append((title, NSRect(x: 0, y: y, width: bounds.width, height: Self.titleHeight)))
                y += Self.titleHeight
            }
            for _ in section.rows {
                rows.append(NSRect(x: 0, y: y, width: bounds.width, height: Self.rowHeight))
                y += Self.rowHeight
            }
        }
        return (rows, titles, separators)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let suggestions else { return }
        let palette = theme.palette
        let layout = frames()
        for (title, frame) in layout.titles where frame.intersects(dirtyRect) {
            let text = NSAttributedString(
                string: title, attributes: [.font: Self.headingFont, .foregroundColor: NSColor(palette.textSecondary)])
            text.draw(
                at: NSPoint(x: frame.minX + Self.rowInset, y: frame.minY + (frame.height - text.size().height) / 2))
        }
        NSColor(palette.border).setFill()
        for y in layout.separators {
            NSRect(x: Self.rowInset, y: y, width: max(0, bounds.width - 2 * Self.rowInset), height: 1).fill()
        }
        let truncating = NSMutableParagraphStyle()
        truncating.lineBreakMode = .byTruncatingTail
        for (index, row) in suggestions.rows.enumerated() where layout.rows.indices.contains(index) {
            let frame = layout.rows[index]
            guard frame.intersects(dirtyRect) else { continue }
            let on = index == highlighted
            if on {
                NSColor(theme.accent.solidButton).setFill()
                let radius = CGFloat(DesignTokens.radii.xs)
                NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius).fill()
            }
            let ink: NSColor
            switch row.tone {
            case .value: ink = NSColor(on ? theme.accent.onSolid : palette.textPrimary)
            case .problem: ink = NSColor(palette.dangerText)
            case .note: ink = NSColor(palette.textSecondary)
            }
            let quiet = on ? NSColor(theme.accent.onSolid).withAlphaComponent(0.85) : NSColor(palette.textSecondary)
            let hint = NSAttributedString(
                string: row.hint, attributes: [.font: Self.hintFont, .foregroundColor: quiet])
            let hintSize = hint.size()
            let hintX = frame.maxX - Self.rowInset - ceil(hintSize.width)
            hint.draw(at: NSPoint(x: hintX, y: frame.minY + (frame.height - hintSize.height) / 2))
            let title = NSAttributedString(
                string: row.title,
                attributes: [.font: Self.titleFont, .foregroundColor: ink, .paragraphStyle: truncating])
            let titleHeight = title.size().height
            title.draw(
                in: NSRect(
                    x: frame.minX + Self.rowInset, y: frame.minY + (frame.height - titleHeight) / 2,
                    width: max(0, hintX - 12 - frame.minX - Self.rowInset), height: titleHeight))
        }
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    private func row(at event: NSEvent) -> Int? {
        let point = convert(event.locationInWindow, from: nil)
        return frames().rows.firstIndex { $0.contains(point) }
    }

    override func mouseMoved(with event: NSEvent) {
        guard let index = row(at: event), index != highlighted, suggestions?.rows[index].canBeChosen == true else {
            return
        }
        highlighted = index
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        guard let index = row(at: event), suggestions?.rows[index].canBeChosen == true else { return }
        onChoose(index)
    }

    // MARK: Accessibility

    func accessibilityRows(parent: NSView) -> [Any] {
        guard let suggestions else { return [] }
        let layout = frames()
        return suggestions.rows.enumerated().compactMap { index, row -> NSAccessibilityElement? in
            guard layout.rows.indices.contains(index) else { return nil }
            let element = NSAccessibilityElement()
            element.setAccessibilityRole(.staticText)
            element.setAccessibilityLabel(row.replacement == nil ? row.title : "\(row.title), types \(row.hint)")
            element.setAccessibilityParent(parent)
            element.setAccessibilityFrameInParentSpace(convert(layout.rows[index], to: parent))
            element.setAccessibilitySelected(index == highlighted)
            return element
        }
    }
}

/// "Syntax Help" at the end of the list's line of keys, in the accent: a press opens Help at Search.
@MainActor
final class SearchSyntaxHelpLink: NSView, ThemeApplying {
    var onPress: () -> Void = {}
    static let title = "Syntax Help"
    private static let font = ThemeFonts.sans(DesignTokens.typeScale.small)
    private var theme = AppearanceModel.shared.theme
    private var trackingArea: NSTrackingArea?
    private var hovered = false {
        didSet { needsDisplay = true }
    }

    init() {
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.link)
        setAccessibilityLabel(Self.title)
        setAccessibilityIdentifier("searchSyntaxHelp")
        toolTip = "Open Help at Search"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var text: NSAttributedString {
        NSAttributedString(
            string: Self.title,
            attributes: [
                .font: Self.font, .foregroundColor: NSColor(theme.accent.solid),
                .underlineStyle: hovered ? NSUnderlineStyle.single.rawValue : 0,
            ])
    }

    override var fittingSize: NSSize { NSSize(width: ceil(text.size().width) + 4, height: ceil(text.size().height)) }

    func applyTheme(_ theme: Theme) {
        self.theme = theme
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let text = text
        text.draw(at: NSPoint(x: 2, y: (bounds.height - text.size().height) / 2))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .cursorUpdate], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func cursorUpdate(with event: NSEvent) { NSCursor.pointingHand.set() }
    override func mouseDown(with event: NSEvent) { onPress() }
    override func accessibilityPerformPress() -> Bool {
        onPress()
        return true
    }
}
