import AppKit
import FTFoundation

/// The 20 pt glyph of a row, a folder or a file, drawn
/// from SVG paths.
@MainActor
final class SheetGlyphView: NSView, ThemeApplying {
    enum Shape {
        case folder, file
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
        }
    }

    /// The path scaled from its view box to fit the view, centered, filled then stroked 1.
    private func draw(_ path: NSBezierPath, viewBox: NSSize, fill: RGBA?, stroke: RGBA) {
        let scale = min(bounds.width / viewBox.width, bounds.height / viewBox.height)
        let transform = AffineTransform(
            translationByX: (bounds.width - viewBox.width * scale) / 2,
            byY: (bounds.height - viewBox.height * scale) / 2)
        guard let scaled = path.copy() as? NSBezierPath else { return }
        scaled.transform(using: AffineTransform(scale: scale))
        scaled.transform(using: transform)
        scaled.lineWidth = scale
        if let fill {
            NSColor(fill).setFill()
            scaled.fill()
        }
        NSColor(stroke).setStroke()
        scaled.stroke()
    }
}

// MARK: Segmented control

/// "For all conflicts:": the system's segmented control as a radio group, so Tab lands on
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

/// Where one segment of "For all conflicts" lies, for automation to find, read and click: it draws nothing and a click
/// goes through it to the control.
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
        // The text's own width, not rounded up, or the track grows a point per segment.
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

/// A row's choice: the system's pop-up, whose menu opens on click; Replace reads in red. Replace is disabled, with its
/// reason, where it can't be done.
@MainActor
final class ReviewChoicePopUp: NSPopUpButton, ThemeApplying {
    private var theme = AppearanceModel.shared.theme
    private static let font = ThemeFonts.sans(DesignTokens.typeScale.body)

    init() {
        super.init(frame: .zero, pullsDown: false)
        autoenablesItems = false
        font = Self.font
        setAccessibilityIdentifier("reviewSheet.row.choice")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Tab comes here whatever the system's keyboard navigation setting says.
    override var acceptsFirstResponder: Bool { isEnabled }
    override var canBecomeKeyView: Bool { acceptsFirstResponder }

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
        applyTitleColors()
        if let index = choices.firstIndex(of: selected) { selectItem(at: index) }
        setAccessibilityLabel(label)
    }

    var choice: CopyPasteChoice? {
        (selectedItem?.representedObject as? String).flatMap(CopyPasteChoice.init(rawValue:))
    }

    /// As wide as the system makes it for its longest item, at least 112 (as a `select` is).
    var preferredWidth: CGFloat {
        max(CGFloat(CopyPasteSheetLayout.choiceMinWidth), ceil(cell?.cellSize.width ?? 0))
    }

    func applyTheme(_ theme: Theme) {
        self.theme = theme
        applyTitleColors()
    }

    /// Replace's title in the danger color, in the menu and on the button while it is chosen.
    private func applyTitleColors() {
        for item in itemArray {
            let replace = (item.representedObject as? String) == CopyPasteChoice.overwrite.rawValue
            item.attributedTitle =
                replace && item.isEnabled
                ? NSAttributedString(
                    string: item.title,
                    attributes: [.font: Self.font, .foregroundColor: NSColor(theme.palette.danger)])
                : nil
        }
    }
}
