// Port of the sheet both CopyPasteReviewDialog.tsx and CopyPasteResultDialog.tsx draw (.copy-paste-sheet, its header,
// list and footer in apps/desktop/src/renderer/styles.css 7171-7420) and of the focus trap of useDialogFocus.ts
import AppKit
import FTFoundation

/// The review and result sheets' panel: dropped in below the toolbar (`.modal-scrim.is-sheet`), 680 wide, every
/// corner rounded; the title and message, an optional bar, the list that scrolls, the footer with its note and
/// buttons. What goes in the bar and the list is the sheet's own.
@MainActor
class CopyPasteSheetView: NSView, DialogPanel, ThemeApplying {
    let titleLabel: ThemedText
    let messageLabel: ThemedText
    let scroll = NSScrollView()
    let list = SheetListContent()
    /// The footer's buttons, left to right, at its right.
    var buttons: [SystemButton] = [] {
        didSet {
            for button in oldValue where !buttons.contains(where: { $0 === button }) { button.removeFromSuperview() }
            for button in buttons where button.superview !== self { addSubview(button) }
            for button in buttons { button.suppressesFocusRing = !keyboardMoved }
            needsLayout = true
        }
    }
    /// The note at the footer's left.
    let note = FooterNoteView()
    /// Whether the list is drawn: the review sheet leaves it out when it has no rows.
    var showsList = true {
        didSet {
            scroll.isHidden = !showsList
            needsLayout = true
        }
    }
    /// The list's padding (`.copy-paste-sheet-list`, or the result list's).
    var listInsets: (top: CGFloat, bottom: CGFloat) = (
        CGFloat(CopyPasteSheetLayout.listVertical), CGFloat(CopyPasteSheetLayout.listVertical)
    )
    private(set) var theme = AppearanceModel.shared.theme
    /// Whether Tab has been used: until then the button the sheet opens on shows no focus ring (it is already marked
    /// by its fill), as the original's sheets open.
    private(set) var keyboardMoved = false

    init(identifier: String) {
        let layout = CopyPasteSheetLayout.self
        var titleStyle = TextStyle(
            font: ThemeFonts.sans(DesignTokens.typeScale.body, .bold), color: { $0.palette.textPrimary },
            lineHeight: layout.titleLineHeight)
        titleStyle.background = { $0.palette.bgElevated }
        titleLabel = ThemedText("", style: titleStyle, wrapping: true)
        var messageStyle = TextStyle(
            font: ThemeFonts.sans(DesignTokens.typeScale.callout), color: { $0.palette.textSecondary },
            lineHeight: layout.messageLineHeight)
        messageStyle.background = { $0.palette.bgElevated }
        messageLabel = ThemedText("", style: messageStyle, wrapping: true)
        self.titleStyle = titleStyle
        self.messageStyle = messageStyle
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.sheet)
        setAccessibilityIdentifier(identifier)
        titleLabel.setAccessibilityIdentifier("\(identifier).title")
        messageLabel.setAccessibilityIdentifier("\(identifier).message")
        wantsLayer = true
        addSubview(titleLabel)
        addSubview(messageLabel)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.documentView = list
        scroll.setAccessibilityIdentifier("\(identifier).list")
        addSubview(scroll)
        note.setAccessibilityIdentifier("\(identifier).note")
        addSubview(note)
        applyTheme(theme)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private let titleStyle: TextStyle
    private let messageStyle: TextStyle

    override var isFlipped: Bool { true }

    func setTitle(_ title: String, message: String) {
        let titleStyle = titleStyle
        let messageStyle = messageStyle
        titleLabel.content = { titleStyle.string(title, $0) }
        messageLabel.content = { messageStyle.string(message, $0) }
        setAccessibilityLabel(title)
        needsLayout = true
    }

    func applyTheme(_ theme: Theme) {
        self.theme = theme
        let palette = theme.palette
        layer?.backgroundColor = NSColor(palette.bgElevated).cgColor
        layer?.cornerRadius = CGFloat(DesignTokens.radii.dialog)
        layer?.masksToBounds = false
        // --elevation-dialog: the 0.5 edge; DialogScrim draws the drops under the panel.
        if let edge = palette.elevationDialog.first(where: { $0.blur == 0 && $0.spread > 0 }) {
            layer?.borderWidth = CGFloat(edge.spread)
            layer?.borderColor = NSColor(edge.color).cgColor
        }
        needsDisplay = true
    }

    /// The sheet's content changed (rows shown or hidden, a longer note): the sheet is sized again, as the original's
    /// grows with its list.
    func contentChanged() {
        needsLayout = true
        superview?.needsLayout = true
    }

    // MARK: What a sheet adds

    /// The bar's height at `width` (0: none).
    func barHeight(forWidth width: CGFloat) -> CGFloat { 0 }

    /// Lays the bar out in `rect`.
    func layoutBar(in rect: NSRect) {}

    /// Lays the list's rows out at `width`; returns the rows' height.
    func layoutRows(width: CGFloat) -> CGFloat { 0 }

    /// The views Tab goes round, in order.
    func focusOrder() -> [NSView] { buttons.filter(\.isEnabled) }

    /// What the footer's note leaves of the footer's left.
    var footerHasNote: Bool { !note.text.isEmpty }

    // MARK: DialogPanel

    var initialResponder: NSView? { buttons.last { $0.isDefault } ?? buttons.last }

    func handleKey(_ event: NSEvent) -> Bool {
        if event.keyCode == KeyCode.tab {
            if !keyboardMoved {
                keyboardMoved = true
                for button in buttons { button.suppressesFocusRing = false }
            }
            cycleFocus(backward: event.modifierFlags.contains(.shift))
            return true
        }
        return false
    }

    /// Tab and ⇧Tab go round the sheet's controls, wrapping at either end (`useDialogFocus`).
    func cycleFocus(backward: Bool) {
        guard let window else { return }
        let order = focusOrder()
        guard !order.isEmpty else { return }
        let current = order.firstIndex { $0 === window.firstResponder }
        let next: Int =
            if backward {
                current.map { $0 <= 0 ? order.count - 1 : $0 - 1 } ?? order.count - 1
            } else {
                current.map { $0 >= order.count - 1 ? 0 : $0 + 1 } ?? 0
            }
        let view = order[next]
        window.makeFirstResponder(view)
        view.scrollToVisible(view.bounds)
    }

    func panelSize(in size: NSSize) -> NSSize {
        let layout = CopyPasteSheetLayout.self
        let width = min(CGFloat(layout.width), max(0, size.width - CGFloat(layout.viewportInset)))
        let room = max(0, size.height - CGFloat(DialogLayout.sheetTop) - CGFloat(layout.bottomInset))
        return NSSize(width: width, height: min(naturalHeight(width: width), room))
    }

    // MARK: Layout

    private func headerHeight(width: CGFloat) -> CGFloat {
        let layout = CopyPasteSheetLayout.self
        let inner = max(0, width - 2 * CGFloat(layout.headerHorizontal))
        return CGFloat(layout.headerTop) + titleLabel.height(forWidth: inner) + CGFloat(layout.headingGap)
            + messageLabel.height(forWidth: inner) + CGFloat(layout.headerBottom)
    }

    private func footerHeight(width: CGFloat) -> CGFloat {
        let layout = CopyPasteSheetLayout.self
        let content = max(CGFloat(DesignTokens.controlHeights.regular), note.height(forWidth: noteWidth(width: width)))
        return CGFloat(layout.border) + CGFloat(layout.footerTop) + content + CGFloat(layout.footerBottom)
    }

    private func noteWidth(width: CGFloat) -> CGFloat {
        let layout = CopyPasteSheetLayout.self
        let gap = CGFloat(layout.footerGap)
        let buttonsWidth = buttons.reduce(0) { $0 + $1.preferredWidth + gap }
        return max(0, width - 2 * CGFloat(layout.footerHorizontal) - buttonsWidth)
    }

    private func listHeight(width: CGFloat) -> CGFloat {
        guard showsList else { return 0 }
        return listInsets.top + layoutRows(width: width) + listInsets.bottom
    }

    private func naturalHeight(width: CGFloat) -> CGFloat {
        headerHeight(width: width) + barHeight(forWidth: width) + listHeight(width: width) + footerHeight(width: width)
    }

    override func layout() {
        super.layout()
        let layout = CopyPasteSheetLayout.self
        let width = bounds.width
        let inner = max(0, width - 2 * CGFloat(layout.headerHorizontal))
        var y = CGFloat(layout.headerTop)
        let titleHeight = titleLabel.height(forWidth: inner)
        titleLabel.frame = NSRect(x: CGFloat(layout.headerHorizontal), y: y, width: inner, height: ceil(titleHeight))
        y += titleHeight + CGFloat(layout.headingGap)
        let messageHeight = messageLabel.height(forWidth: inner)
        messageLabel.frame = NSRect(
            x: CGFloat(layout.headerHorizontal), y: y, width: inner, height: ceil(messageHeight))
        y += messageHeight + CGFloat(layout.headerBottom)
        let bar = barHeight(forWidth: width)
        if bar > 0 {
            layoutBar(in: NSRect(x: 0, y: y, width: width, height: bar))
            y += bar
        }
        let footer = footerHeight(width: width)
        let footerTop = bounds.height - footer
        if showsList {
            let rows = layoutRows(width: width)
            scroll.frame = NSRect(x: 0, y: y, width: width, height: max(0, footerTop - y))
            list.frame = NSRect(x: 0, y: 0, width: width, height: listInsets.top + rows + listInsets.bottom)
        }
        // The footer: the note at the left, the buttons in a row at the right, centered on one line.
        let contentTop = footerTop + CGFloat(layout.border) + CGFloat(layout.footerTop)
        let contentHeight = footer - CGFloat(layout.border) - CGFloat(layout.footerTop) - CGFloat(layout.footerBottom)
        var right = width - CGFloat(layout.footerHorizontal)
        for button in buttons.reversed() {
            let buttonWidth = button.preferredWidth
            right -= buttonWidth
            button.frame = NSRect(
                x: right, y: contentTop + (contentHeight - CGFloat(button.controlHeight)) / 2, width: buttonWidth,
                height: CGFloat(button.controlHeight))
            right -= CGFloat(layout.footerGap)
        }
        let noteWidth = noteWidth(width: width)
        let noteHeight = note.height(forWidth: noteWidth)
        note.frame = NSRect(
            x: CGFloat(layout.footerHorizontal), y: contentTop + (contentHeight - noteHeight) / 2, width: noteWidth,
            height: noteHeight)
        footerLine = footerTop
    }

    private var footerLine: CGFloat = 0

    override func draw(_ dirtyRect: NSRect) {
        // The footer's line (`border-top: 1px solid var(--border-light)`).
        NSColor(theme.palette.borderLight).setFill()
        NSRect(x: 0, y: footerLine, width: bounds.width, height: CGFloat(CopyPasteSheetLayout.border))
            .fill(using: .sourceOver)
    }
}

/// The list's content: rows one under another, a line between them (`.copy-paste-sheet-row + .copy-paste-sheet-row`).
@MainActor
final class SheetListContent: NSView, ThemeApplying {
    /// Where a line goes between two rows, and the full-width lines between sections.
    var separators: [CGFloat] = [] { didSet { needsDisplay = true } }
    /// The lines that belong to a row marked Replace (its top border), which has its tint under them too.
    var tintedSeparators: [CGFloat] = [] { didSet { needsDisplay = true } }
    var sectionLines: [CGFloat] = [] { didSet { needsDisplay = true } }
    private var theme = AppearanceModel.shared.theme

    override var isFlipped: Bool { true }

    func applyTheme(_ theme: Theme) {
        self.theme = theme
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let height = CGFloat(CopyPasteSheetLayout.border)
        let border = theme.palette.borderLight
        NSColor(theme.palette.danger.withAlpha(CopyPasteSheetLayout.replacingAlpha)).setFill()
        for y in tintedSeparators {
            NSRect(x: 0, y: y, width: bounds.width, height: height).fill(using: .sourceOver)
        }
        NSColor(border.withAlpha(border.alpha * CopyPasteSheetLayout.rowSeparatorAlpha)).setFill()
        for y in separators { NSRect(x: 0, y: y, width: bounds.width, height: height).fill(using: .sourceOver) }
        NSColor(border).setFill()
        for y in sectionLines { NSRect(x: 0, y: y, width: bounds.width, height: height).fill(using: .sourceOver) }
    }
}

/// The footer's note (`.copy-paste-sheet-footer-note`): the summary, or the warning with its triangle.
@MainActor
final class FooterNoteView: NSView {
    let glyph = SheetGlyphView(.warning)
    let label: ThemedText
    private(set) var text = ""
    private(set) var isWarning = false

    override init(frame: NSRect) {
        label = ThemedText("", style: Self.style(warning: false))
        label.lineBreakMode = .byWordWrapping
        label.usesSingleLineMode = false
        label.cell?.wraps = true
        super.init(frame: frame)
        addSubview(glyph)
        addSubview(label)
        glyph.isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    private static func style(warning: Bool) -> TextStyle {
        var style = TextStyle(
            font: ThemeFonts.sans(DesignTokens.typeScale.body),
            color: { warning ? $0.palette.textPrimary : $0.palette.textSecondary })
        style.background = { $0.palette.bgElevated }
        return style
    }

    func set(_ text: String, warning: Bool) {
        self.text = text
        isWarning = warning
        let style = Self.style(warning: warning)
        label.content = { style.string(text, $0) }
        glyph.isHidden = !warning
        setAccessibilityLabel(text)
        label.setAccessibilityValue(text)
        needsLayout = true
    }

    private var textInset: CGFloat {
        isWarning ? CGFloat(CopyPasteSheetLayout.warningGlyphSize + CopyPasteSheetLayout.noteGap) : 0
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let textHeight = label.normalLineBoxHeight(forWidth: max(1, width - textInset))
        return max(textHeight, isWarning ? CGFloat(CopyPasteSheetLayout.warningGlyphSize) : 0)
    }

    override func layout() {
        super.layout()
        let size = CGFloat(CopyPasteSheetLayout.warningGlyphSize)
        glyph.frame = NSRect(x: 0, y: (bounds.height - size) / 2, width: size, height: size)
        let textWidth = max(0, bounds.width - textInset)
        let textHeight = label.normalLineBoxHeight(forWidth: textWidth)
        label.frame = NSRect(
            x: textInset, y: (bounds.height - textHeight) / 2, width: textWidth,
            height: ceil(label.height(forWidth: textWidth)))
    }
}
