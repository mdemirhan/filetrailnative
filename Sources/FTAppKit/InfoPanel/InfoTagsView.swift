// The Info panel's Tags row: each tag as a chip, and a click opens the Tags popover
import AppKit
import FTFileSystem
import FTFoundation

/// The tags as chips, as many lines as they take, so every tag shows: a dot (a ring for a tag without a color) and the
/// name; a tag on only some of the items is outlined with a dashed line and says how many have it. Each line ends at the
/// right edge, as the panel's other values do. With no tags it reads "Add Tags…" where a click can add them, "None"
/// where it can't. A click opens the Tags popover from the row.
@MainActor
final class InfoTagsView: NSView {
    var tags = InfoTags(tags: [], itemCount: 1, editable: false) {
        didSet {
            toolTip = tags.summary.isEmpty ? nil : tags.summary
            setAccessibilityValue(tags.summary.isEmpty ? emptyText : tags.summary)
            needsDisplay = true
        }
    }
    var font: NSFont = ThemeFonts.sans(DesignTokens.typeScale.callout) {
        didSet { needsDisplay = true }
    }
    var textColor: NSColor = .labelColor
    var mutedColor: NSColor = .secondaryLabelColor
    var onClick: (() -> Void)?
    private var isHovered = false {
        didSet { needsDisplay = true }
    }

    static let dot: CGFloat = 7
    static let chipPadding: CGFloat = 5
    static let chipGap: CGFloat = 4
    static let dotGap: CGFloat = 4

    init() {
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Tags")
        setAccessibilityIdentifier("infoPanel.tags")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    private var emptyText: String { tags.editable ? "Add Tags\u{2026}" : "None" }

    /// The width of every chip, or of the empty text.
    var naturalWidth: Double {
        if tags.tags.isEmpty { return textExtent(emptyText, font) + 2 }
        let widths = tags.tags.map(chipWidth)
        return Double(widths.reduce(0, +) + CGFloat(max(0, widths.count - 1)) * Self.chipGap)
    }

    private func label(_ tag: InfoTag) -> String {
        tag.count < tags.itemCount ? "\(tag.name) (\(FormatLocale.count(tag.count)))" : tag.name
    }

    private func chipWidth(_ tag: InfoTag) -> CGFloat {
        ceil(Self.chipPadding * 2 + Self.dot + Self.dotGap + CGFloat(textExtent(label(tag), font)))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(
            NSTrackingArea(
                rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = tags.editable }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func mouseUp(with event: NSEvent) {
        guard tags.editable, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?()
    }

    override func accessibilityPerformPress() -> Bool {
        guard tags.editable else { return false }
        onClick?()
        return true
    }

    /// The chips of each line, by index, for a width: as many to a line as fit, a chip wider than the width alone on
    /// its line.
    func lines(width: CGFloat) -> [[Int]] {
        var lines: [[Int]] = []
        var line: [Int] = []
        var used: CGFloat = 0
        for (index, tag) in tags.tags.enumerated() {
            let chip = chipWidth(tag)
            let needed = line.isEmpty ? chip : used + Self.chipGap + chip
            if !line.isEmpty, needed > width {
                lines.append(line)
                line = [index]
                used = chip
            } else {
                line.append(index)
                used = needed
            }
        }
        if !line.isEmpty { lines.append(line) }
        return lines
    }

    /// The height of one line of chips.
    var lineHeight: CGFloat { ceil(font.ascender - font.descender + font.leading) }

    static let lineGap: CGFloat = 4

    /// The height the tags take at a width: one line with none.
    func height(width: CGFloat) -> CGFloat {
        let count = max(1, lines(width: width).count)
        return CGFloat(count) * lineHeight + CGFloat(count - 1) * Self.lineGap
    }

    override func draw(_ dirtyRect: NSRect) {
        if isHovered {
            NSColor.quaternaryLabelColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: -3, dy: -1), xRadius: 5, yRadius: 5).fill()
        }
        let lineHeight = lineHeight
        if tags.tags.isEmpty {
            (emptyText as NSString).draw(
                at: NSPoint(x: max(0, bounds.width - CGFloat(textExtent(emptyText, font)) - 1), y: 0),
                withAttributes: [.font: font, .foregroundColor: mutedColor])
            return
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        for (lineIndex, line) in lines(width: bounds.width).enumerated() {
            let top = CGFloat(lineIndex) * (lineHeight + Self.lineGap)
            let widths = line.map { min(chipWidth(tags.tags[$0]), bounds.width) }
            let total = widths.reduce(0, +) + CGFloat(max(0, line.count - 1)) * Self.chipGap
            var x = max(0, bounds.width - total)
            for (position, index) in line.enumerated() {
                let tag = tags.tags[index]
                let chip = NSRect(x: x, y: top, width: widths[position], height: lineHeight)
                let path = NSBezierPath(roundedRect: chip.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
                if tag.count < tags.itemCount {
                    NSColor.tertiaryLabelColor.setStroke()
                    path.lineWidth = 1
                    path.setLineDash([3, 2], count: 2, phase: 0)
                    path.stroke()
                } else {
                    NSColor.quaternaryLabelColor.setFill()
                    path.fill()
                }
                let dotRect = NSRect(
                    x: x + Self.chipPadding, y: top + (lineHeight - Self.dot) / 2, width: Self.dot, height: Self.dot)
                if let color = tag.colorNumber.flatMap(FinderTagColor.init(rawValue:)) {
                    color.dotColor.setFill()
                    NSBezierPath(ovalIn: dotRect).fill()
                } else {
                    mutedColor.setStroke()
                    let ring = NSBezierPath(ovalIn: dotRect.insetBy(dx: 0.75, dy: 0.75))
                    ring.lineWidth = 1.5
                    ring.stroke()
                }
                let textX = dotRect.maxX + Self.dotGap
                // Only a chip wider than the panel ends in an ellipsis.
                (label(tag) as NSString).draw(
                    with: NSRect(
                        x: textX, y: top, width: max(0, chip.maxX - Self.chipPadding - textX), height: lineHeight),
                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                    attributes: [.font: font, .foregroundColor: textColor, .paragraphStyle: paragraph])
                x += widths[position] + Self.chipGap
            }
        }
    }
}
