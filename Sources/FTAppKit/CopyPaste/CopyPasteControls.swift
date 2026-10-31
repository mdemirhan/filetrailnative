// Port of the glyphs (FolderGlyph, FileGlyph, WarningGlyph), the "For all conflicts" segmented control
// (AllConflictsButtons) and the row choice popup of apps/desktop/src/renderer/components/CopyPasteReviewDialog.tsx,
// with the .segmented, .copy-paste-choice and .copy-paste-*-glyph rules of styles.css
import AppKit
import FTFoundation

/// The 20 pt glyph of a row (`FolderGlyph`, `FileGlyph`) or the footer's warning triangle (`WarningGlyph`), drawn
/// from the original's SVG paths.
@MainActor
final class SheetGlyphView: NSView, ThemeApplying {
    enum Shape {
        case folder, file, warning
    }

    var shape: Shape { didSet { needsDisplay = true } }
    private var theme = AppearanceModel.shared.theme

    init(_ shape: Shape) {
        self.shape = shape
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    func applyTheme(_ theme: Theme) {
        self.theme = theme
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let palette = theme.palette
        switch shape {
        case .folder:
            // viewBox 0 0 20 16: M1 3a2 2 0 0 1 2-2h4.5l2 2H17a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H3a2 2 0 0 1-2-2z
            let path = NSBezierPath()
            path.move(to: NSPoint(x: 1, y: 3))
            path.appendArc(from: NSPoint(x: 1, y: 1), to: NSPoint(x: 3, y: 1), radius: 2)
            path.line(to: NSPoint(x: 7.5, y: 1))
            path.line(to: NSPoint(x: 9.5, y: 3))
            path.line(to: NSPoint(x: 17, y: 3))
            path.appendArc(from: NSPoint(x: 19, y: 3), to: NSPoint(x: 19, y: 5), radius: 2)
            path.line(to: NSPoint(x: 19, y: 13))
            path.appendArc(from: NSPoint(x: 19, y: 15), to: NSPoint(x: 17, y: 15), radius: 2)
            path.line(to: NSPoint(x: 3, y: 15))
            path.appendArc(from: NSPoint(x: 1, y: 15), to: NSPoint(x: 1, y: 13), radius: 2)
            path.close()
            draw(
                path, viewBox: NSSize(width: 20, height: 16), fill: theme.accent.folderTint, stroke: theme.accent.solid)
        case .file:
            // viewBox 0 0 16 20: M2 1h8l5 5v12a1 1 0 0 1-1 1H2a1 1 0 0 1-1-1V2a1 1 0 0 1 1-1z, and the fold M10 1v5h5
            let path = NSBezierPath()
            path.move(to: NSPoint(x: 2, y: 1))
            path.line(to: NSPoint(x: 10, y: 1))
            path.line(to: NSPoint(x: 15, y: 6))
            path.line(to: NSPoint(x: 15, y: 18))
            path.appendArc(from: NSPoint(x: 15, y: 19), to: NSPoint(x: 14, y: 19), radius: 1)
            path.line(to: NSPoint(x: 2, y: 19))
            path.appendArc(from: NSPoint(x: 1, y: 19), to: NSPoint(x: 1, y: 18), radius: 1)
            path.line(to: NSPoint(x: 1, y: 2))
            path.appendArc(from: NSPoint(x: 1, y: 1), to: NSPoint(x: 2, y: 1), radius: 1)
            path.close()
            let fold = NSBezierPath()
            fold.move(to: NSPoint(x: 10, y: 1))
            fold.line(to: NSPoint(x: 10, y: 6))
            fold.line(to: NSPoint(x: 15, y: 6))
            let box = NSSize(width: 16, height: 20)
            draw(path, viewBox: box, fill: palette.bgElevated, stroke: palette.textSecondary)
            draw(fold, viewBox: box, fill: nil, stroke: palette.textSecondary)
        case .warning:
            // viewBox 0 0 16 16: M8 1.5 15 14H1z, and the mark M8 6v3.6M8 11.4v.1
            let path = NSBezierPath()
            path.move(to: NSPoint(x: 8, y: 1.5))
            path.line(to: NSPoint(x: 15, y: 14))
            path.line(to: NSPoint(x: 1, y: 14))
            path.close()
            path.lineJoinStyle = .round
            let mark = NSBezierPath()
            mark.move(to: NSPoint(x: 8, y: 6))
            mark.line(to: NSPoint(x: 8, y: 9.6))
            mark.move(to: NSPoint(x: 8, y: 11.4))
            mark.line(to: NSPoint(x: 8, y: 11.5))
            mark.lineCapStyle = .round
            mark.lineWidth = 1.5
            let box = NSSize(width: 16, height: 16)
            draw(path, viewBox: box, fill: palette.warningGlyphFill, stroke: palette.warningGlyphStroke)
            draw(mark, viewBox: box, fill: nil, stroke: palette.warningGlyphMark, keepsWidth: true)
        }
    }

    /// The path scaled from its view box into the view, centered (`preserveAspectRatio` meet), filled then stroked 1.
    private func draw(_ path: NSBezierPath, viewBox: NSSize, fill: RGBA?, stroke: RGBA, keepsWidth: Bool = false) {
        let scale = min(bounds.width / viewBox.width, bounds.height / viewBox.height)
        let transform = AffineTransform(
            translationByX: (bounds.width - viewBox.width * scale) / 2,
            byY: (bounds.height - viewBox.height * scale) / 2)
        guard let scaled = path.copy() as? NSBezierPath else { return }
        scaled.transform(using: AffineTransform(scale: scale))
        scaled.transform(using: transform)
        scaled.lineWidth = (keepsWidth ? path.lineWidth : 1) * scale
        if let fill {
            NSColor(fill).setFill()
            scaled.fill()
        }
        NSColor(stroke).setStroke()
        scaled.stroke()
    }
}

// MARK: Segmented control

/// "For all conflicts:" (`AllConflictsButtons`): the system's segmented control (D-020) as a radio group, so Tab lands on
/// it and the arrow keys move the choice. Replace is red once chosen.
@MainActor
final class AllConflictsControl: SystemSegmentedControl {
    let segments: [AllConflictsSegment]
    var value: AllConflictsChoice? {
        didSet { showValue() }
    }
    var onChange: (AllConflictsChoice) -> Void = { _ in }

    init(choices: [AllConflictsChoice], value: AllConflictsChoice?) {
        segments = choices.map { AllConflictsSegment(choice: $0) }
        self.value = value
        super.init(titles: choices.map(\.label))
        setAccessibilityLabel(ReviewSheetText.allConflictsLabel)
        setSegmentWidths(
            segments.map(\.preferredWidth), trackPadding: CGFloat(CopyPasteSheetLayout.segmentTrackPadding),
            gap: CGFloat(CopyPasteSheetLayout.segmentGap))
        for segment in segments { addSubview(segment) }
        onSegment = { [weak self] index in
            guard let self, self.segments.indices.contains(index) else { return }
            self.pick(self.segments[index].choice)
            self.showValue()
        }
        showValue()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// What Tab lands on.
    var tabStop: NSView? { self }

    var preferredSize: NSSize {
        let layout = CopyPasteSheetLayout.self
        let widths = segments.reduce(0) { $0 + $1.preferredWidth }
        let gaps = CGFloat(max(0, segments.count - 1)) * CGFloat(layout.segmentGap)
        return NSSize(
            width: widths + gaps + 2 * CGFloat(layout.segmentTrackPadding),
            height: CGFloat(DesignTokens.controlHeights.regular + 2 * layout.segmentTrackPadding))
    }

    private func showValue() {
        for segment in segments { segment.isSelected = segment.choice == value }
        selectedSegment = segments.firstIndex { $0.choice == value } ?? -1
        applyTheme(theme)
    }

    override func selectionColor(_ theme: Theme) -> RGBA {
        value == .overwrite ? theme.palette.danger : theme.accent.solid
    }

    override func layout() {
        super.layout()
        let layout = CopyPasteSheetLayout.self
        var x = CGFloat(layout.segmentTrackPadding)
        for segment in segments {
            let width = segment.preferredWidth
            segment.frame = NSRect(
                x: x, y: CGFloat(layout.segmentTrackPadding), width: width,
                height: CGFloat(DesignTokens.controlHeights.regular))
            x += width + CGFloat(layout.segmentGap)
        }
    }

    /// Picks `choice`, as a click on its segment does.
    func pick(_ choice: AllConflictsChoice) {
        onChange(choice)
    }
}

/// Where one segment of "For all conflicts" lies (`.segmented-item.copy-paste-segment`), for captures to find, read and
/// click: it draws nothing and a click goes through it to the control.
@MainActor
final class AllConflictsSegment: TextControl {
    let choice: AllConflictsChoice
    var isSelected = false {
        didSet { applyColors() }
    }
    private static let font = ThemeFonts.sans(DesignTokens.typeScale.body)

    init(choice: AllConflictsChoice) {
        self.choice = choice
        super.init(text: choice.label, theme: AppearanceModel.shared.theme)
        font = Self.font
        alignment = .center
        alphaValue = 0
        setAccessibilityElement(false)
        setAccessibilityIdentifier("reviewSheet.choice")
        applyColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var preferredWidth: CGFloat {
        // A CSS box as wide as its text: not rounded up, or the track grows a point per segment.
        (title as NSString).size(withAttributes: [.font: Self.font]).width
            + 2 * CGFloat(CopyPasteSheetLayout.segmentPadding)
    }

    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func applyColors() {
        let palette = theme.palette
        textColor = NSColor(
            isSelected
                ? (choice == .overwrite ? palette.danger : palette.segmentedSelectedText) : palette.textSecondary)
    }

    override func applyTheme(_ theme: Theme) {
        super.applyTheme(theme)
        applyColors()
    }
}

// MARK: Choice popup

/// A row's choice (`.copy-paste-choice`): a native popup button, whose platform menu opens on click, in the push
/// button's bezel with the menu list's single down chevron; red while it reads Replace. Replace is disabled, with its reason, where it can't be done.
@MainActor
final class ReviewChoicePopUp: NSPopUpButton, ThemeApplying {
    private var theme = AppearanceModel.shared.theme
    private static let font = ThemeFonts.sans(DesignTokens.typeScale.body)
    /// The room the native popup's arrows take at its right.
    static let arrowWidth = 16.0
    /// Where the menu list's text starts past its padding, and its chevron (measured on the original's capture).
    static let textInset = 4.5
    static let chevronInset = 7.5
    static let chevronWidth = 7.0
    static let chevronHeight = 3.5
    static let chevronLineWidth = 1.25

    init() {
        super.init(frame: .zero, pullsDown: false)
        isBordered = false
        autoenablesItems = false
        font = Self.font
        setAccessibilityIdentifier("reviewSheet.row.choice")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var acceptsFirstResponder: Bool { isEnabled }
    override var isFlipped: Bool { true }

    /// Sets the items, and the one chosen.
    func set(_ choices: [CopyPasteChoice], selected: CopyPasteChoice, blockedReason: String?, label: String) {
        removeAllItems()
        for choice in choices {
            let item = NSMenuItem(
                title: ReviewSheetText.choiceTitle(choice, blockedReason: blockedReason), action: nil,
                keyEquivalent: "")
            item.representedObject = choice.rawValue
            item.isEnabled = !(choice == .overwrite && blockedReason != nil)
            menu?.addItem(item)
        }
        if let index = choices.firstIndex(of: selected) { selectItem(at: index) }
        setAccessibilityLabel(label)
        needsDisplay = true
    }

    var choice: CopyPasteChoice? {
        (selectedItem?.representedObject as? String).flatMap(CopyPasteChoice.init(rawValue:))
    }

    /// As wide as its longest item, with the padding and the arrows, at least 112 (as a `select` is).
    var preferredWidth: CGFloat {
        let widest = itemArray.map { ($0.title as NSString).size(withAttributes: [.font: Self.font]).width }.max() ?? 0
        return max(
            CGFloat(CopyPasteSheetLayout.choiceMinWidth),
            ceil(widest) + 2 * CGFloat(CopyPasteSheetLayout.choicePadding) + CGFloat(Self.arrowWidth))
    }

    func applyTheme(_ theme: Theme) {
        self.theme = theme
        needsDisplay = true
    }

    /// The chosen item's color: red while it reads Replace (`.copy-paste-choice.is-danger`).
    var titleColor: NSColor { NSColor(choice == .overwrite ? theme.palette.danger : theme.palette.textPrimary) }
    /// The menu list paints its arrow in the element's `color`, so the chevron follows the text.
    var chevronColor: NSColor { titleColor }

    override func draw(_ dirtyRect: NSRect) {
        let palette = theme.palette
        let radius = CGFloat(DesignTokens.radii.control)
        let shape = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        NSColor(palette.pushButtonBg).setFill()
        shape.fill()
        drawPushButtonBezel(palette, around: bounds, radius: radius)
        let color = titleColor
        // The menu list's own inner padding puts the text 4.5 in from the 8 of `padding: 0 8px`.
        let inset = CGFloat(CopyPasteSheetLayout.choicePadding + Self.textInset)
        let title = NSAttributedString(
            string: titleOfSelectedItem ?? "", attributes: [.font: Self.font, .foregroundColor: color])
        let size = title.size()
        let available = bounds.width - inset - CGFloat(CopyPasteSheetLayout.choicePadding) - CGFloat(Self.arrowWidth)
        title.draw(
            with: NSRect(x: inset, y: (bounds.height - size.height) / 2, width: available, height: size.height),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        // The menu list's one down chevron, 7.5 in from the right edge, in the text's color.
        let chevron = NSBezierPath()
        let centerX = bounds.width - CGFloat(Self.chevronInset)
        let midY = bounds.height / 2
        let half = CGFloat(Self.chevronWidth / 2)
        let rise = CGFloat(Self.chevronHeight / 2)
        chevron.move(to: NSPoint(x: centerX - half, y: midY - rise))
        chevron.line(to: NSPoint(x: centerX, y: midY + rise))
        chevron.line(to: NSPoint(x: centerX + half, y: midY - rise))
        chevron.lineWidth = CGFloat(Self.chevronLineWidth)
        chevron.lineCapStyle = .round
        chevron.lineJoinStyle = .round
        chevronColor.setStroke()
        chevron.stroke()
        if window?.firstResponder === self {
            let ring = NSBezierPath(
                roundedRect: bounds.insetBy(dx: -1.5, dy: -1.5), xRadius: radius + 1.5, yRadius: radius + 1.5)
            ring.lineWidth = CGFloat(DesignTokens.focusRingWidth)
            NSColor(theme.accent.solid.withAlpha(0.5)).setStroke()
            ring.stroke()
        }
    }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        needsDisplay = true
        return super.resignFirstResponder()
    }
}
